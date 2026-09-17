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

- Fixed-width record writer (`Telford::Format`) for the batch header and line detail records, unit-tested against `docs/example.tsv`
- Fund → `subcc` mapping UI (`configure()`)
- `generate_batch()`: builds a batch from closed, not-yet-submitted invoices (order lines + invoice adjustments), with a persistent K001–K999 batch id sequence
- `install`/`upgrade`/`uninstall`: submitted-invoices, cron-run-log and batch-sequence tables
- `docs/DATA_REQUIREMENTS.md`: documents that `apar_id`/`voucher_date` depend on Koha's own vendor "Account number" and invoice "Billing date" fields being populated

### Changed

- `apar_id` and `voucher_date` are read directly from `aqbooksellers.accountnumber` and `aqinvoices.billingdate` rather than a plugin-level vendor mapping/date fallback; an invoice missing either is skipped (and left unsubmitted) rather than exported with guessed data

### Fixed

[Unreleased]: https://github.com/openfifth/koha-plugin-telford-erp/compare/v0.0.0...HEAD
