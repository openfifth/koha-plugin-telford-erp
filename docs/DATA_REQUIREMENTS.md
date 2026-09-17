# Data requirements

Two fields this export needs are Koha's own native fields, not plugin
configuration. If they're not populated, the affected invoice is skipped
from the export entirely (and stays unsubmitted, so it's picked up
automatically once fixed) rather than the plugin guessing or maintaining
a shadow mapping.

## Vendor account number → `apar_id`

Every line requires the ERP's 6-digit creditor number (starting with `5`,
per `docs/spec.md` Appendix B). This comes from **the vendor's "Account
number" field** (`aqbooksellers.accountnumber`), set on each vendor's
detail page in Koha (Acquisitions → Vendors → *vendor* → Edit).

As of 2026-09-17, none of Telford's live vendors have this set. It needs
configuring per vendor before that vendor's invoices can export.

## Invoice billing date → `voucher_date`

Every line requires the supplier's invoice date. This comes from **the
invoice's "Billing date" field** (`aqinvoices.billingdate`), set when
recording/closing an invoice in Koha (Acquisitions → vendor → Invoices →
*invoice*).

As of 2026-09-17, this is `NULL` on every live invoice in the copy we
checked — Telford doesn't currently have any invoices with it populated.
This is expected to resolve itself as new invoices are entered with the
field filled in; it does not need a plugin-level fix.

## Fund → sub cost centre (`subcc`)

Unlike the two above, this genuinely has no equivalent native Koha field
(funds have no "material category" concept), so it *is* plugin
configuration - see the "Fund → sub cost centre mapping" table on the
plugin's Configure page.
