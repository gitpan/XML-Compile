# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.03.

use warnings;
use strict;

package XML::Compile::Schema::Instance;
use vars '$VERSION';
$VERSION = '0.64';

use Log::Report 'xml-compile', syntax => 'SHORT';
use XML::Compile::Schema::Specs;
use XML::Compile::Util qw/pack_type/;

use Scalar::Util       qw/weaken/;

my @defkinds = qw/element attribute simpleType complexType
                  attributeGroup group/;
my %defkinds = map { ($_ => 1) } @defkinds;


sub new($@)
{   my $class = shift;
    (bless {}, $class)->init( {top => @_} );
}

sub init($)
{   my ($self, $args) = @_;
    my $top = $args->{top};
    defined $top && $top->isa('XML::LibXML::Node')
        or panic "instance is based on XML node";

    $self->{$_} = {} for @defkinds, 'sgs';

    $self->_collectTypes($top);
    $self;
}


sub targetNamespace { shift->{tns} }
sub schemaNamespace { shift->{xsd} }
sub schemaInstance  { shift->{xsi} }


sub type($) { $_[0]->{types}{$_[1]} }


sub element($) { $_[0]->{elements}{$_[1]} }


sub ids()             { keys %{shift->{ids}} }
sub elements()        { keys %{shift->{element}} }
sub attributes()      { keys %{shift->{attributes}} }
sub attributeGroups() { keys %{shift->{attributeGroup}} }
sub groups()          { keys %{shift->{group}} }
sub simpleTypes()     { keys %{shift->{simpleType}} }
sub complexTypes()    { keys %{shift->{complexType}} }


sub types()           { ($_[0]->simpleTypes, $_[0]->complexTypes) }


sub substitutionGroups() { keys %{shift->{sgs}} }


sub substitutionGroupMembers($)
{   my $sgs = shift->{sgs}      or return ();
    my $sg  = $sgs->{ (shift) } or return ();
    @$sg;
}


my %skip_toplevel = map { ($_ => 1) }
   qw/annotation import notation include redefine/;

sub _collectTypes($)
{   my ($self, $schema) = @_;

    $schema->localName eq 'schema'
        or panic "requires schema element";

    my $xsd = $self->{xsd} = $schema->namespaceURI || '';
    if(length $xsd)
    {   my $def = $self->{def}
          = XML::Compile::Schema::Specs->predefinedSchema($xsd)
            or error __x"schema namespace `{namespace}' not (yet) supported"
                  , namespace => $xsd;

        $self->{xsi} = $def->{uri_xsi};
    }
    my $tns = $self->{tns} = $schema->getAttribute('targetNamespace') || '';

    my $efd = $self->{efd}
      = $schema->getAttribute('elementFormDefault')   || 'unqualified';

    my $afd = $self->{afd}
      = $schema->getAttribute('attributeFormDefault') || 'unqualified';

    $self->{types} = {};
    $self->{ids}   = {};

    foreach my $node ($schema->childNodes)
    {   next unless $node->isa('XML::LibXML::Element');
        my $local = $node->localName;

        next if $skip_toplevel{$local};

        my $tag   = $node->getAttribute('name');
        my $ref;
        unless(defined $tag && length $tag)
        {   $ref = $tag = $node->getAttribute('ref')
               or error __x"schema component {local} without name or ref"
                      , local => $local;
            $tag =~ s/.*?\://;
        }

        error __x"schema component `{name}' must be in {namespace}"
            , name => $tag, namespace => $xsd
            if $xsd && $node->namespaceURI ne $xsd;

        my $id    = $schema->getAttribute('id');

        my ($prefix, $name)
         = index($tag, ':') >= 0 ? split(/\:/,$tag,2) : ('', $tag);

        # prefix existence enforced by xml parser
        my $ns    = length $prefix ? $node->lookupNamespaceURI($prefix) : $tns;
        my $label = pack_type $ns, $name;

        my $sg;
        if(my $subst = $node->getAttribute('substitutionGroup'))
        {    my ($sgpref, $sgname)
              = index($subst, ':') >= 0 ? split(/\:/,$subst,2) : ('', $subst);
             my $sgns = length $sgpref ? $node->lookupNamespaceURI($sgpref) : $tns;
             defined $sgns
                or error __x"no namespace for {what} in substitutionGroup {group}"
                       , what => (length $sgpref ? "'$sgpref'" : 'target')
                       , group => $tag;
             $sg = pack_type $sgns, $sgname;
        }

        unless($defkinds{$local})
        {   mistake __x"ignoring unknown definition-type {local}", type => $local;
            next;
        }

        my $info  = $self->{$local}{$label} =
          { type => $local, id => $id,   node => $node
          , full => pack_type($ns, $name)
          , ns   => $ns,  name => $name, prefix => $prefix
          , afd  => $afd, efd  => $efd,  schema => $self
          , ref  => $ref, sg   => $sg
          };
        weaken($self->{schema});

        # Id's can also be set on nested items, but these are ignored
        # for now...
        $self->{ids}{"$ns#$id"} = $info
           if defined $id;

        push @{$self->{sgs}{$sg}}, $info
           if defined $sg;
    }

    $self;
}


sub printIndex(;$)
{   my $self  = shift;
    my $fh    = shift || select;

    $fh->print("namespace: ", $self->targetNamespace, "\n");
    foreach my $kind (@defkinds)
    {   my $table = $self->{$kind};
        keys %$table or next;
        $fh->print("  definitions of $kind objects:\n");
        $fh->print("    ", $_->{name}, "\n")
            for sort {$a->{name} cmp $b->{name}}
                  values %$table;
    }
}


sub find($$) { $_[0]->{$_[1]}{$_[2]} }

1;
