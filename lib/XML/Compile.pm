
use warnings;
use strict;

package XML::Compile;

use XML::LibXML;
use Carp;

=chapter NAME

XML::Compile - Compilation based XML processing

=chapter SYNOPSIS

 # See XML::Compile::Schema

=chapter DESCRIPTION

Many applications which process data-centric XML do that based on a
nice specification, expressed in an XML Schema.  C<XML::Compile> reads
and writes XML data with the help of such schema's.  On the Perl side,
it uses a tree of nested hashes with the same structure.

Where other Perl modules, like M<SOAP::WSDL> help you using these schema's
(often with a lot of run-time (XPath) searches), this module takes a
different approach: in stead of run-time processing of the specification,
it will first compile the expected structure into real Perl, and then
use that to process the data.

There are many perl modules with the same as this one: translate
between XML and nested hashes.  However, there are a few serious
differences:  because the schema is used here, we make sure we only
handle correct data.  Data-types are formatted and processed correctly;
for instance, C<integer> does accept huge values (at least 18 digits) as
the specification prescribes.  Also more complex data-types like C<list>,
C<union>, and C<substitutionGroup> (unions on complex type level) are
supported, which is rarely the case in other modules.

=chapter METHODS

=section Constructors
These constructors are base class methods, and therefore not directly
accessed.

=method new TOP, OPTIONS

The TOP is a M<XML::LibXML::Document> (a direct result from parsing
activities) or a M<XML::LibXML::Node> (a sub-tree).  In any case,
a product of the XML::LibXML module (based on libxml2).

If you have compiled/collected all the information you need,
then simply terminate the compiler object: that will clean-up
the XML::LibXML objects.

=cut

sub new(@)
{   my ($class, $top) = (shift, shift);
    croak "ERROR: you should instantiate a sub-class, $class is base only"
        if $class eq __PACKAGE__;

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

=section Accessors

=method top
Returns the XML::LibXML object tree which needs to be compiled.

=cut

sub top() {shift->{XC_top}}

=section Filters

=method walkTree NODE, CODE
Walks the whole tree from NODE downwards, calling the CODE reference
for each NODE found.  When the routine returns false, the child
nodes will be skipped.

=cut

sub walkTree($$)
{   my ($self, $node, $code) = @_;
    if($code->($node))
    {   $self->walkTree($_, $code)
            foreach $node->getChildNodes;
    }
}

=section Compilers

=cut

1;
