use Modern::Perl;
use Test::More tests => 7;
use Test::Exception;
use FindBin qw($Bin);
use lib "$Bin/..";

use Koha::Plugin::Com::OpenFifth::Telford::Format qw();

subtest 'pad_field' => sub {
    plan tests => 4;
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::pad_field( value => 'LBAB', width => 4, align => 'left' ),
        'LBAB', 'exact-width left align is unchanged' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::pad_field( value => 'K1', width => 4, align => 'left' ),
        'K1  ', 'left align pads on the right' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::pad_field( value => '6679', width => 10, align => 'right' ),
        '      6679', 'right align pads on the left' );
    throws_ok {
        Koha::Plugin::Com::OpenFifth::Telford::Format::pad_field( value => 'TOOLONGVALUE', width => 4, align => 'left' );
    } qr/exceeds width/, 'oversized value dies rather than truncating silently';
};

subtest 'format_pence' => sub {
    plan tests => 4;
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( 66.79, 10 ), '      6679', 'positive amount in pence' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( -5.00, 10 ), '      -500', 'credit note carries a leading minus' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( 0, 10 ), '         0', 'zero amount' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( undef, 10 ), '         0', 'undef amount treated as zero' );
};

subtest 'tax_code_for_rate' => sub {
    plan tests => 4;
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::tax_code_for_rate(0.20), '01', '20% is standard rate' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::tax_code_for_rate(0),    '04', '0% is zero rated' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::tax_code_for_rate(0.05), '04', 'any non-20% rate falls back to zero rated per spec' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::tax_code_for_rate(undef), 'ZZ', 'missing rate is flagged rather than guessed' );
};

subtest 'format_description' => sub {
    plan tests => 2;
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::format_description(101), '0000000101', 'ordernumber is zero-padded to 10 digits' );
    is( length( Koha::Plugin::Com::OpenFifth::Telford::Format::format_description(1) ), 10, 'always exactly 10 characters' );
};

subtest 'batch id sequencing' => sub {
    plan tests => 4;
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::next_batch_number(0),   1,   'first ever batch is 1' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::next_batch_number(1),   2,   'increments normally' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::next_batch_number(999), 1,   'wraps from 999 back to 1' );
    is( Koha::Plugin::Com::OpenFifth::Telford::Format::format_batch_id(1),     'K001', 'formatted with K prefix and zero padding' );
};

subtest 'build_header_record' => sub {
    plan tests => 2;
    my $record = Koha::Plugin::Com::OpenFifth::Telford::Format::build_header_record(
        {   batch_id      => 'K001',
            num_trans     => 10,
            total_debits  => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( 1454.06, 17 ),
            total_credits => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( 0,       17 ),
            batch_date    => '20260804',
        }
    );
    is( length($record), 120, 'header record is always 120 characters' );
    is( substr( $record, 0, 4 ) . substr( $record, 4, 5 ) . substr( $record, 43, 8 ),
        'K001   1020260804', 'batch_id, num_trans and batch_date land in their documented byte ranges' );
};

subtest 'build_line_record' => sub {
    plan tests => 2;
    my $record = Koha::Plugin::Com::OpenFifth::Telford::Format::build_line_record(
        {   batch_id     => 'K001',
            account      => $Koha::Plugin::Com::OpenFifth::Telford::Format::ACCOUNT,
            costc        => $Koha::Plugin::Com::OpenFifth::Telford::Format::COSTC,
            subcc        => 'LBPB',
            analysis     => $Koha::Plugin::Com::OpenFifth::Telford::Format::ANALYSIS,
            tax_code     => '04',
            amount       => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( 66.79, 10 ),
            vat_amount   => Koha::Plugin::Com::OpenFifth::Telford::Format::format_pence( 0,     10 ),
            description  => Koha::Plugin::Com::OpenFifth::Telford::Format::format_description(101),
            trans_date   => '20260801',
            voucher_date => '20260731',
            ext_inv_ref  => '7292520514',
            apar_id      => '303',
        }
    );
    is( length($record), 120, 'line record is always 120 characters' );
    is( substr( $record, 0, 22 ), 'K001R4016LLAALBPBZ9904', 'fixed-constant prefix matches docs/example.tsv line 2' );
};
