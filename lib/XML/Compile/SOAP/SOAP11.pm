# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.
use warnings;
use strict;

package XML::Compile::SOAP::SOAP11;
use vars '$VERSION';
$VERSION = '0.53';
use base 'XML::Compile::SOAP';

use Log::Report 'xml-compile', syntax => 'SHORT';
use XML::Compile::Util  qw/pack_type/;

my $base       = 'http://schemas.xmlsoap.org/soap';
my $actor_next = "$base/actor/next";


sub new($@)
{   my $class = shift;
    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    my $env = $args->{envelope_ns} ||= "$base/envelope/";
    my $enc = $args->{encoding_ns} ||= "$base/encoding/";
    $self->SUPER::init($args);

    my $schemas = $self->schemas;
    $schemas->importDefinitions($env);
    $schemas->importDefinitions($enc);
    $self;
}


#sub compile

sub _writer_header_env($$$$)
{   my ($self, $code, $allns, $understand, $actors) = @_;
    $understand || $actors or return $code;

    my $schema = $self->schemas;
    my $envns  = $self->envelopeNS;

    # Cannot precompile everything, because $doc is unknown
    my $ucode;
    if($understand)
    {   my $u_w = $self->{soap11_u_w} ||=
          $schema->compile
            ( WRITER => pack_type($envns, 'mustUnderstand')
            , output_namespaces    => $allns
            , include_namespaces   => 0
            );

        $ucode =
        sub { my $el = $code->(@_) or return ();
              my $un = $u_w->($_[0], 1);
              $el->addChild($un) if $un;
              $el;
            };
    }
    else {$ucode = $code}

    if($actors)
    {   $actors =~ s/\b(\S+)\b/$self->roleAbbreviation($1)/ge;

        my $a_w = $self->{soap11_a_w} ||=
          $schema->compile
            ( WRITER => pack_type($envns, 'actor')
            , output_namespaces    => $allns
            , include_namespaces   => 0
            );

        return
        sub { my $el  = $ucode->(@_) or return ();
              my $act = $a_w->($_[0], $actors);
              $el->addChild($act) if $act;
              $el;
            };
    }

    $ucode;
}

sub _writer($)
{   my ($self, $args) = @_;
    $args->{prefix_table}
     = [ ''         => 'do not use'
       , 'SOAP-ENV' => $self->envelopeNS
       , 'SOAP-ENC' => $self->encodingNS
       , xsd        => 'http://www.w3.org/2001/XMLSchema'
       , xsi        => 'http://www.w3.org/2001/XMLSchema-instance'
       ];

    $self->SUPER::_writer($args);
}


sub roleAbbreviation($) { $_[1] eq 'NEXT' ? $actor_next : $_[1] }

1;
