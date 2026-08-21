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

## Key open questions (need answering before/while building)

1. **What drives `subcc`?** Koha has no `itemtype` field on `aqorders`. The two realistic sources are: (a) `aqbudgets.budget_code` — i.e. Telford runs separate funds per material category, reusing the sibling plugins' "fund → code" mapping pattern; or (b) `aqorders.sort1`/`sort2` statistical fields, which Koha designed for exactly this kind of orthogonal categorisation. Need to check Telford's actual fund/budget structure in their live Koha to know which.
2. **Which invoices are in scope?** Siblings filter by `booksellerid.name LIKE 'XXX%'` — is there an equivalent Telford-only filter, or is this a single-tenant Koha instance where all closed invoices qualify?
3. **Batch ID persistence** — needs a durable, safe-under-concurrency counter (new table), reset K999→K001. Does Telford need this to survive plugin reinstall/upgrade, and is a single global counter fine (vs per-day)?
4. **Batch header totals format** — spec says "Format 9(14)99" for `Total Debits`/`Total Credits` (17 chars) while line `amount` is a 10-char plain integer-pence field. Need to confirm whether the header total is also pence-as-integer or pounds-with-implied-2-decimals (COBOL picture clause reads like the latter).
5. **Credit note detection** — Koha has no `is_credit_note` flag; siblings infer credits from negative `unitprice`/`shipmentcost`/adjustment amounts. Confirm this convention is sufficient for Telford's credit notes too.
6. **`description` (transaction number)** — spec says "Koha generated transaction number" width 10. Likely `aqorders.ordernumber` or `aqinvoices.invoiceid`, need to confirm which Telford actually wants as the cross-reference key (siblings use `invoicenumber` for this role, which is vendor-supplied, not Koha-generated — so this is subtly different from all three siblings).

## Plan of action

1. **Scaffold** the plugin from the house template (closest analogue: `rbkc-oracle`, since it's the simplest of the three): `package.json`, `Koha/Plugin/Com/OpenFifth/Telford.pm` (or a name matching the actual receiving system once confirmed — spec just calls it "ERP (PL)"), `UploadController.pm`, `t/`, `docs/`.
2. **Resolve the open questions above** with the Telford stakeholder — critically #1 (subcc source) and #4 (header total format), since they change the data model.
3. **Build the fixed-width record writer** — new module (none of the siblings need this; they're all delimited). Needs per-field width/justification/padding rules (char fields space-padded left-justified, numeric fields space or zero-padded right-justified, signed amounts), validated against `example.tsv` byte-for-byte.
4. **Batch ID counter** — new `plugin_telford_batch_sequence` (or reuse `plugin_data`) storing the last-used K-number, with wraparound at K999→K001, incremented atomically per run.
5. **Data extraction** — `Koha::Acquisition::Invoices` (closed, date-ranged) → `aqorders` + `aqinvoice_adjustments`, resolving `subcc` via whichever mapping source is confirmed in step 2, `tax_code` via a hardcoded 20%→01 / 0%→04 lookup, `apar_id` from `aqbooksellers.accountnumber`.
6. **Batch header aggregation** — num_trans, total_debits, total_credits computed from the same line set.
7. **Reuse the house infrastructure wholesale**: `install()/uninstall()/upgrade()` creating submitted-invoices + cron-run-log tables, `configure()` for mapping + SFTP/local transport + schedule, `cronjob_nightly()`, two-step manual `report()`, `manage-submissions.tt`, REST `UploadController` for on-demand upload — all directly portable from `rbkc-oracle`/`wcc-sap` with the SAP/Oracle-specific bits swapped out.
8. **Tests** — unit tests for the fixed-width writer (field widths, padding, sign handling) and batch-ID rollover, mirroring `t/01-oracle-integration.t`.
9. **Docs** — README + a field-mapping guide (mirroring `wscc-oracle/docs/ACQUISITIONS_FIELD_MAPPING_GUIDE.md`), documenting the subcc/tax_code/apar_id mapping decisions once confirmed.
10. **Validate against KTD** with real acquisitions/invoice fixtures, byte-diffing generated output against `example.tsv`'s structure before considering it done.
