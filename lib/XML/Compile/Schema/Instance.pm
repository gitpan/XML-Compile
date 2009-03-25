# Copyrights 2006-2009 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.06.

use warnings;
use strict;

package XML::Compile::Schema::Instance;
use vars '$VERSION';
$VERSION = '1.03';


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

    $self->{filename} = $args->{filename};
    $self->{source}   = $args->{source};

    $self->{$_}       = {} for @defkinds, 'sgs', 'import';
    $self->{include}  = [];

    $self->_collectTypes($top, $args);
    $self;
}


sub targetNamespace { shift->{tns} }
sub schemaNamespace { shift->{xsd} }
sub schemaInstance  { shift->{xsi} }
sub source          { shift->{source} }
sub filename        { shift->{filename} }


sub type($) { $_[0]->{types}{$_[1]} }


sub element($) { $_[0]->{elements}{$_[1]} }


sub id($) { $_[0]->{ids}{$_[1]} }


sub ids()             { keys %{shift->{ids}} }
sub elements()        { keys %{shift->{element}} }
sub attributes()      { keys %{shift->{attributes}} }
sub attributeGroups() { keys %{shift->{attributeGroup}} }
sub groups()          { keys %{shift->{group}} }
sub simpleTypes()     { keys %{shift->{simpleType}} }
sub complexTypes()    { keys %{shift->{complexType}} }


sub types()           { ($_[0]->simpleTypes, $_[0]->complexTypes) }


sub substitutionGroups() { keys %{shift->{sgs}} }


sub substitutionGroupMembers($) { @{ $_[0]->{sgs}{ $_[1] } || [] }; }


# Fast!
sub mergeSubstGroupsInto($)
{   my ($self, $h) = @_;
    while( my($type, $members) = each %{$self->{sgs}})
    {   push @{$h->{$type}}, @$members;
    }
}


my %skip_toplevel = map { ($_ => 1) } qw/annotation notation redefine/;

sub _collectTypes($$)
{   my ($self, $schema, $args) = @_;

    $schema->localName eq 'schema'
        or panic "requires schema element";

    my $xsd = $self->{xsd} = $schema->namespaceURI || '<none>';
    if(length $xsd)
    {   my $def = $self->{def}
          = XML::Compile::Schema::Specs->predefinedSchema($xsd)
            or error __x"schema namespace `{namespace}' not (yet) supported"
                  , namespace => $xsd;

        $self->{xsi} = $def->{uri_xsi};
    }
    my $tns = $self->{tns} = $schema->getAttribute('targetNamespace') || '';

    my $efd = $self->{efd}
       = $args->{element_form_default}
      || $schema->getAttribute('elementFormDefault')
      || 'unqualified';

    my $afd = $self->{afd}
       = $args->{attribute_form_default}
      || $schema->getAttribute('attributeFormDefault')
      || 'unqualified';

    $self->{types} = {};
    $self->{ids}   = {};

  NODE:
    foreach my $node ($schema->childNodes)
    {   next unless $node->isa('XML::LibXML::Element');
        my $local = $node->localName;
        my $myns  = $node->namespaceURI || '';
        $myns eq $xsd
            or error __x"schema element `{name}' not in schema namespace {ns} but {other}"
                 , name => $local, ns => $xsd, other => ($myns || '<none>');

        next if $skip_toplevel{$local};

        if($local eq 'import')
        {   my $namespace = $node->getAttribute('namespace')      || $tns;
            my $location  = $node->getAttribute('schemaLocation') || '';
            push @{$self->{import}{$namespace}}, $location;
            next NODE;
        }

        if($local eq 'include')
        {   my $location  = $node->getAttribute('schemaLocation')
                or error __x"include requires schemaLocation attribute at line {linenr}"
                   , linenr => $node->line_number;

            push @{$self->{include}}, $location;
            next NODE;
        }

        my $tag   = $node->getAttribute('name');
        my $ref;
        unless(defined $tag && length $tag)
        {   $ref = $tag = $node->getAttribute('ref')
               or error __x"schema component {local} without name or ref at line {linenr}"
                    , local => $local, linenr => $node->line_number;

            $tag =~ s/.*?\://;
        }

        my $nns = $node->namespaceURI || '';
        error __x"schema component `{name}' must be in namespace {ns}"
          , name => $tag, ns => $xsd
              if $xsd && $nns ne $xsd;

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

        my $abstract = $node->getAttribute('abstract') || 'false';
        my $final    = $node->getAttribute('final')    || 'false';

        my ($af, $ef) = ($afd, $efd);
        if($local eq 'element')
        {   if(my $f = $node->getAttribute('form')) { $ef = $f }
        }
        elsif($local eq 'attribute')
        {   if(my $f = $node->getAttribute('form')) { $af = $f }
        }

        unless($defkinds{$local})
        {   mistake __x"ignoring unknown definition-type {local}", type => $local;
            next;
        }

        my $info  = $self->{$local}{$label} =
          { type => $local, id => $id, node => $node
          , full => pack_type($ns, $name), ref => $ref, sg => $sg
          , ns => $ns,  name => $name, prefix => $prefix
          , afd => $af, efd => $ef, schema => $self
          , abstract => ($abstract eq 'true' || $abstract eq '1')
          , final => ($final eq 'true' || $final eq '1')
          };
        weaken($info->{schema});

        # Id's can also be set on nested items, but these are ignored
        # for now...
        $self->{ids}{"$ns#$id"} = $info
           if defined $id;

        push @{$self->{sgs}{$sg}}, $info
           if defined $sg;
    }

    $self;
}


sub includeLocations() { @{shift->{include}} }


sub imports() { keys %{shift->{import}} }


sub importLocations($)
{   my $locs = $_[0]->{import}{$_[1]};
    $locs ? @$locs : ();
}


sub printIndex(;$)
{   my $self   = shift;
    my $fh     = @_ % 2 ? shift : select;
    my %args   = @_;

    $fh->print("namespace: ", $self->targetNamespace, "\n");
    if(defined(my $filename = $self->filename))
    {   $fh->print(" filename: $filename\n");
    }
    elsif(defined(my $source = $self->source))
    {   $fh->print("   source: $source\n");
    }

    my @kinds
     = ! defined $args{kinds}      ? @defkinds
     : ref $args{kinds} eq 'ARRAY' ? @{$args{kinds}}
     :                               $args{kinds};

    my $list_abstract = exists $args{list_abstract} ? $args{list_abstract} : 1;

    foreach my $kind (@kinds)
    {   my $table = $self->{$kind};
        keys %$table or next;
        $fh->print("  definitions of ${kind}s:\n") if @kinds > 1;
        foreach (sort {$a->{name} cmp $b->{name}} values %$table)
        {   next if $_->{abstract} && ! $list_abstract;
            my $abstract = $_->{abstract} ? ' [abstract]' : '';
            my $final    = $_->{final}    ? ' [final]' : '';
            $fh->print("    $_->{name}$abstract$final\n");
        }
    }
}


sub find($$) { $_[0]->{$_[1]}{$_[2]} }

1;
