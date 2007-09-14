# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.
use warnings;
use strict;

package XML::Compile::SOAP::SOAP12;
use vars '$VERSION';
$VERSION = '0.54';
use base 'XML::Compile::SOAP';

use Log::Report 'xml-compile', syntax => 'SHORT';

my $base  = 'http://www.w3.org/2003/05';

my $role  = "$base/soap-envelope/role";
my %roles =
 ( NEXT     => "$role/next"
 , NONE     => "$role/none"
 , ULTIMATE => "$role/ultimateReceiver"
 );


sub new($@)
{   my $class = shift;
    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    my $env = $args->{envelope_ns} ||= "$base/soap-envelope";
    my $enc = $args->{encoding_ns} ||= "$base/soap-encoding";
    $self->SUPER::init($args);

    my $rpc = $self->{rpc} = $args->{rpc} || "$base/soap-rpc";

    my $schemas = $self->schemas;
    $schemas->importDefinitions($env);
    $schemas->importDefinitions($enc);
    $schemas->importDefinitions($rpc);
    $self;
}


sub rpcNS() {shift->{rpc}}

sub _writer($)
{   my ($self, $args) = @_;

    error __x"headerfault does only exist in SOAP1.1"
        if $args->{header_fault};

}


sub roleAbbreviation($) { $roles{$_[1]} || $_[1] }

1;
