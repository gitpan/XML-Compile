
use warnings;
use strict;

package XML::Compile;
use vars '$VERSION';
$VERSION = '0.01';

use XML::LibXML;
use Carp;


sub new(@)
{   my ($class, $top) = (shift, shift);
    (bless {}, $class)->init( {top => $top, @_} );
}

sub init($)
{   my ($self, $args) = @_;

    my $top = $args->{top}
       or croak "ERROR: XML definition not specified";

    $self->{XC_top}
      = ref $top && $top->isa('XML::LibXML::Node') ? $top
      : $self->parse(\$top);

    $self;
}

# Extend this later with other input mechamisms.
sub parse($)
{   my ($thing, $data) = @_;
    my $xml = XML::LibXML->new->parse_string($$data);
    defined $xml ? $xml->documentElement : undef;
}


sub top() {shift->{XC_top}}


sub walkTree($$)
{   my ($self, $node, $code) = @_;
    if($code->($node))
    {   $self->walkTree($_, $code)
            foreach $node->getChildNodes;
    }
}


1;
