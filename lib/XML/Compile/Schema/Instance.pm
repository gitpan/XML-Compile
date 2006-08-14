
use warnings;
use strict;

package XML::Compile::Schema::Instance;
use vars '$VERSION';
$VERSION = '0.02';

use Carp;

use XML::Compile::Schema::Specs;

use Scalar::Util   qw/weaken/;


sub new($@)
{   my $class = shift;
    (bless {}, $class)->init( {top => @_} );
}

sub init($)
{   my ($self, $args) = @_;
    my $top = $args->{top};
    defined $top && $top->isa('XML::LibXML::Node')
       or croak "ERROR: instance based on XML node.";

    $self->_collectTypes($top);
    $self;
}


sub targetNamespace { shift->{tns} }
sub schemaNamespace { shift->{xsd} }
sub schemaInstance  { shift->{xsi} }


sub ids() {keys %{shift->{ids}}}


sub types() { keys %{shift->{types}} }


sub type($) { $_[0]->{types}{$_[1]} }


sub elements() { keys %{shift->{elements}} }


sub element($) { $_[0]->{elements}{$_[1]} }


my %as_element = map { ($_ => 1) } qw/element group attributeGroup/;

sub _collectTypes($)
{   my ($self, $schema) = @_;

    $schema->localname eq 'schema'
       or croak "ERROR: requires schema element";

    my $xsd = $self->{xsd} = $schema->namespaceURI;
    my $def = $self->{def} =
       XML::Compile::Schema::Specs->predefinedSchema($xsd)
         or croak "ERROR: schema namespace $xsd not (yet) supported";

    my $xsi = $self->{xsi} = $def->{uri_xsi};
    my $tns = $self->{tns} = $schema->getAttribute('targetNamespace') || '';

    my $efd = $self->{efd}
      = $schema->getAttribute('elementFormDefault')   || 'unqualified';

    my $afd = $self->{afd}
      = $schema->getAttribute('attributeFormDefault') || 'unqualified';

    $self->{types} = {};
    $self->{ids}   = {};

    foreach my $node ($schema->childNodes)
    {   next unless $node->isa('XML::LibXML::Element');
        my $local = $node->localname;

        next if $local eq 'annotation';
        next if $local eq 'import';

        my $tag   = $node->getAttribute('name');
        my $ref;
        unless(defined $tag && length $tag)
        {   $ref = $tag = $node->getAttribute('ref')
               or croak "ERROR: schema component $local without name or ref";
            $tag =~ s/.*?\://;
        }

        $node->namespaceURI eq $xsd
           or croak "ERROR: schema component $tag shall be in $xsd";

        my $id    = $schema->getAttribute('id');

        my ($prefix, $name)
         = index($tag, ':') >= 0
         ? split(/\:/,$tag,2)
         : ('', $tag);

        # prefix existence enforced by xml parser
        my $ns = length $prefix ? $node->lookupNamespaceURI($prefix) : $tns;

        my $label = "{$ns}$name";
        my $class = $as_element{$local} ? 'elements' : 'types';
        my $info  = $self->{$class}{$label}
          = { type => $local, id => $id,   node => $node, full => "{$ns}$name"
            , ns   => $ns,  name => $name, prefix => $prefix
            , afd  => $afd, efd  => $efd,  schema => $self
            , ref  => $ref
            };
        weaken($self->{schema});

        $self->{ids}{"$ns#$id"} = $info
           if defined $id;
    }

    $self;
}


sub printIndex(;$)
{   my $self  = shift;
    my $fh    = shift || select;

    $fh->printf("  %11s %s\n", $_->{type}, $_->{name})
      for sort {$a->{name} cmp $b->{name}}
             values %{$self->{types}}, values %{$self->{elements}}
}


1;
