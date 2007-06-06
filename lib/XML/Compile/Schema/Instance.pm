# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.00.

use warnings;
use strict;

package XML::Compile::Schema::Instance;
use vars '$VERSION';
$VERSION = '0.18';

use Carp;

use XML::Compile::Schema::Specs;

use Scalar::Util   qw/weaken/;

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
       or croak "ERROR: instance based on XML node.";

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

        next if $skip_toplevel{$local};

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
         = index($tag, ':') >= 0 ? split(/\:/,$tag,2) : ('', $tag);

        # prefix existence enforced by xml parser
        my $ns    = length $prefix ? $node->lookupNamespaceURI($prefix) : $tns;
        my $label = "{$ns}$name";

        my $sg;
        if(my $subst = $node->getAttribute('substitutionGroup'))
        {    my ($sgpref, $sgname)
              = index($subst, ':') >= 0 ? split(/\:/,$subst,2) : ('', $subst);
             my $sgns = length $sgpref ? $node->lookupNamespaceURI($sgpref) : $tns;
             defined $sgns
                or croak "ERROR: no namespace for "
                       . (length $sgpref ? "'$sgpref'" : 'target')
                       . " in substitutionGroup of $tag\n";
             $sg = "{$sgns}$sgname";
        }

        unless($defkinds{$local})
        {   carp "ignoring unknown definition-type $local";
            next;
        }

        my $info  = $self->{$local}{$label}
          = { type => $local, id => $id,   node => $node, full => "{$ns}$name"
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
