# koha-plugin-telford-erp

A Koha plugin to export acquisitions invoice/credit-note data from Koha to Telford's ERP (PL) finance system.

## Status

This plugin is in early scaffolding — the finance export logic has not been implemented yet. See [docs/](docs/) for the ERP file format specification and the implementation plan.

## Documentation

- [ERP file format specification](docs/spec.md) — the batch header / line detail record layout supplied by Telford
- [Example output](docs/example.tsv) — a sample export file matching the spec
- [Findings & plan of action](docs/FINDINGS_AND_PLAN.md) — comparison against sibling Open Fifth ERP export plugins and the implementation plan

## Installation

1. Download the latest `.kpz` file from the [Releases](https://github.com/openfifth/koha-plugin-telford-erp/releases) page
2. In Koha, go to Tools > Plugins
3. Upload the `.kpz` file using the plugin upload feature
4. Enable the plugin

## Support

- **Issues**: [GitHub Issues](https://github.com/openfifth/koha-plugin-telford-erp/issues)
- **Author**: Open Fifth
- **License**: GPL-3.0
