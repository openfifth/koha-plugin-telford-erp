# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Koha plugin (`Koha::Plugin::Com::OpenFifth::Telford`) that exports closed acquisitions invoices and credit notes to Telford's "PL" finance system as a **fixed-width, 120-character-per-record** batch file (one header record plus one line record per order/adjustment). It is a sibling of the Open Fifth `koha-plugin-wcc-sap`, `-rbkc-oracle` and `-wscc-oracle` plugins and follows the same skeleton (cron + manual report UI + dedup table + optional SFTP delivery), but the output format and batch-ID sequencing are specific to Telford.

## Commands

There is no local build. Tests need a Koha environment (KTD) because the plugin loads `Koha::*` and `C4::Context`; CI runs them inside a KTD instance with `--plugins`.

```bash
# inside KTD, from /kohadevbox/plugins/koha-plugin-telford-erp
export KOHA_PLUGIN_DIR=$(pwd) PERL5LIB=$PERL5LIB:.
prove -v -r t/                 # all tests
prove -v t/01-format.t         # single test file
```

`t/01-format.t` only exercises `Format.pm` (pure Perl, no Koha dependency) and can be run with plain `prove -I. t/01-format.t` outside KTD. `t/00-load.t` reads `package.json` and checks the module loads and its `$VERSION` matches.

Releases (patch/minor/major) are done with `npm run release:patch|minor|major`: it runs `increment_version.js` (bumps `package.json` and `$VERSION` in the `.pm`, and promotes `[Unreleased]` in `CHANGELOG.md`), commits `chore: bump version`, tags `vX.Y.Z` and pushes. A pushed `v*.*.*` tag triggers the CI release job that builds the `.kpz`. Add user-visible changes under `## [Unreleased]` in `CHANGELOG.md` as you work; don't edit the headings or comparison links by hand.

## Architecture

- `Koha/Plugin/Com/OpenFifth/Telford.pm` — the plugin class. Hooks: `install`/`upgrade`/`uninstall` (create/drop the `plugin_telford_*` tables), `configure` (settings UI), `cronjob_nightly`, `report`/`report_step1`/`report_step2` (manual export), `tool`/`manage_submissions` (view/undo submissions).
- `Telford/Format.pm` — pure fixed-width formatting (field tables `@HEADER_FIELDS` / `@LINE_FIELDS`, `pad_field`, `format_pence`, `tax_code_for_rate`, `next_batch_number`, ...). `pad_field` dies on oversized values rather than truncating. The constants `$ACCOUNT` (`R4016`), `$COSTC` (`LLAA`) and `$ANALYSIS` (`Z99`) are deliberately hard-coded literals, not config.
- `Telford/*.tt` — Template Toolkit templates for configure, the two-step report, and manage-submissions.

Data flow in `generate_batch({from, to})`: closed invoices in the date range, minus those already in `plugin_telford_submitted_invoices` → order lines from `aqorders` plus `Koha::Acquisition::Invoice::Adjustments` (credit notes) → `Format` records, with a new batch ID from `_next_batch_id`. `_deliver_batch` then writes either to `bundle_path/output/` (git-ignored, contains real financial data) or uploads via a configured `Koha::File::Transports` server. Invoices are marked submitted only after a successful delivery (`mark_invoices_submitted`).

Non-obvious behaviours worth knowing before changing things:

- **Batch IDs** (`K001`–`K999`, wrapping) come from a single global counter in `plugin_telford_batch_sequence`, incremented under a row lock.
- **`subcc`** (`LBAB`/`LBPB`/`LBPP`/`LBRO`) is resolved from `aqbudgets.budget_code` via the fund mapping in plugin config; an unmapped fund (or any value too wide for its field) is collected into `errors` on the batch rather than dying; the report page lists them and nothing is sent or numbered, and the nightly cron logs an error run.
- **`apar_id` / `voucher_date`** come straight from `aqbooksellers.accountnumber` and `aqinvoices.billingdate`. Invoices missing either are **skipped with a warning** (left unsubmitted), never defaulted. See `docs/DATA_REQUIREMENTS.md`.
- **`tax_code`**: `tax_rate_on_receiving == 0.20` → `01`, anything else → `04`. Adjustment lines have no tax rate and default to `04`.
- **Nightly cron** only sends on configured `transport_days`, and covers the previous scheduled day up to *yesterday* (today is excluded because the cron runs in the early hours).
- Plugin DB tables: `plugin_telford_submitted_invoices` (dedup) plus the batch-sequence and run-log tables; plugin config lives in `retrieve_data`/`store_data` keys such as `output`, `transport_server`, `transport_days`.

## Reference docs

- `docs/spec.md` — Telford's record layout (field offsets/widths); `docs/example.tsv` is a matching sample file that `Format.pm` is validated against byte-for-byte.
- `docs/FINDINGS_AND_PLAN.md` — resolved design decisions, evidence, and still-open questions (e.g. VAT on multi-quantity lines, tax code for adjustments).
- `docs/DATA_REQUIREMENTS.md` — Koha data Telford must keep populated for invoices to export.

Staff-facing templates must not reference repo-only files (`docs/…`); put the relevant detail inline instead.
