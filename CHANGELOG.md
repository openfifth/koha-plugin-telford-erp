# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add user-visible changes under the `[Unreleased]` heading below as you work.
On the next `npm run release:*`, `increment_version.js` promotes `[Unreleased]`
to a dated `[X.Y.Z]` section and inserts a fresh empty `[Unreleased]` above it
along with the comparison links — do not edit the heading or the links by hand.

## [Unreleased]

### Added

- `configure.tt`: an info box explaining how the export is built - a table of which Koha field/area populates each export field (fixed values, order/adjustment data, the `apar_id`/`voucher_date` Koha fields, and the fund mapping below it), plus a static example header + line record

### Fixed

- `configure.tt`/`report-step2.tt`: replaced references to repo-only files (`docs/spec.md`, `docs/DATA_REQUIREMENTS.md`, `docs/example.tsv`) in staff-facing messages with the relevant detail inline, since plugin users don't have access to the plugin's source

## [0.1.3] - 2026-09-18

### Fixed

- `configure.tt`/`report-step1.tt`/`report-step2.tt`/`manage-submissions.tt`: wrapped tables in `page-section` divs and gave action buttons the `btn btn-primary`/`cancel` classes core now expects, and swapped the legacy `dialog message`/`dialog alert` classes for `alert alert-info`/`alert alert-danger`, matching current core tool/report page markup

## [0.1.2] - 2026-09-18

### Fixed

- `configure.tt`/`report-step1.tt`/`report-step2.tt`/`manage-submissions.tt`: adopted core's `wrapper-staff-tool-plugin.inc` instead of hand-rolled header/breadcrumbs/Bootstrap-3 grid markup, which had gone stale against 25.11's Bootstrap 5 staff templates and rendered with broken styling

## [0.1.1] - 2026-09-17

## [0.1.0] - 2026-09-17

### Added

- Fixed-width record writer (`Telford::Format`) for the batch header and line detail records, unit-tested against `docs/example.tsv`
- Fund → `subcc` mapping UI (`configure()`)
- `generate_batch()`: builds a batch from closed, not-yet-submitted invoices (order lines + invoice adjustments), with a persistent K001–K999 batch id sequence
- `install`/`upgrade`/`uninstall`: submitted-invoices, cron-run-log and batch-sequence tables
- `docs/DATA_REQUIREMENTS.md`: documents that `apar_id`/`voucher_date` depend on Koha's own vendor "Account number" and invoice "Billing date" fields being populated

- `cronjob_nightly()`: sends a batch covering everything closed since the last scheduled day, via the configured (S)FTP transport or a local `output/` file
- `report()`/`report-step1.tt`/`report-step2.tt`: manual date-range run, delivers the same way as the cron and shows the result (batch id, totals, raw text)
- `tool()`/`manage-submissions.tt`: run history and a way to clear a submitted invoice so it's picked up again
- `configure()`: delivery method, (S)FTP transport and nightly-cron weekday schedule

### Changed

- `apar_id` and `voucher_date` are read directly from `aqbooksellers.accountnumber` and `aqinvoices.billingdate` rather than a plugin-level vendor mapping/date fallback; an invoice missing either is skipped (and left unsubmitted) rather than exported with guessed data

### Fixed

- Template files moved out of a `templates/` subdirectory to sit flat next to the module - `Koha::Plugins::Base::get_template` (via `Module::Bundled::Files`) only ever looks in the module's own directory, so nothing under `templates/` was ever actually reachable, in this plugin or in the original scaffold it came from

[Unreleased]: https://github.com/openfifth/koha-plugin-telford-erp/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/openfifth/koha-plugin-telford-erp/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/openfifth/koha-plugin-telford-erp/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/openfifth/koha-plugin-telford-erp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/openfifth/koha-plugin-telford-erp/compare/v0.0.0...v0.1.0