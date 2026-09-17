# Telford ERP Export — Findings & Plan of Action

## What the Telford spec actually asks for

`spec.md` + `example.tsv` define a **fixed-width (not delimited) batch export** to an ERP called "PL":

- **Batch header record** (120 chars): `Batch ID` (K001–K999, wraps), `Num Trans`, `Total Debits`, `Total Credits`, `Batch Date`.
- **Line detail record** (120 chars): `account` (constant `R4016`), `costc` (constant `LLAA`), `subcc` (4 values: `LBAB` audio books / `LBPB` printed books / `LBPP` papers & periodicals / `LBRO` reference online), `analysis` (constant `Z99`), `tax_code` (only 2 values: `01`=20% standard, `04`=0% zero-rated), `amount` + `vat_amount` (pence, signed for credits), `description` (Koha's transaction number, for cross-reference), `trans_date`, `voucher_date` (supplier's invoice date), `ext_inv_ref`, `apar_id` (6-digit vendor code starting with `5`).

I decoded `example.tsv` against the byte offsets in the spec and it lines up exactly (4+5+4+4+3+2+10+10+10+8+8+10+6+36=120), so the spec is internally consistent and trustworthy.

## Comparison to the three sibling plugins

All three existing plugins (`wcc-sap`, `wscc-oracle`, `rbkc-oracle`) are the **same house-built skeleton** by Open Fifth — `Koha::Plugin::Com::OpenFifth::<System>`, installed as `package.json` + `Koha/Plugin/Com/OpenFifth/*.pm` + `UploadController.pm` + TT templates:

| Aspect              | wcc-sap / rbkc-oracle / wscc-oracle                         | Telford spec                                                                                             |
| ------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Output format       | Delimited (CSV or `\|`), variable-width                     | **Fixed-width, 120 char** — new writer needed                                                            |
| Record types        | 3 (`CT`/`AP`/`GL`) mimicking Oracle/SAP ledger import       | 2 (Header/Detail) — simpler                                                                              |
| Account/cost-centre | Per-fund lookup table (many funds → many codes)             | **Mostly constant** (`R4016`/`LLAA`/`Z99` fixed); only `subcc` (4 values) and `tax_code` (2 values) vary |
| Batch sequencing    | None — files are just timestamped                           | **Stateful K001–K999 counter with wraparound** — new requirement                                         |
| Triggers            | cron (nightly) + manual report UI + REST upload API         | Same pattern should work                                                                                 |
| Dedup/state         | `plugin_*_submitted_invoices` + `plugin_*_cron_runs` tables | Same pattern should work                                                                                 |
| Delivery            | `Koha::File::Transports` (SFTP) or local disk               | Same pattern should work                                                                                 |
| Credit notes        | Sign convention on amounts, adjustment-note parsing for tax | Same sign convention expected (spec: "place a minus figure before the amount")                           |
| Vendor code         | `aqbooksellers.accountnumber`                               | Matches `apar_id` requirement exactly                                                                    |

**wscc-oracle** is the most mature reference (income/cashup export too, plus a `docs/` folder with field-mapping guides) — worth mining for the mapping-config and cron-window patterns even though Telford's output format is much simpler.

## Resolved questions (confirmed 2026-09-17 against a live Telford DB copy in KTD `o5th25`)

1. **`account` (`R4016`)** — confirmed constant. No column anywhere in `aqbudgets`/`aqorders`/`aqbooksellers` holds anything like it; it's a literal baked into the plugin (`$Koha::Plugin::Com::OpenFifth::Telford::Format::ACCOUNT`).
2. **`costc` (`LLAA`)** — confirmed constant, same reasoning (`::COSTC`).
3. **`subcc`** — confirmed driven by `aqbudgets.budget_code`, mapped via a plugin config table (mirrors the siblings' `fund_field_mappings` pattern), not `sort1`/`sort2` (both are blank on every live fund). Evidence: the live "Library Bookfund 2026-2027" period has a fund named exactly `AUDIO` ("Audio Books"), which maps cleanly to `LBAB`; the other live funds (`AF`, `ANF`, `JUN`, `LP`) are all general book funds and map to `LBPB`. No fund yet exists for `LBPP` (Papers & Periodicals) or `LBRO` (Reference Online) — the configure UI maps by `budget_code` and defaults anything unmapped to `UNMAPPED` (visible in the output so staff can fix it), rather than guessing.
4. **`analysis` (`Z99`)** — confirmed constant, same reasoning as #1/#2 (`::ANALYSIS`).
5. **`tax_code`** — confirmed: `aqorders.tax_rate_on_receiving == 0.20` → `01`, everything else (incl. `0.00`) → `04`. Matches live order data exactly (two real lines: rate `0.2000`→should be `01`, rate `0.0000`→`04`).
6. **`description`** — confirmed zero-padded `aqorders.ordernumber`, 10 digits, cross-reference only (`Format::format_description`).

### New findings surfaced while confirming the above

- **`ext_inv_ref`** is `aqinvoices.invoicenumber` — real values (`O5Jul0126`, `O56001`) fit the 10-char field comfortably.
- **`voucher_date`** should be `aqinvoices.billingdate`, but it is **`NULL` on every live invoice** — finance staff aren't currently entering the supplier's invoice date in Koha. Implemented with a fallback chain (`billingdate` → `shipmentdate` → `closedate`) and a logged warning when it falls back, but this needs a process fix on Telford's side, not just a code workaround.
- **`apar_id`** can't come from `aqbooksellers.accountnumber` — it's blank on all 5 live vendors. Implemented as its own plugin-config mapping (vendor → 6-digit code), same shape as the fund mapping, rather than relying on that field.
- **Credit notes** show up as `aqinvoice_adjustments` rows (negative `adjustment`, linked to a `budget_id`, no order line) — confirmed with a real row (`-5.00`, `budget_id=3`). These need their own line-generation path (implemented), separate from order lines.
- **Batch header totals** — re-reading the spec text resolves this cleanly (no longer an open question): both `Total Debits` and `Total Credits` are explicitly stated to be "in pence" and "a positive unsigned value", i.e. same units as the line `amount` field, just wider and split by sign.

## Still open / needs a decision

1. **VAT basis on multi-quantity order lines** — all real order lines seen so far have `quantity = 1`, so it's untested whether `tax_value_on_receiving` is the *total* tax for the line or a *per-unit* value. `generate_batch()` currently assumes it's already the line total (not multiplied by quantity again) — needs verifying against a real `quantity > 1` invoice.
2. **`tax_code` on adjustment lines** — `aqinvoice_adjustments` has no tax rate column at all, so credit/postage adjustment lines currently default to `04`. Confirm with Telford whether that's actually correct for their adjustments.
3. **`description` collision risk** — order lines use zero-padded `ordernumber`, adjustment lines use zero-padded `adjustment_id`; these are separate auto-increment sequences and could collide. Low risk in practice, but worth flagging.
4. **Which invoices are in scope** — is this instance single-tenant (all closed invoices are Telford's), or does the export need a vendor/branch filter like the siblings' `name LIKE 'XXX%'`?
5. **Batch ID persistence semantics** — implemented as a single global counter in a new `plugin_telford_batch_sequence` table, incremented under a row lock. Confirm a single global sequence (rather than per-day) is what Telford's ERP expects.

## Plan of action

1. ✅ **Scaffold** the plugin from the house template — done (`Koha::Plugin::Com::OpenFifth::Telford`, `package.json`, `t/`, `docs/`).
2. ✅ **Resolve the open questions** — done for the 6 order-line-level questions, against a live Telford DB copy in KTD `o5th25` (see above). A handful of new, narrower questions remain (see "Still open" above) but no longer block core development.
3. ✅ **Build the fixed-width record writer** — done: `Koha/Plugin/Com/OpenFifth/Telford/Format.pm`, unit-tested in `t/01-format.t`, validated byte-for-byte against `docs/example.tsv`.
4. ✅ **Batch ID counter** — done: `plugin_telford_batch_sequence`, single global counter, row-locked increment, K001→K999→K001 wraparound (`Format::next_batch_number`).
5. ✅ **Data extraction** — done: `generate_batch()` in `Telford.pm` walks `Koha::Acquisition::Invoices` (closed, date-ranged, not-yet-submitted) → `aqorders` + `Koha::Acquisition::Invoice::Adjustments`, resolving `subcc` and `apar_id` via the new plugin-config mappings and `tax_code` via `Format::tax_code_for_rate`.
6. ✅ **Batch header aggregation** — done: `num_trans`/`total_debits`/`total_credits` computed alongside the line loop in `generate_batch()`.
7. ⬜ **Reuse the house infrastructure**: `cronjob_nightly()`, two-step manual `report()` UI, `manage-submissions.tt`, REST `UploadController`, SFTP/local delivery — not yet wired up. `configure()` currently only covers the fund/vendor mapping tables; transport + schedule config from the sibling plugins still needs porting across.
8. ✅ **Tests** — `t/01-format.t` covers the fixed-width writer and batch-ID rollover, runs on the host with plain `prove` (no KTD needed). Still needed: a DB-backed test for `generate_batch()` itself (needs KTD/fixtures, per `t/01-oracle-integration.t`'s pattern).
9. ⬜ **Docs** — a field-mapping guide (mirroring `wscc-oracle/docs/ACQUISITIONS_FIELD_MAPPING_GUIDE.md`) once the "still open" items above are settled with Telford.
10. ⬜ **Validate against KTD** with real acquisitions/invoice fixtures — `generate_batch()` has not yet been run inside `o5th25`; next session should call it against the live data and byte-diff against `docs/example.tsv`'s structure.
