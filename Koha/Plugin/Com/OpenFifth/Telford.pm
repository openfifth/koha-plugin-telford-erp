package Koha::Plugin::Com::OpenFifth::Telford;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Acquisition::Invoices;
use Koha::Acquisition::Invoice::Adjustments;
use Koha::Acquisition::Funds;
use Koha::Acquisition::Booksellers;
use Koha::Logger;

use Mojo::JSON qw(encode_json decode_json);

use Koha::Plugin::Com::OpenFifth::Telford::Format;

our $VERSION = '0.0.0';
our $MINIMUM_VERSION = "24.11.00.000";

our $metadata = {
    name            => 'Telford ERP Integration',
    author          => 'Open Fifth',
    description     => "A plugin to manage finance integration for Telford with their ERP (PL) finance system",
    date_authored   => '2026-08-21',
    date_updated    => '2026-09-17',
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new();

    return $self;
}

sub install {
    my ($self) = @_;
    my $dbh = C4::Context->dbh;

    $dbh->do(
        q{
        CREATE TABLE IF NOT EXISTS `plugin_telford_submitted_invoices` (
          `id` int(11) NOT NULL AUTO_INCREMENT,
          `invoiceid` int(11) NOT NULL,
          `submitted_at` datetime NOT NULL,
          `submitted_by` varchar(255) NOT NULL DEFAULT 'cron',
          `filename` varchar(255) DEFAULT NULL,
          PRIMARY KEY (`id`),
          UNIQUE KEY `unique_invoiceid` (`invoiceid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    }
    );

    $dbh->do(
        q{
        CREATE TABLE IF NOT EXISTS `plugin_telford_cron_runs` (
          `id` int(11) NOT NULL AUTO_INCREMENT,
          `run_at` datetime NOT NULL,
          `status` varchar(32) NOT NULL,
          `invoices_found` int(11) NOT NULL DEFAULT 0,
          `filename` varchar(255) DEFAULT NULL,
          `message` text DEFAULT NULL,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    }
    );

    # Single-row counter for the K001-K999 batch id sequence (Appendix A).
    $dbh->do(
        q{
        CREATE TABLE IF NOT EXISTS `plugin_telford_batch_sequence` (
          `id` int(11) NOT NULL,
          `last_number` int(11) NOT NULL DEFAULT 0,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    }
    );
    $dbh->do(
        q{
        INSERT IGNORE INTO `plugin_telford_batch_sequence` (`id`, `last_number`) VALUES (1, 0)
    }
    );

    return 1;
}

sub upgrade {
    my ($self) = @_;
    return $self->install();
}

sub uninstall {
    my ($self) = @_;
    my $dbh = C4::Context->dbh;

    $dbh->do(q{DROP TABLE IF EXISTS `plugin_telford_submitted_invoices`});
    $dbh->do(q{DROP TABLE IF EXISTS `plugin_telford_cron_runs`});
    $dbh->do(q{DROP TABLE IF EXISTS `plugin_telford_batch_sequence`});

    return 1;
}

=head3 configure

Staff UI for mapping Koha funds to the interface's 4-value C<subcc> code,
and Koha vendors to the ERP's 6-digit C<apar_id> creditor number. Neither
of these can be derived from data Koha already holds for us (funds have no
built-in "material category" field, and C<aqbooksellers.accountnumber> is
not populated in Telford's live data), so both are plugin-level config.

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        # Funds are per budget-period, so the same budget_code (e.g. AUDIO)
        # can appear more than once across periods. The mapping is keyed on
        # budget_code, so we only need to show it once in the form.
        my %seen;
        my @funds =
            grep { !$seen{ $_->{budget_code} }++ }
            map  { { budget_code => $_->budget_code, budget_name => $_->budget_name } }
            Koha::Acquisition::Funds->search( {}, { order_by => 'budget_code' } )->as_list;

        my @vendors = Koha::Acquisition::Booksellers->search( {}, { order_by => 'name' } )->as_list;

        $template->param(
            funds           => \@funds,
            vendors         => \@vendors,
            fund_mappings   => $self->_fund_subcc_mappings,
            vendor_mappings => $self->_vendor_apar_mappings,
            subcc_codes     => \@Koha::Plugin::Com::OpenFifth::Telford::Format::SUBCC_CODES,
        );

        $self->output_html( $template->output() );
    }
    else {
        my %fund_mappings;
        my %vendor_mappings;
        for my $param_name ( $cgi->param() ) {
            if ( $param_name =~ /^fund_subcc_(.+)$/ ) {
                my $value = $cgi->param($param_name);
                $fund_mappings{$1} = $value if $value && $value =~ /\S/;
            }
            elsif ( $param_name =~ /^vendor_apar_(\d+)$/ ) {
                my $value = $cgi->param($param_name);
                $vendor_mappings{$1} = $value if $value && $value =~ /\S/;
            }
        }

        $self->store_data(
            {
                fund_subcc_mappings  => encode_json( \%fund_mappings ),
                vendor_apar_mappings => encode_json( \%vendor_mappings ),
            }
        );
        $self->go_home();
    }
}

sub _fund_subcc_mappings {
    my ($self) = @_;
    my $data = $self->retrieve_data('fund_subcc_mappings') || '{}';
    return eval { decode_json($data) } || {};
}

sub _vendor_apar_mappings {
    my ($self) = @_;
    my $data = $self->retrieve_data('vendor_apar_mappings') || '{}';
    return eval { decode_json($data) } || {};
}

sub _map_fund_to_subcc {
    my ( $self, $budget_code ) = @_;
    return 'UNMAPPED' unless defined $budget_code;
    return $self->_fund_subcc_mappings->{$budget_code} // 'UNMAPPED';
}

sub _map_vendor_to_apar_id {
    my ( $self, $bookseller_id ) = @_;
    return 'UNMAPPED' unless defined $bookseller_id;
    return $self->_vendor_apar_mappings->{$bookseller_id} // 'UNMAPPED';
}

=head3 _next_batch_id

Atomically advances the K001-K999 sequence (see docs/spec.md Appendix A)
and returns the formatted batch id for the batch about to be sent.

=cut

sub _next_batch_id {
    my ($self) = @_;
    my $dbh = C4::Context->dbh;

    $dbh->{AutoCommit} = 0;
    my $current =
        $dbh->selectrow_array(q{SELECT last_number FROM plugin_telford_batch_sequence WHERE id = 1 FOR UPDATE});
    my $next = Koha::Plugin::Com::OpenFifth::Telford::Format::next_batch_number($current);
    $dbh->do( q{UPDATE plugin_telford_batch_sequence SET last_number = ? WHERE id = 1}, undef, $next );
    $dbh->commit;
    $dbh->{AutoCommit} = 1;

    return Koha::Plugin::Com::OpenFifth::Telford::Format::format_batch_id($next);
}

=head3 generate_batch

    my $batch = $plugin->generate_batch({ from => $date, to => $date });

Builds the fixed-width export for every closed, not-yet-submitted invoice
with a C<closedate> in the given (inclusive) range. Returns a hashref:

    {
        batch_id     => 'K001',
        text         => "...\r\n...\r\n",   # header record + line records
        invoice_ids  => [ 1, 2, ... ],       # for marking as submitted
        num_trans    => 3,
        total_debits => 6679,                # pence
        total_credits => 500,                # pence
    }

Two things this cannot yet resolve safely and currently default with a
flag rather than guess silently - see docs/FINDINGS_AND_PLAN.md:

=over 4

=item * C<voucher_date> falls back to C<shipmentdate> then C<closedate>
when C<billingdate> (the supplier's invoice date) is not recorded.

=item * Invoice adjustment lines (credit notes/postage with no order line)
have no tax rate recorded in Koha, so C<tax_code> defaults to '04'.

=back

=cut

sub generate_batch {
    my ( $self, $args ) = @_;
    my $from = $args->{from};
    my $to   = $args->{to};

    my $logger = Koha::Logger->get( { category => 'Koha.Plugin.Com.OpenFifth.Telford' } );

    my $already_submitted = $self->_get_submitted_invoice_ids;

    my @invoices = Koha::Acquisition::Invoices->search(
        {
            closedate => { '!=' => undef, -between => [ $from, $to ] },
        },
        { order_by => 'closedate' }
    )->as_list;
    @invoices = grep { !$already_submitted->{ $_->invoiceid } } @invoices;

    my $batch_id = $self->_next_batch_id;

    my @lines;
    my ( $total_debits, $total_credits ) = ( 0, 0 );
    my @invoice_ids;

    for my $invoice (@invoices) {
        push @invoice_ids, $invoice->invoiceid;

        my $voucher_date = $invoice->billingdate || $invoice->shipmentdate || $invoice->closedate;
        unless ( $invoice->billingdate ) {
            $logger->warn( "Invoice " . $invoice->invoicenumber . " has no billingdate; falling back to "
                    . ( $invoice->shipmentdate ? "shipmentdate" : "closedate" )
                    . " for voucher_date" );
        }

        my $apar_id = $self->_map_vendor_to_apar_id( $invoice->booksellerid );

        for my $order ( $invoice->orders->as_list ) {
            next unless defined $order->unitprice_tax_excluded;

            # Assumption: unitprice_tax_excluded is a per-unit price, but
            # tax_value_on_receiving is already the TOTAL tax for the line
            # (Koha's convention when receiving). Confirm against a real
            # multi-quantity invoice before trusting this on quantity > 1.
            my $net_pounds = $order->unitprice_tax_excluded * ( $order->quantity // 1 );
            my $vat_pounds = $order->tax_value_on_receiving // 0;

            my $subcc = $self->_map_fund_to_subcc( $order->fund ? $order->fund->budget_code : undef );

            push @lines, Koha::Plugin::Com::OpenFifth::Telford::Format::build_line_record(
                {
                    batch_id     => $batch_id,
                    account      => $Koha::Plugin::Com::OpenFifth::Telford::Format::ACCOUNT,
                    costc        => $Koha::Plugin::Com::OpenFifth::Telford::Format::COSTC,
                    subcc        => $subcc,
                    analysis     => $Koha::Plugin::Com::OpenFifth::Telford::Format::ANALYSIS,
                    tax_code     => Koha::Plugin::Com::OpenFifth::Telford::Format::tax_code_for_rate( $order->tax_rate_on_receiving ),
                    amount       => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( $net_pounds, 10 ),
                    vat_amount   => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( $vat_pounds, 10 ),
                    description  => Koha::Plugin::Com::OpenFifth::Telford::Format::format_description( $order->ordernumber ),
                    trans_date   => _yyyymmdd( $order->datereceived || $invoice->closedate ),
                    voucher_date => _yyyymmdd($voucher_date),
                    ext_inv_ref  => $invoice->invoicenumber,
                    apar_id      => $apar_id,
                }
            );

            $total_debits  += $net_pounds >= 0 ? int( sprintf( '%.0f', $net_pounds * 100 ) ) : 0;
            $total_credits += $net_pounds < 0  ? int( sprintf( '%.0f', -$net_pounds * 100 ) ) : 0;
        }

        for my $adjustment ( Koha::Acquisition::Invoice::Adjustments->search( { invoiceid => $invoice->invoiceid } )->as_list ) {
            my $net_pounds = $adjustment->adjustment // 0;
            my $subcc = $self->_map_fund_to_subcc( $adjustment->fund ? $adjustment->fund->budget_code : undef );

            push @lines, Koha::Plugin::Com::OpenFifth::Telford::Format::build_line_record(
                {
                    batch_id     => $batch_id,
                    account      => $Koha::Plugin::Com::OpenFifth::Telford::Format::ACCOUNT,
                    costc        => $Koha::Plugin::Com::OpenFifth::Telford::Format::COSTC,
                    subcc        => $subcc,
                    analysis     => $Koha::Plugin::Com::OpenFifth::Telford::Format::ANALYSIS,
                    tax_code     => '04',    # no tax rate recorded against adjustments - see caveat above
                    amount       => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( $net_pounds, 10 ),
                    vat_amount   => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( 0, 10 ),
                    description  => Koha::Plugin::Com::OpenFifth::Telford::Format::format_description( $adjustment->adjustment_id ),
                    trans_date   => _yyyymmdd( $invoice->closedate ),
                    voucher_date => _yyyymmdd($voucher_date),
                    ext_inv_ref  => $invoice->invoicenumber,
                    apar_id      => $apar_id,
                }
            );

            $total_debits  += $net_pounds >= 0 ? int( sprintf( '%.0f', $net_pounds * 100 ) ) : 0;
            $total_credits += $net_pounds < 0  ? int( sprintf( '%.0f', -$net_pounds * 100 ) ) : 0;
        }
    }

    my $header = Koha::Plugin::Com::OpenFifth::Telford::Format::build_header_record(
        {
            batch_id      => $batch_id,
            num_trans     => scalar @lines,
            total_debits  => Koha::Plugin::Com::OpenFifth::Telford::Format::pad_field( value => $total_debits,  width => 17, align => 'right' ),
            total_credits => Koha::Plugin::Com::OpenFifth::Telford::Format::pad_field( value => $total_credits, width => 17, align => 'right' ),
            batch_date    => _yyyymmdd( dt_from_string() ),
        }
    );

    return {
        batch_id      => $batch_id,
        text          => join( "\r\n", $header, @lines ) . "\r\n",
        invoice_ids   => \@invoice_ids,
        num_trans     => scalar @lines,
        total_debits  => $total_debits,
        total_credits => $total_credits,
    };
}

sub _get_submitted_invoice_ids {
    my ($self) = @_;
    my $dbh  = C4::Context->dbh;
    my $rows = $dbh->selectcol_arrayref(q{SELECT invoiceid FROM plugin_telford_submitted_invoices});
    return { map { $_ => 1 } @$rows };
}

sub mark_invoices_submitted {
    my ( $self, $invoice_ids, $filename, $submitted_by ) = @_;
    my $dbh = C4::Context->dbh;

    for my $invoiceid (@$invoice_ids) {
        $dbh->do(
            q{INSERT IGNORE INTO plugin_telford_submitted_invoices (invoiceid, submitted_at, submitted_by, filename) VALUES (?, NOW(), ?, ?)},
            undef, $invoiceid, $submitted_by || 'manual', $filename
        );
    }

    return 1;
}

sub _yyyymmdd {
    my ($date) = @_;
    return '' unless $date;
    my $dt = ref($date) ? $date : dt_from_string($date);
    return $dt->strftime('%Y%m%d');
}

1;
