package Koha::Plugin::Com::OpenFifth::Telford;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Acquisition::Invoices;
use Koha::Acquisition::Invoice::Adjustments;
use Koha::Acquisition::Funds;
use Koha::Acquisition::Booksellers;
use Koha::File::Transports;
use Koha::Logger;

use File::Path qw(make_path);
use File::Spec;
use List::Util qw(max);
use Mojo::JSON qw(encode_json decode_json);

use Koha::Plugin::Com::OpenFifth::Telford::Format;

our $VERSION         = '0.1.0';
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

Staff UI for mapping Koha funds to the interface's 4-value C<subcc> code.
This can't be derived from data Koha already holds (funds have no
built-in "material category" field), so it's plugin-level config.

C<apar_id> and C<voucher_date> are deliberately NOT configured here - they
come straight from C<aqbooksellers.accountnumber> and
C<aqinvoices.billingdate>, which Koha already has a native field for. See
L<docs/DATA_REQUIREMENTS.md> for what Telford needs to keep populated in
Koha itself for those to work.

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

        my @days_of_week = qw(sunday monday tuesday wednesday thursday friday saturday);
        my $transport_days = {
            map  { $days_of_week[$_] => 1 }
            grep { defined $days_of_week[$_] }
            split( ',', $self->retrieve_data('transport_days') // '' )
        };

        $template->param(
            funds                => \@funds,
            fund_mappings        => $self->_fund_subcc_mappings,
            subcc_codes          => \@Koha::Plugin::Com::OpenFifth::Telford::Format::SUBCC_CODES,
            output               => $self->retrieve_data('output') || 'file',
            transport_server     => $self->retrieve_data('transport_server'),
            transport_days       => $transport_days,
            available_transports => Koha::File::Transports->search(),
        );

        $self->output_html( $template->output() );
    }
    else {
        my %fund_mappings;
        for my $param_name ( $cgi->param() ) {
            if ( $param_name =~ /^fund_subcc_(.+)$/ ) {
                my $value = $cgi->param($param_name);
                $fund_mappings{$1} = $value if $value && $value =~ /\S/;
            }
        }

        my @selected_days = $cgi->multi_param('days');

        $self->store_data(
            {
                fund_subcc_mappings => encode_json( \%fund_mappings ),
                output              => scalar $cgi->param('output'),
                transport_server    => scalar $cgi->param('transport_server'),
                transport_days      => join( ',', sort { $a <=> $b } @selected_days ),
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

sub _map_fund_to_subcc {
    my ( $self, $budget_code ) = @_;
    return 'UNMAPPED' unless defined $budget_code;
    return $self->_fund_subcc_mappings->{$budget_code} // 'UNMAPPED';
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

Every exported invoice needs two things that Koha has native fields for
but that are not reliably populated in Telford's data yet (see
L<docs/DATA_REQUIREMENTS.md>): the vendor's C<accountnumber> (apar_id)
and the invoice's C<billingdate> (voucher_date). Rather than guess at a
fallback or maintain a shadow mapping for either, an invoice missing
either one is skipped entirely (logged as a warning) and left
unsubmitted, so it picks itself up automatically once the missing Koha
data is filled in.

One further thing this cannot yet resolve safely and currently defaults
with a flag rather than guess silently - see docs/FINDINGS_AND_PLAN.md:
invoice adjustment lines (credit notes/postage with no order line) have
no tax rate recorded in Koha, so C<tax_code> defaults to '04'.

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
        my $voucher_date = $invoice->billingdate;
        unless ($voucher_date) {
            $logger->warn( "Invoice " . $invoice->invoicenumber
                    . " has no billingdate recorded in Koha; skipping until it is set on the invoice" );
            next;
        }

        my $vendor = Koha::Acquisition::Booksellers->find( $invoice->booksellerid );
        my $apar_id = $vendor ? $vendor->accountnumber : undef;
        unless ($apar_id) {
            $logger->warn( "Invoice " . $invoice->invoicenumber . " vendor '"
                    . ( $vendor ? $vendor->name : $invoice->booksellerid )
                    . "' has no account number configured in Koha; skipping until it is set on the vendor" );
            next;
        }

        push @invoice_ids, $invoice->invoiceid;

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

=head3 cronjob_nightly

Runs on Koha's nightly plugins cron. Sends a batch covering everything
closed since the previous scheduled day (inclusive) up to yesterday
(today is excluded because the cron runs in the early hours and
invoices closed later today would otherwise be missed by both this run
and the next).

=cut

sub cronjob_nightly {
    my ($self) = @_;
    my $logger = Koha::Logger->get( { category => 'Koha.Plugin.Com.OpenFifth.Telford' } );

    $logger->info("Telford nightly cronjob started");

    my $transport_days = $self->retrieve_data('transport_days');
    unless ($transport_days) {
        $logger->info("Telford nightly cronjob: no transport days configured, skipping");
        return;
    }

    my @selected_days = sort { $a <=> $b } split( /,/, $transport_days );
    my %selected_days = map { $_ => 1 } @selected_days;

    my $today = dt_from_string()->day_of_week % 7;
    unless ( $selected_days{$today} ) {
        $logger->info("Telford nightly cronjob: today (day $today) is not a scheduled day, skipping");
        return;
    }

    my $prev_in_week = max( grep { $_ < $today } @selected_days );
    my $days_since_prev =
        defined($prev_in_week)
        ? $today - $prev_in_week
        : ( ( $today - $selected_days[-1] ) % 7 || 7 );

    my $today_dt   = dt_from_string()->truncate( to => 'day' );
    my $from       = $today_dt->clone->subtract( days => $days_since_prev )->ymd;
    my $to         = $today_dt->clone->subtract( days => 1 )->ymd;

    $logger->info("Telford nightly cronjob: generating batch for $from to $to");

    my $batch = $self->generate_batch( { from => $from, to => $to } );

    unless ( $batch->{num_trans} ) {
        $logger->info("Telford nightly cronjob: nothing to export for $from to $to");
        $self->_add_run_log( { status => 'no_data', message => "[$from to $to] Nothing to export" } );
        return;
    }

    my $filename = $self->_generate_filename( $batch->{batch_id} );
    my $result   = $self->_deliver_batch( $batch, $filename );

    if ( $result->{success} ) {
        $self->mark_invoices_submitted( $batch->{invoice_ids}, $filename, 'cron' );
        $logger->info("Telford nightly cronjob: delivered $filename ($batch->{num_trans} lines)");
        $self->_add_run_log(
            {
                status         => 'success',
                invoices_found => scalar @{ $batch->{invoice_ids} },
                filename       => $filename,
                message        => "[$from to $to] Delivered $filename",
            }
        );
    }
    else {
        $logger->error("Telford nightly cronjob: delivery failed for $filename: $result->{error}");
        $self->_add_run_log(
            {
                status         => 'error',
                invoices_found => scalar @{ $batch->{invoice_ids} },
                filename       => $filename,
                message        => "[$from to $to] Delivery failed: $result->{error}",
            }
        );
    }

    return $result->{success};
}

=head3 report

Staff Tools > Reports entry point: a two-step manual run (pick a date
range, then either preview it or download/deliver it). Running step 2
generates a real batch (consumes a batch id, marks its invoices
submitted) - there's no separate no-op "preview" mode, since previewing
a batch and sending it are the same generation step for this format.

=cut

sub report {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};

    if ( ( $cgi->param('page') // '' ) eq 'manage_submissions' ) {
        $self->manage_submissions();
    }
    elsif ( $cgi->param('from') ) {
        $self->report_step2();
    }
    else {
        $self->report_step1();
    }
}

sub report_step1 {
    my ($self) = @_;
    my $template = $self->get_template( { file => 'report-step1.tt' } );
    $self->output_html( $template->output() );
}

sub report_step2 {
    my ($self) = @_;
    my $cgi  = $self->{cgi};
    my $from = $cgi->param('from');
    my $to   = $cgi->param('to');

    my $batch = $self->generate_batch( { from => $from, to => $to } );

    if ( $batch->{num_trans} ) {
        my $filename = $self->_generate_filename( $batch->{batch_id} );
        my $result   = $self->_deliver_batch( $batch, $filename );

        if ( $result->{success} ) {
            $self->mark_invoices_submitted( $batch->{invoice_ids}, $filename, 'manual' );
            $self->_add_run_log(
                {
                    status         => 'success',
                    invoices_found => scalar @{ $batch->{invoice_ids} },
                    filename       => $filename,
                    message        => "[$from to $to] (manual) Delivered $filename",
                }
            );
            $batch->{filename} = $filename;
            $batch->{delivered} = 1;
        }
        else {
            $self->_add_run_log(
                {
                    status         => 'error',
                    invoices_found => scalar @{ $batch->{invoice_ids} },
                    filename       => $filename,
                    message        => "[$from to $to] (manual) Delivery failed: $result->{error}",
                }
            );
            $batch->{error} = $result->{error};
        }
    }

    my $template = $self->get_template( { file => 'report-step2.tt' } );
    $template->param(
        from  => $from,
        to    => $to,
        batch => $batch,
    );
    $self->output_html( $template->output() );
}

=head3 tool

Staff Tools entry point: shows recent run history and lets staff clear
a submitted invoice so it's picked up again on the next run (e.g. after
fixing bad data and needing to resend).

=cut

sub tool {
    my ($self) = @_;
    $self->manage_submissions();
}

sub manage_submissions {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $dbh = C4::Context->dbh;

    if ( ( $cgi->param('action') // '' ) eq 'clear' ) {
        my @to_clear = $cgi->multi_param('invoiceid');
        if (@to_clear) {
            my $placeholders = join( ',', ('?') x @to_clear );
            $dbh->do( "DELETE FROM plugin_telford_submitted_invoices WHERE invoiceid IN ($placeholders)", undef, @to_clear );
        }
    }

    my $submitted = $dbh->selectall_arrayref(
        q{
        SELECT s.invoiceid, i.invoicenumber, s.submitted_at, s.submitted_by, s.filename
        FROM plugin_telford_submitted_invoices s
        LEFT JOIN aqinvoices i ON i.invoiceid = s.invoiceid
        ORDER BY s.submitted_at DESC
    }, { Slice => {} }
    );

    my $runs = $dbh->selectall_arrayref(
        q{
        SELECT run_at, status, invoices_found, filename, message
        FROM plugin_telford_cron_runs
        ORDER BY run_at DESC
        LIMIT 30
    }, { Slice => {} }
    );

    my $template = $self->get_template( { file => 'manage-submissions.tt' } );
    $template->param(
        submitted_invoices => $submitted,
        runs               => $runs,
        CLASS              => ref($self),
    );
    $self->output_html( $template->output() );
}

=head3 _deliver_batch

Writes the batch text to the configured SFTP/FTP transport, or to a
local C<output/> directory inside the plugin's own bundle path if no
transport is configured. Returns C<{ success => 1 }> or
C<{ success => 0, error => $message }>.

=cut

sub _deliver_batch {
    my ( $self, $batch, $filename ) = @_;

    my $output = $self->retrieve_data('output') || 'file';

    if ( $output eq 'upload' ) {
        my $transport = Koha::File::Transports->find( $self->retrieve_data('transport_server') );
        return { success => 0, error => 'No transport server configured' } unless $transport;

        eval { $transport->connect };
        return { success => 0, error => "Connection failed: $@" } if $@;

        open my $fh, '<', \$batch->{text} or return { success => 0, error => "Unable to open in-memory handle: $!" };
        my $ok = $transport->upload_file( $fh, $filename );
        close $fh;

        return $ok ? { success => 1 } : { success => 0, error => 'Upload failed' };
    }
    else {
        my $dir = File::Spec->catdir( $self->bundle_path, 'output' );
        eval { make_path($dir) };
        return { success => 0, error => "Unable to create $dir: $@" } if $@;

        my $path = File::Spec->catfile( $dir, $filename );
        open my $fh, '>', $path or return { success => 0, error => "Unable to open $path: $!" };
        print $fh $batch->{text};
        close $fh;

        return { success => 1, path => $path };
    }
}

sub _generate_filename {
    my ( $self, $batch_id ) = @_;
    return "TELFORD_" . ( $batch_id // '' ) . "_" . dt_from_string()->strftime('%Y%m%d%H%M%S') . ".txt";
}

sub _add_run_log {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do(
        q{INSERT INTO plugin_telford_cron_runs (run_at, status, invoices_found, filename, message) VALUES (NOW(), ?, ?, ?, ?)},
        undef,
        $args->{status}         // 'success',
        $args->{invoices_found} // 0,
        $args->{filename},
        $args->{message},
    );
}

sub _yyyymmdd {
    my ($date) = @_;
    return '' unless $date;
    my $dt = ref($date) ? $date : dt_from_string($date);
    return $dt->strftime('%Y%m%d');
}

1;
