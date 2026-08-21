package Koha::Plugin::Com::OpenFifth::Telford;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use Koha::DateUtils;

our $VERSION = '0.0.0';
our $MINIMUM_VERSION = "24.11.00.000";

our $metadata = {
    name            => 'Telford ERP Integration',
    author          => 'Open Fifth',
    description     => "A plugin to manage finance integration for Telford with their ERP (PL) finance system",
    date_authored   => '2026-08-21',
    date_updated    => '2026-08-21',
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

sub install {
    my ( $self, $args ) = @_;
    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;
    return 1;
}

sub uninstall {
    my ( $self, $args ) = @_;
    return 1;
}

1;
