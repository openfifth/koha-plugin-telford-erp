package Koha::Plugin::Com::OpenFifth::Telford::Format;

use Modern::Perl;

use Carp qw(croak);

our $RECORD_LENGTH = 120;

# Field layout for the batch header record (Appendix A).
our @HEADER_FIELDS = (
    { name => 'batch_id',      width => 4,  align => 'left' },
    { name => 'num_trans',     width => 5,  align => 'right' },
    { name => 'total_debits',  width => 17, align => 'right' },
    { name => 'total_credits', width => 17, align => 'right' },
    { name => 'batch_date',    width => 8,  align => 'left' },
    { name => 'filler',        width => 69, align => 'left' },
);

# Field layout for the line detail record (Appendix B).
our @LINE_FIELDS = (
    { name => 'batch_id',     width => 4,  align => 'left' },
    { name => 'account',      width => 5,  align => 'left' },
    { name => 'costc',        width => 4,  align => 'left' },
    { name => 'subcc',        width => 4,  align => 'left' },
    { name => 'analysis',     width => 3,  align => 'left' },
    { name => 'tax_code',     width => 2,  align => 'left' },
    { name => 'amount',       width => 10, align => 'right' },
    { name => 'vat_amount',   width => 10, align => 'right' },
    { name => 'description',  width => 10, align => 'right' },
    { name => 'trans_date',   width => 8,  align => 'left' },
    { name => 'voucher_date', width => 8,  align => 'left' },
    { name => 'ext_inv_ref',  width => 10, align => 'left' },
    { name => 'apar_id',      width => 6,  align => 'left' },
    { name => 'filler',       width => 36, align => 'left' },
);

# Constant values fixed by the spec for every line detail record - not
# derived from any Koha data. See docs/spec.md Appendix B.
our $ACCOUNT  = 'R4016';
our $COSTC    = 'LLAA';
our $ANALYSIS = 'Z99';

our @SUBCC_CODES = qw(LBAB LBPB LBPP LBRO);

sub pad_field {
    my (%args) = @_;

    my $value = defined $args{value} ? "$args{value}" : '';
    my $width = $args{width};
    my $align = $args{align} || 'left';

    my $name = $args{name} // '?';
    croak "Value '$value' for field '$name' exceeds width $width"
        if length($value) > $width;

    my $pad = $width - length($value);
    return $align eq 'right'
        ? ( ' ' x $pad ) . $value
        : $value . ( ' ' x $pad );
}

sub _build_record {
    my ( $fields, $values ) = @_;

    my $record = join '', map {
        pad_field( %$_, value => $values->{ $_->{name} } )
    } @$fields;

    croak "Record length mismatch: got " . length($record) . ", expected $RECORD_LENGTH"
        unless length($record) == $RECORD_LENGTH;

    return $record;
}

sub build_header_record {
    my ($values) = @_;
    return _build_record( \@HEADER_FIELDS, { filler => '', %$values } );
}

sub build_line_record {
    my ($values) = @_;
    return _build_record( \@LINE_FIELDS, { filler => '', %$values } );
}

# Batch IDs run K001-K999 and wrap back round to K001. $current is the
# last-used sequence number (0 before anything has ever been sent).
sub next_batch_number {
    my ($current) = @_;
    $current //= 0;
    return ( $current % 999 ) + 1;
}

sub format_batch_id {
    my ($number) = @_;
    return sprintf( 'K%03d', $number );
}

# Koha stores money as pounds (decimal); the interface wants integer pence,
# right-justified, with a literal '-' immediately before the digits for
# credits (spec: "place a minus figure before the amount").
sub format_pence {
    my ( $pounds, $width ) = @_;
    $pounds //= 0;
    my $pence = int( sprintf( '%.0f', $pounds * 100 ) );
    return pad_field( value => $pence, width => $width, align => 'right' );
}

# Only two tax codes are valid on this interface: 01 (standard, 20%) and
# 04 (zero-rated, 0%) - see docs/spec.md Appendix B, tax_code notes.
sub tax_code_for_rate {
    my ($rate) = @_;
    return 'ZZ' unless defined $rate;
    return ( abs( $rate - 0.20 ) < 0.0001 ) ? '01' : '04';
}

# The line 'description' field is the Koha-generated transaction number,
# used only for cross-referencing back to Koha - zero-padded to 10 digits.
sub format_description {
    my ($id) = @_;
    return sprintf( '%010d', $id );
}

1;
