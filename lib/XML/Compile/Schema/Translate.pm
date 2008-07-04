# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.05.
use warnings;
use strict;

package XML::Compile::Schema::Translate;
use vars '$VERSION';
$VERSION = '0.87';


# Errors are either in _class 'usage': called with request
#                         or 'schema': syntax error in schema

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util  'first';

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInFacets;
use XML::Compile::Schema::BuiltInTypes qw/%builtin_types/;
use XML::Compile::Util                 qw/pack_type unpack_type type_of_node/;
use XML::Compile::Iterator             ();

# Elements from the schema to ignore: remember, we are collecting data
# from the schema, but only use selective items to produce processors.
# All the sub-elements of these will be ignored automatically
# Don't known whether we ever need the notation... maybe
my $assertions      = qr/assert|report/;
my $id_constraints  = qr/unique|key|keyref/;
my $ignore_elements = qr/^(?:notation|annotation|$id_constraints|$assertions)$/;

my $particle_blocks = qr/^(?:sequence|choice|all|group)$/;
my $attribute_defs  = qr/^(?:attribute|attributeGroup|anyAttribute)$/;


sub compileTree($@)
{   my ($class, $item, %args) = @_;

    my $path   = $item;
    my $self   = bless \%args, $class;

    ref $item
        and panic "expecting an item as point to start at $path";

    my $bricks = $self->{bricks}
        or panic "no bricks to build";

    $self->{nss}
        or panic "no namespace tables";

    my $hooks   = $self->{hooks}
        or panic "no hooks list defined";

    $self->{action}
        or panic "action type is needed";

    my $typemap = $self->{typemap} || {};
    my $nsp     = $self->namespaces;
    foreach my $t (keys %$typemap)
    {   $nsp->find(complexType => $t) || $nsp->find(simpleType => $t)
            or error __x"complex or simpleType {type} for typemap unknown"
                 , type => $t;
    }

    { no strict 'refs';
      "${bricks}::typemap_to_hooks"->($hooks, $typemap);
    }

    if(my $def = $self->namespaces->findID($item))
    {   my $node = $def->{node};
        my $name = $node->localName;
        $item    = $def->{full};
    }

    delete $self->{_created};
    my $produce = $self->topLevel($path, $item);
    delete $self->{_created};

      $self->{include_namespaces}
    ? $self->make(wrapper_ns => $path, $produce, $self->{prefixes})
    : $produce;
}

sub assertType($$$$)
{   my ($self, $where, $field, $type, $value) = @_;
    my $checker = $builtin_types{$type}{check};
    unless(defined $checker)
    {   mistake "useless assert for type $type";
        return;
    }

    return if $checker->($value);

    error __x"field {field} contains '{value}' which is not a valid {type} at {where}"
        , field => $field, value => $value, type => $type, where => $where
        , _class => 'usage';

}

sub extendAttrs($@)
{   my ($self, $in, %add) = @_;

    # new attrs overrule
    unshift @{$in->{attrs}},     @{$add{attrs}}     if $add{attrs};
    unshift @{$in->{attrs_any}}, @{$add{attrs_any}} if $add{attrs_any};
    $in;
}

sub isTrue($) { $_[1] eq '1' || $_[1] eq 'true' }

# This sub cannot set-up the context itself, because changing the
# context requires the use of local() on those values.
sub nsContext($)
{   my ($self, $type) = @_;

    my $elems_qual = $type->{efd} eq 'qualified';
    if(exists $self->{elements_qualified})
    {   my $qual = $self->{elements_qualified} || 0;
        $elems_qual = $qual eq 'ALL' ? 1 : $qual eq 'NONE' ? 0 : $qual;
    }

    my $attrs_qual = $type->{afd} eq 'qualified';
    if(exists $self->{attributes_qualified})
    {   my $qual = $self->{attributes_qualified} || 0;
        $attrs_qual = $qual eq 'ALL' ? 1 : $qual eq 'NONE' ? 0 : $qual;
    }

    ($elems_qual, $attrs_qual, $type->{ns});
}

sub namespaces() { $_[0]->{nss} }

sub make($@)
{   my ($self, $component, $where, @args) = @_;
    no strict 'refs';
    "$self->{bricks}::$component"->($where, $self, @args);
}

sub topLevel($$)
{   my ($self, $path, $fullname) = @_;

    # built-in types have to be handled differently.
    my $internal = XML::Compile::Schema::Specs->builtInType
       (undef, $fullname, sloppy_integers => $self->{sloppy_integers});

    if($internal)
    {   my $builtin = $self->make(builtin => $fullname, undef
            , $fullname, $internal, $self->{check_values});
        my $builder = $self->{action} eq 'WRITER'
          ? sub { $_[0]->createTextNode($builtin->(@_)) }
          : $builtin;
        return $self->make('element_wrapper', $path, $builder);
    }

    my $nss  = $self->namespaces;
    my $top  = $nss->find(element   => $fullname)
            || $nss->find(attribute => $fullname)
       or error __x(( $fullname eq $path
                    ? N__"cannot find element or attribute `{name}'"
                    : N__"cannot find element or attribute `{name}' at {where}"
                    ), name => $fullname, where => $path, _class => 'usage');

    my $node = $top->{node};

    my $elems_qual = $top->{efd} eq 'qualified';
    if(exists $self->{elements_qualified})
    {   my $qual = $self->{elements_qualified} || 0;

           if($qual eq 'ALL')  { $elems_qual = 1 }
        elsif($qual eq 'NONE') { $elems_qual = 0 }
        elsif($qual eq 'TOP')
        {   unless($elems_qual)
            {   # explitly overrule the name-space qualification of the
                # top-level element, which is dirty but people shouldn't
                # use unqualified schemas anyway!!!
                $node->removeAttribute('form');   # when in schema
                $node->setAttribute(form => 'qualified');
                delete $self->{elements_qualified};
                $elems_qual = 0;
            }
        }
        else {$elems_qual = $qual}
    }

    local $self->{elems_qual} = $elems_qual;
    local $self->{tns}        = $top->{ns};
    my $schemans = $node->namespaceURI;

    my $tree = XML::Compile::Iterator->new
      ( $node
      , $path
      , sub { my $n = shift;
                 $n->isa('XML::LibXML::Element')
              && $n->namespaceURI eq $schemans
              && $n->localName !~ $ignore_elements
            }
      );

    delete $self->{_nest};  # reset recursion administration

    my $name = $node->localName;
    my $make
      = $name eq 'element'   ? $self->element($tree)
      : $name eq 'attribute' ? $self->attributeOne($tree)
      : error __x"top-level {full} is not an element or attribute but {name} at {where}"
            , full => $fullname, name => $name, where => $tree->path
            , _class => 'usage';

    my $wrapper = $name eq 'element' ? 'element_wrapper' : 'attribute_wrapper';
    $self->make($wrapper, $path, $make);
}

sub typeByName($$)
{   my ($self, $tree, $typename) = @_;

    #
    # First try to catch build-ins
    #

    my $node  = $tree->node;
    my $code  = XML::Compile::Schema::Specs->builtInType
       ($node, $typename, sloppy_integers => $self->{sloppy_integers});

    if($code)
    {   my $where = $typename;
        my $st = $self->make
          (builtin=> $where, $node, $typename, $code, $self->{check_values});

        return +{ st => $st };
    }

    #
    # Then try own schemas
    #

    my $top = $self->namespaces->find(complexType => $typename)
           || $self->namespaces->find(simpleType  => $typename)
       or error __x"cannot find type {type} at {where}"
            , type => $typename, where => $tree->path, _class => 'usage';

    local @$self{ qw/elems_qual attrs_qual tns/ }
                 = $self->nsContext($top);

    my $typedef  = $top->{type};
    my $typeimpl = $tree->descend($top->{node});

      $typedef eq 'simpleType'  ? $self->simpleType($typeimpl)
    : $typedef eq 'complexType' ? $self->complexType($typeimpl)
    : error __x"expecting simple- or complexType, not '{type}' at {where}"
          , type => $typedef, where => $tree->path, _class => 'schema';
}

sub simpleType($;$)
{   my ($self, $tree, $in_list) = @_;

    $tree->nrChildren==1
       or error __x"simpleType must have exactly one child at {where}"
            , where => $tree->path, _class => 'schema';

    my $child = $tree->firstChild;
    my $name  = $child->localName;
    my $nest  = $tree->descend($child);

    # Full content:
    #    annotation?
    #  , (restriction | list | union)

    my $type
    = $name eq 'restriction' ? $self->simpleRestriction($nest, $in_list)
    : $name eq 'list'        ? $self->simpleList($nest)
    : $name eq 'union'       ? $self->simpleUnion($nest)
    : error __x"simpleType contains '{local}', must be restriction, list, or union at {where}"
          , local => $name, where => $tree->path, _class => 'schema';

    delete @$type{'attrs','attrs_any'};  # spec says ignore attrs
    $type;
}

sub simpleList($)
{   my ($self, $tree) = @_;

    # attributes: id, itemType = QName
    # content: annotation?, simpleType?

    my $per_item;
    my $node  = $tree->node;
    my $where = $tree->path . '#list';

    if(my $type = $node->getAttribute('itemType'))
    {   $tree->nrChildren==0
            or error __x"list with both itemType and content at {where}"
                 , where => $where, _class => 'schema';

        my $typename = $self->rel2abs($where, $node, $type);
        $per_item    = $self->typeByName($tree, $typename);
    }
    else
    {   $tree->nrChildren==1
            or error __x"list expects one simpleType child at {where}"
                 , where => $where, _class => 'schema';

        $tree->currentLocal eq 'simpleType'
            or error __x"list can only have a simpleType child at {where}"
                 , where => $where, _class => 'schema';

        $per_item    = $self->simpleType($tree->descend, 1);
    }

    my $st = $per_item->{st}
        or panic "list did not produce a simple type at $where";

    $per_item->{st} = $self->make(list => $where, $st);
    $per_item->{is_list} = 1;
    $per_item;
}

sub simpleUnion($)
{   my ($self, $tree) = @_;

    # attributes: id, memberTypes = List of QName
    # content: annotation?, simpleType*

    my $node  = $tree->node;
    my $where = $tree->path . '#union';

    # Normal error handling switched off, and check_values must be on
    # When check_values is off, we may decide later to treat that as
    # string, which is faster but not 100% safe, where int 2 may be
    # formatted as float 1.999

    local $self->{check_values} = 1;

    my @types;
    if(my $members = $node->getAttribute('memberTypes'))
    {   foreach my $union (split " ", $members)
        {   my $typename = $self->rel2abs($where, $node, $union);
            my $type = $self->typeByName($tree, $typename);
            my $st   = $type->{st}
                or error __x"union only of simpleTypes, but {type} is complex at {where}"
                     , type => $typename, where => $where, _class => 'schema';

            push @types, $st;
        }
    }

    foreach my $child ($tree->childs)
    {   my $name = $child->localName;
        $name eq 'simpleType'
            or error __x"only simpleType's within union, found {local} at {where}"
                 , local => $name, where => $where, _class => 'schema';

        my $ctype = $self->simpleType($tree->descend($child), 0);
        push @types, $ctype->{st};
    }

    my $do = $self->make(union => $where, @types);
    { st => $do, is_union => 1 };
}

sub simpleRestriction($$)
{   my ($self, $tree, $in_list) = @_;

    # attributes: id, base = QName
    # content: annotation?, simpleType?, facet*

    my $node  = $tree->node;
    my $where = $tree->path . '#sres';

    my $base;
    if(my $basename = $node->getAttribute('base'))
    {   my $typename = $self->rel2abs($where, $node, $basename);
        $base        = $self->typeByName($tree, $typename);
    }
    else
    {   my $simple   = $tree->firstChild
            or error __x"no base in simple-restriction, so simpleType required at {where}"
                   , where => $where, _class => 'schema';

        $simple->localName eq 'simpleType'
            or error __x"simpleType expected, because there is no base attribute at {where}"
                   , where => $where, _class => 'schema';

        $base = $self->simpleType($tree->descend($simple, 'st'));
        $tree->nextChild;
    }

    my $st = $base->{st}
        or error __x"simple-restriction is not a simpleType at {where}"
               , where => $where, _class => 'schema';

    my $do = $self->applySimpleFacets($tree, $st, $in_list);

    $tree->currentChild
        and error __x"elements left at tail at {where}"
                , where => $tree->path, _class => 'schema';

    +{ st => $do };
}

sub applySimpleFacets($$$)
{   my ($self, $tree, $st, $in_list) = @_;

    # partial
    # content: facet*
    # facet = minExclusive | minInclusive | maxExclusive | maxInclusive
    #   | totalDigits | fractionDigits | maxScale | minScale | length
    #   | minLength | maxLength | enumeration | whiteSpace | pattern

    my $where = $tree->path . '#facet';
    my %facets;
    for(my $child = $tree->currentChild; $child; $child = $tree->nextChild)
    {   my $facet = $child->localName;
        last if $facet =~ $attribute_defs;

        my $value = $child->getAttribute('value');
        defined $value
            or error __x"no value for facet `{facet}' at {where}"
                   , facet => $facet, where => $where, _class => 'schema';

           if($facet eq 'enumeration') { push @{$facets{enumeration}}, $value }
        elsif($facet eq 'pattern')     { push @{$facets{pattern}}, $value }
        elsif(!exists $facets{$facet}) { $facets{$facet} = $value }
        else
        {   error __x"facet `{facet}' defined twice at {where}"
                , facet => $facet, where => $where, _class => 'schema';
        }
    }

    return $st
        if $self->{ignore_facets} || !keys %facets;

    my %facets_info = %facets;

    #
    # new facets overrule all of the base-class
    #

    if(defined $facets{totalDigits} && defined $facets{fractionDigits})
    {   my $td = delete $facets{totalDigits};
        my $fd = delete $facets{fractionDigits};
        $facets{totalFracDigits} = [$td, $fd];
    }

    # First the strictly ordered facets, before an eventual split
    # of the list, then the other facets
    my @early;
    foreach my $ordered ( qw/whiteSpace pattern/ )
    {   my $limit = delete $facets{$ordered};
        push @early, builtin_facet($where, $self, $ordered, $limit)
           if defined $limit;
    }

    my @late
      = map { builtin_facet($where, $self, $_, $facets{$_}) }
            keys %facets;

      $in_list
    ? $self->make(facets_list => $where, $st, \%facets_info, \@early, \@late)
    : $self->make(facets => $where, $st, \%facets_info, @early, @late);
}

sub element($)
{   my ($self, $tree) = @_;

    # attributes: abstract, default, fixed, form, id, maxOccurs, minOccurs
    #           , name, nillable, ref, substitutionGroup, type
    # ignored: block, final, targetNamespace additional restrictions
    # content: annotation?
    #        , (simpleType | complexType)?
    #        , (unique | key | keyref)*

    my $node     = $tree->node;
    my $name     = $node->getAttribute('name')
        or error __x"element has no name at {where}"
             , where => $tree->path, _class => 'schema';
    my $ns       = $self->{tns};

    $self->assertType($tree->path, name => NCName => $name);
    my $fullname = pack_type $ns, $name;

    # Handle re-usable fragments

    my $nodeid   = $node->nodePath.'#'.$fullname;
    my $already  = $self->{_created}{$nodeid};
    return $already if $already;

    # Detect recursion

    if(exists $self->{_nest}{$nodeid})
    {   my $outer = \$self->{_nest}{$nodeid};
        return sub { $$outer->(@_) };
    }
    $self->{_nest}{$nodeid} = undef;

    # Construct XML tag to use

    my $where    = $tree->path;
    my $form     = $node->getAttribute('form');
    my $qual
      = !defined $form         ? $self->{elems_qual}
      : $form eq 'qualified'   ? 1
      : $form eq 'unqualified' ? 0
      : error __x"form must be (un)qualified, not `{form}' at {where}"
            , form => $form, where => $tree->path, _class => 'schema';

    my $trans     = $qual ? 'tag_qualified' : 'tag_unqualified';
    my $tag       = $self->make($trans => $where, $node, $name, $ns);

    # Construct type processor

    my ($typename, $type);
    my $nr_childs = $tree->nrChildren;
    if(my $isa = $node->getAttribute('type'))
    {   $nr_childs==0
            or error __x"no childs expected with attribute `type' at {where}"
                   , where => $where, _class => 'schema';

        $typename = $self->rel2abs($where, $node, $isa);
        $type     = $self->typeByName($tree, $typename);
    }
    elsif($nr_childs==0)
    {   $typename = $self->anyType($node);
        $type     = $self->typeByName($tree, $typename);
    }
    elsif($nr_childs!=1)
    {   error __x"expected is only one child at {where}"
          , where => $where, _class => 'schema';
    }
    else # nameless types
    {   my $child = $tree->firstChild;
        my $local = $child->localname;
        my $nest  = $tree->descend($child);

        $type
          = $local eq 'simpleType'  ? $self->simpleType($nest, 0)
          : $local eq 'complexType' ? $self->complexType($nest)
          : error __x"illegal element child `{name}' at {where}"
                , name => $local, where => $where, _class => 'schema';
    }

    my ($st, $elems, $attrs, $attrs_any)
      = @$type{ qw/st elems attrs attrs_any/ };
    $_ ||= [] for $elems, $attrs, $attrs_any;

    # Collect the hooks

    my ($before, $replace, $after)
      = $self->findHooks($where, $typename, $node);

    # Construct basic element handler

    my $r;
    if($replace) { ; }             # do not attempt to compile
    elsif($type->{mixed})          # complexType mixed
    {   $r = $self->make(mixed_element =>
            $where, $tag, $elems, $attrs, $attrs_any);
    }
    elsif(! defined $st)           # complexType
    {   $r = $self->make(complex_element =>
            $where, $tag, $elems, $attrs, $attrs_any);
    }
    elsif(@$attrs || @$attrs_any)  # complex simpleContent
    {   $r = $self->make(tagged_element =>
            $where, $tag, $st, $attrs, $attrs_any);
    }
    else                           # simple
    {   $r = $self->make(simple_element => $where, $tag, $st);
    }

    # Implement hooks

    my $do = ($before || $replace || $after)
      ? $self->make(hook => $where, $r, $tag, $before, $replace, $after)
      : $r;

    # handle recursion
    # this must look very silly to you... however, this is resolving
    # recursive schemas: this way nested use of the same element
    # definition will catch the code reference of the outer definition.
    $self->{_nest}{$nodeid}    = $do;
    delete $self->{_nest}{$nodeid};  # clean the outer definition

    $self->{_created}{$nodeid} = $do;
}

sub particle($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my $local = $node->localName;
    my $where = $tree->path;

    my $min   = $node->getAttribute('minOccurs');
    my $max   = $node->getAttribute('maxOccurs');

    unless(defined $min)
    {   $min = $self->{action} eq 'WRITER'
            && ($node->getAttribute('default') || $node->getAttribute('fixed'))
             ? 0 : 1;
    }

    # default attribute in writer means optional, but we want to see
    # them in the reader, to see the value.
 
    defined $max or $max = 1;

    $max = 'unbounded'
        if $max ne 'unbounded' && $max > 1 && !$self->{check_occurs};

    $min = 0
        if $max eq 'unbounded' && !$self->{check_occurs};

    return $self->anyElement($tree, $min, $max)
        if $local eq 'any';

    my ($pns, $label, $process)
      = $local eq 'element'        ? $self->particleElement($tree)
      : $local eq 'group'          ? $self->particleGroup($tree)
      : $local =~ $particle_blocks ? $self->particleBlock($tree)
      : error __x"unknown particle type '{name}' at {where}"
            , name => $local, where => $tree->path, _class => 'schema';

    defined $label
        or return ();

    return $self->make(block_handler =>
        $where, $label, $min, $max, $process, $local)
            if ref $process eq 'BLOCK';

    my $required = $min==0 ? undef
      : $self->make(required => $where, $label, $process);

    my $key = defined $pns ? $self->keyRewrite($pns, $label) : $label;

    my $do  = $self->make(element_handler =>
        $where, $key, $min, $max, $required, $process);

    ( ($self->{action} eq 'READER' ? $label : $key) => $do);
}

sub particleGroup($)
{   my ($self, $tree) = @_;

    # attributes: id, maxOccurs, minOccurs, name, ref
    # content: annotation?, (all|choice|sequence)?
    # apparently, a group can not refer to a group... well..

    my $node  = $tree->node;
    my $where = $tree->path . '#group';
    my $ref   = $node->getAttribute('ref')
        or error __x"group without ref at {where}"
             , where => $where, _class => 'schema';

    my $typename = $self->rel2abs($where, $node, $ref);

    my $dest    = $self->namespaces->find(group => $typename)
        or error __x"cannot find group `{name}' at {where}"
             , name => $typename, where => $where, _class => 'schema';

    my $group   = $tree->descend($dest->{node});
    return () if $group->nrChildren==0;

    $group->nrChildren==1
        or error __x"only one particle block expected in group `{name}' at {where}"
               , name => $typename, where => $where, _class => 'schema';

    my $local = $group->currentLocal;
    $local    =~ m/^(?:all|choice|sequence)$/
        or error __x"illegal group member `{name}' at {where}"
               , name => $local, where => $where, _class => 'schema';

    $self->particleBlock($group->descend);
}

sub particleBlock($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my @pairs = map { $self->particle($tree->descend($_)) } $tree->childs;
    @pairs or return ();

    # label is name of first component, only needed when maxOcc > 1
    my $label     = $pairs[0];
    my $blocktype = $node->localName;

    (undef, $label => $self->make($blocktype => $tree->path, @pairs));
}

sub findSgMembers($)
{   my ($self, $type) = @_;
    my @subgrps;
    foreach my $subgrp ($self->namespaces->findSgMembers($type))
    {   my $node     = $subgrp->{node};
        my $abstract = $node->getAttribute('abstract') || 'false';

        push @subgrps, $self->isTrue($abstract)
           ? $self->findSgMembers($subgrp->{full})
           : $subgrp;
    }
#warn "SUBGRPS for $type\n  ", join "\n  ", map {$_->{full}} @subgrps;
    @subgrps;
}
        
sub particleElementSubst($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my $where = $tree->path . '#subst';

    my $groupname = $node->getAttribute('name')
        or error __x"substitutionGroup element needs name at {where}"
               , where => $tree->path, _class => 'schema';

    my $tns     = $self->{tns};
    my $type    = pack_type $tns, $groupname;
    my @subgrps = $self->findSgMembers($type);

    # at least the base is expected
    unless(@subgrps)
    {   trace __x"no substitutionGroups found for {type} at {where}"
          , type => $type, where => $where, _class => 'schema'
             unless $self->{nosubst_notice}{$type}++;
    }

    my %localnames;
    my @elems;
    foreach my $subst (@subgrps)
    {    local @$self{ qw/elems_qual attrs_qual tns/ }
            = $self->nsContext($subst);

         my $name = $subst->{name};
         if(exists $localnames{$name})
         {   trace "double $name is $localnames{$name} and $subst->{full}";
             error "twice element `{name}' in substitutionGroup {group}, use rewrite_element"
               , name => $name, group => $type;

         }

         $localnames{$name} = $subst->{full};
         my $subst_elem     = $tree->descend($subst->{node});
         my ($pns, $pname, $do) = $self->particleElement($subst_elem);
         push @elems, $pname => $do;
    } 

    (undef, $groupname => $self->make(substgroup => $where, $type, @elems));
}

sub particleElement($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;

    if(my $ref =  $node->getAttribute('ref'))
    {   my $refname  = $self->rel2abs($tree, $node, $ref);
        my $where    = $tree->path . "/$ref";
 
        my $def      = $self->namespaces->find(element => $refname)
            or error __x"cannot find element '{name}' at {where}"
                   , name => $refname, where => $where, _class => 'schema';

        local @$self{ qw/elems_qual attrs_qual tns/ }
                     = $self->nsContext($def);

        my $refnode  = $def->{node};
        my $abstract = $refnode->getAttribute('abstract') || 'false';
        $self->assertType($where, abstract => boolean => $abstract);

        return $self->isTrue($abstract)
          ? $self->particleElementSubst($tree->descend($refnode))
          : $self->particleElement($tree->descend($refnode));
    }

    my $name     = $node->getAttribute('name')
        or error __x"element needs name or ref at {where}"
             , where => $tree->path, _class => 'schema';

    my $where    = $tree->path . '/' . $name;
    my $default  = $node->getAttributeNode('default');
    my $fixed    = $node->getAttributeNode('fixed');

    $default && $fixed
        and error __x"element can not have default and fixed at {where}"
              , where => $tree->path, _class => 'schema';

    my $nillable = $node->getAttribute('nillable') || 'false';
    $self->assertType($where, nillable => boolean => $nillable);

    my $do       = $self->element($tree->descend($node, $name));

    my $value
       = $default ? $default->textContent
       : $fixed   ? $fixed->textContent
       :            undef;
    my $generate
     = $self->isTrue($nillable) ? 'element_nillable'
     : $default   ? 'element_default'
     : $fixed     ? 'element_fixed'
     :              'element';

    my $ns    = $self->{tns}; #$node->namespaceURI;
    my $do_el = $self->make($generate => $where, $ns, $name, $do, $value);

    # hrefs are used by SOAP-RPC
    $do_el = $self->make(element_href => $where, $ns, $name, $do_el)
        if $self->{permit_href} && $self->{action} eq 'READER';
 
    ($ns, $name => $do_el);
}

sub keyRewrite($$)
{   my ($self, $ns, $label) = @_;
    my $key = $label;

    foreach my $r ( @{$self->{rewrite}} )
    {   if(ref $r eq 'HASH')
        {   my $full = pack_type $ns, $key;
            $key = $r->{$full} if defined $r->{$full};
            $key = $r->{$key}  if defined $r->{$key};
        }
        elsif(ref $r eq 'CODE')
        {   $key = $r->($ns, $key);
        }
        elsif($r eq 'UNDERSCORES')
        {   $key =~ s/-/_/g;
        }
        elsif($r eq 'SIMPLIFIED')
        {   $key =~ s/-/_/g;
            $key =~ s/\W//g;
            $key = lc $key;
        }
        elsif($r eq 'PREFIXED')
        {   my $p = $self->{prefixes};
            keys %$p > 1 || !exists $p->{''}
                or error __x"no prefix table provided with key_rewrite";

            my $prefix = $p->{$ns} ? $p->{$ns}{prefix} : '';
            $key = $prefix . '_' . $key if $prefix ne '';
        }
        elsif($r =~ m/^PREFIXED\(\s*(.*?)\s*\)$/)
        {   my @l = split /\s*\,\s*/, $1;
            my $p = $self->{prefixes};
            keys %$p > 1 || !exists $p->{''}
                or error __x"no prefix table provided with key_rewrite";

            my $prefix = $p->{$ns} ? $p->{$ns}{prefix} : '';
            $key = $prefix . '_' . $key if grep {$prefix eq $_} @l;
        }
        else
        {   error __x"key rewrite `{got}' not understood", got => $r;
        }
    }

    trace "rewrote key $label to $key"
        if $label ne $key;

    $key;
}

sub attributeOne($)
{   my ($self, $tree) = @_;

    # attributes: default, fixed, form, id, name, ref, type, use
    # content: annotation?, simpleType?

    my $node = $tree->node;
    my $type;

    my($ref, $name, $form, $typeattr);
    if(my $refattr =  $node->getAttribute('ref'))
    {   my $refname = $self->rel2abs($tree, $node, $refattr);
        my $def     = $self->namespaces->find(attribute => $refname)
            or error __x"cannot find attribute {name} at {where}"
                 , name => $refname, where => $tree->path, _class => 'schema';

        $ref        = $def->{node};
        local $self->{tns} = $def->{ns};
        my $attrs_qual = $def->{efd} eq 'qualified';
        if(exists $self->{attributes_qualified})
        {   my $qual = $self->{attributes_qualified} || 0;
            $attrs_qual = $qual eq 'ALL' ? 1 : $qual eq 'NONE' ? 0 : $qual;
        }
        local $self->{attrs_qual} = $attrs_qual;

        $name       = $ref->getAttribute('name')
            or error __x"ref attribute without name at {where}"
                 , where => $tree->path, _class => 'schema';

        if($typeattr = $ref->getAttribute('type'))
        {   # postpone interpretation
        }
        else
        {   my $other = $tree->descend($ref);
            $other->nrChildren==1 && $other->currentLocal eq 'simpleType'
                or error __x"toplevel attribute {type} has no type attribute nor single simpleType child"
                     , type => $refname, _class => 'schema';
            $type   = $self->simpleType($other->descend);
        }
        $form = $ref->getAttribute('form');
        $node = $ref;
    }
    elsif($tree->nrChildren==1)
    {   $tree->currentLocal eq 'simpleType'
            or error __x"attribute child can only be `simpleType', not `{found}' at {where}"
                 , found => $tree->currentLocal, where => $tree->path
                 , _class => 'schema';

        $name       = $node->getAttribute('name')
            or error __x"attribute without name at {where}"
                   , where => $tree->path;

        $form       = $node->getAttribute('form');
        $type       = $self->simpleType($tree->descend);
    }

    else
    {   $name       = $node->getAttribute('name')
            or error __x"attribute without name or ref at {where}"
                   , where => $tree->path, _class => 'schema';

        $typeattr   = $node->getAttribute('type');
        $form       = $node->getAttribute('form');
    }

    my $where = $tree->path.'/@'.$name;
    $self->assertType($where, name => NCName => $name);

    unless($type)
    {   my $typename = defined $typeattr
          ? $self->rel2abs($where, $node, $typeattr)
          : $self->anyType($node);

         $type  = $self->typeByName($tree, $typename);
    }

    my $st      = $type->{st}
        or error __x"attribute not based in simple value type at {where}"
             , where => $where, _class => 'schema';

    my $qual
      = ! defined $form        ? $self->{attrs_qual}
      : $form eq 'qualified'   ? 1
      : $form eq 'unqualified' ? 0
      : error __x"form must be (un)qualified, not {form} at {where}"
            , form => $form, where => $where, _class => 'schema';

    my $trans   = $qual ? 'tag_qualified' : 'tag_unqualified';
    my $ns      = $qual ? $self->{tns} : '';
    my $tag     = $self->make($trans => $where, $node, $name, $ns);

    my $use     = $node->getAttribute('use') || '';
    $use =~ m/^(?:optional|required|prohibited|)$/
        or error __x"attribute use is required, optional or prohibited (not '{use}') at {where}"
             , use => $use, where => $where, _class => 'schema';

    my $default = $node->getAttributeNode('default');
    my $fixed   = $node->getAttributeNode('fixed');

    my $generate
     = defined $default    ? 'attribute_default'
     : defined $fixed      ? 'attribute_fixed'
     : $use eq 'required'  ? 'attribute_required'
     : $use eq 'prohibited'? 'attribute_prohibited'
     :                       'attribute';

    my $value = defined $default ? $default : $fixed;
    my $do    = $self->make($generate => $where, $ns, $tag, $st, $value);
    defined $do ? ($name => $do) : ();
}

sub attributeGroup($)
{   my ($self, $tree) = @_;

    # attributes: id, ref = QName
    # content: annotation?

    my $node  = $tree->node;
    my $where = $tree->path;
    my $ref   = $node->getAttribute('ref')
        or error __x"attributeGroup use without ref at {where}"
             , where => $tree->path, _class => 'schema';

    my $typename = $self->rel2abs($where, $node, $ref);

    my $def  = $self->namespaces->find(attributeGroup => $typename)
        or error __x"cannot find attributeGroup {name} at {where}"
             , name => $typename, where => $where, _class => 'schema';

    $self->attributeList($tree->descend($def->{node}));
}

# Don't known how to handle notQName
sub anyAttribute($)
{   my ($self, $tree) = @_;

    # attributes: id
    #  , namespace = ##any|##other| List of (anyURI|##targetNamespace|##local)
    #  , notNamespace = List of (anyURI|##targetNamespace|##local)
    # ignored attributes
    #  , notQName = List of QName
    #  , processContents = lax|skip|strict
    # content: annotation?

    my $node      = $tree->node;
    my $where     = $tree->path . '@any';

    my $handler   = $self->{anyAttribute};
    my $namespace = $node->getAttribute('namespace')       || '##any';
    my $not_ns    = $node->getAttribute('notNamespace');
    my $process   = $node->getAttribute('processContents') || 'strict';

    warn "HELP: please explain me how to handle notQName"
        if $^W && $node->getAttribute('notQName');

    my ($yes, $no) = $self->translateNsLimits($namespace, $not_ns);
    my $do = $self->make(anyAttribute => $where, $handler, $yes, $no, $process);
    defined $do ? $do : ();
}

sub anyElement($$$)
{   my ($self, $tree, $min, $max) = @_;

    # attributes: id, maxOccurs, minOccurs,
    #  , namespace = ##any|##other| List of (anyURI|##targetNamespace|##local)
    #  , notNamespace = List of (anyURI|##targetNamespace|##local)
    # ignored attributes
    #  , notQName = List of QName
    #  , processContents = lax|skip|strict
    # content: annotation?

    my $node      = $tree->node;
    my $where     = $tree->path . '#any';
    my $handler   = $self->{anyElement};

    my $namespace = $node->getAttribute('namespace')       || '##any';
    my $not_ns    = $node->getAttribute('notNamespace');
    my $process   = $node->getAttribute('processContents') || 'strict';

    info "HELP: please explain me how to handle notQName"
        if $^W && $node->getAttribute('notQName');

    my ($yes, $no) = $self->translateNsLimits($namespace, $not_ns);
    (any => $self->make(anyElement =>
        $where, $handler, $yes, $no, $process, $min, $max));
}

sub translateNsLimits($$)
{   my ($self, $include, $exclude) = @_;

    # namespace    = ##any|##other| List of (anyURI|##targetNamespace|##local)
    # notNamespace = List of (anyURI |##targetNamespace|##local)
    # handling of ##local ignored: only full namespaces are supported for now

    return (undef, [])     if $include eq '##any';

    my $tns       = $self->{tns};
    return (undef, [$tns]) if $include eq '##other';

    my @return;
    foreach my $list ($include, $exclude)
    {   my @list;
        if(defined $list && length $list)
        {   foreach my $url (split " ", $list)
            {   push @list
                 , $url eq '##targetNamespace' ? $tns
                 : $url eq '##local'           ? ()
                 : $url;
            }
        }
        push @return, @list ? \@list : undef;
    }

    @return;
}

sub complexType($)
{   my ($self, $tree) = @_;

    # abstract, block, final, id, mixed, name, defaultAttributesApply
    # Full content:
    #    annotation?
    #  , ( simpleContent
    #    | complexContent
    #    | ( (group|all|choice|sequence)?
    #      , (attribute|attributeGroup)*
    #      , anyAttribute?
    #      )
    #    )
    #  , (assert | report)*

    my $node  = $tree->node;
    my $mixed = $self->isTrue($node->getAttribute('mixed') || 'false');
    undef $mixed
        if $self->{action} eq 'READER'
        && $self->{mixed_elements} eq 'STRUCTURAL';

    my $first = $tree->firstChild
        or return {mixed => $mixed};

    my $name  = $first->localName;
    return $self->complexBody($tree, $mixed)
        if $name =~ $particle_blocks || $name =~ $attribute_defs;

    $tree->nrChildren==1
        or error __x"expected is single simpleContent or complexContent at {where}"
             , where => $tree->path, _class => 'schema';

    return $self->simpleContent($tree->descend($first))
        if $name eq 'simpleContent';

    return $self->complexContent($tree->descend($first), $mixed)
        if $name eq 'complexContent';

    error __x"complexType contains particles, simpleContent or complexContent, not `{name}' at {where}"
      , name => $name, where => $tree->path, _class => 'schema';
}

sub complexBody($$)
{   my ($self, $tree, $mixed) = @_;

    $tree->currentChild
        or return ();

    # partial
    #    (group|all|choice|sequence)?
    #  , ((attribute|attributeGroup)*
    #  , anyAttribute?

    my @elems;
    if($tree->currentLocal =~ $particle_blocks)
    {   push @elems, $self->particle($tree->descend) unless $mixed;
        $tree->nextChild;
    }

    my @attrs = $self->attributeList($tree);

    defined $tree->currentChild
        and error __x"trailing non-attribute `{name}' at {where}"
              , name => $tree->currentChild->localName, where => $tree->path
              , _class => 'schema';

    {elems => \@elems, mixed => $mixed, @attrs};
}

sub attributeList($)
{   my ($self, $tree) = @_;

    # partial content
    #    ((attribute|attributeGroup)*
    #  , anyAttribute?

    my $where = $tree->path;

    my (@attrs, @any);
    for(my $attr = $tree->currentChild; defined $attr; $attr = $tree->nextChild)
    {   my $name = $attr->localName;
        if($name eq 'attribute')
        {   push @attrs, $self->attributeOne($tree->descend) }
        elsif($name eq 'attributeGroup')
        {   my %group = $self->attributeGroup($tree->descend);
            push @attrs, @{$group{attrs}};
            push @any,   @{$group{attrs_any}};
        }
        else { last }
    }

    # officially only one: don't believe that
    while($tree->currentLocal eq 'anyAttribute')
    {   push @any, $self->anyAttribute($tree->descend);
        $tree->nextChild;
    }

    (attrs => \@attrs, attrs_any => \@any);
}

sub simpleContent($)
{   my ($self, $tree) = @_;

    # attributes: id
    # content: annotation?, (restriction | extension)

    $tree->nrChildren==1
        or error __x"need one simpleContent child at {where}"
             , where => $tree->path, _class => 'schema';

    my $name  = $tree->currentLocal;
    return $self->simpleContentExtension($tree->descend)
        if $name eq 'extension';

    return $self->simpleContentRestriction($tree->descend)
        if $name eq 'restriction';

     error __x"simpleContent needs extension or restriction, not `{name}' at {where}"
         , name => $name, where => $tree->path, _class => 'schema';
}

sub simpleContentExtension($)
{   my ($self, $tree) = @_;

    # attributes: id, base = QName
    # content: annotation?
    #        , (attribute | attributeGroup)*
    #        , anyAttribute?
    #        , (assert | report)*

    my $node     = $tree->node;
    my $where    = $tree->path . '#sext';

    my $base     = $node->getAttribute('base');
    my $typename = defined $base ? $self->rel2abs($where, $node, $base)
     : $self->anyType($node);

    my $basetype = $self->typeByName($tree, $typename);
    defined $basetype->{st}
        or error __x"base of simpleContent not simple at {where}"
             , where => $where, _class => 'schema';
 
    $self->extendAttrs($basetype, $self->attributeList($tree));
    $tree->currentChild
        and error __x"elements left at tail at {where}"
              , where => $tree->path, _class => 'schema';

    $basetype;

}

sub simpleContentRestriction($$)
{   my ($self, $tree) = @_;

    # attributes id, base = QName
    # content: annotation?
    #        , (simpleType?, facet*)?
    #        , (attribute | attributeGroup)*, anyAttribute?
    #        , (assert | report)*

    my $node  = $tree->node;
    my $where = $tree->path . '#cres';

    my $type;
    if(my $basename = $node->getAttribute('base'))
    {   my $typename = $self->rel2abs($where, $node, $basename);
        $type        = $self->typeByName($tree, $typename);
    }
    else
    {   my $first    = $tree->currentLocal
            or error __x"no base in complex-restriction, so simpleType required at {where}"
                 , where => $where, _class => 'schema';

        $first eq 'simpleType'
            or error __x"simpleType expected, because there is no base attribute at {where}"
                 , where => $where, _class => 'schema';

        $type = $self->simpleType($tree->descend);
        $tree->nextChild;
    }

    my $st = $type->{st}
        or error __x"not a simpleType in simpleContent/restriction at {where}"
             , where => $where, _class => 'schema';

    $type->{st} = $self->applySimpleFacets($tree, $st, 0);

    $self->extendAttrs($type, $self->attributeList($tree));

    $tree->currentChild
        and error __x"elements left at tail at {where}"
                , where => $where, _class => 'schema';

    $type;
}

sub complexContent($$)
{   my ($self, $tree, $mixed) = @_;

    # attributes: id, mixed = boolean
    # content: annotation?, (restriction | extension)

    my $node = $tree->node;
    $mixed ||= $self->isTrue($node->getAttribute('mixed') || 'false');
  
    $tree->nrChildren == 1
        or error __x"only one complexContent child expected at {where}"
             , where => $tree->path, _class => 'schema';

    my $name  = $tree->currentLocal;
 
    return $self->complexContentExtension($tree->descend)
        if $name eq 'extension';

    # nice for validating, but base can be ignored
    return $self->complexBody($tree->descend, $mixed)
        if $name eq 'restriction';

    error __x"complexContent needs extension or restriction, not `{name}' at {where}"
        , name => $name, where => $tree->path, _class => 'schema';
}

sub complexContentExtension($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my $base  = $node->getAttribute('base') || 'anyType';
    my $type  = {};
    my $where = $tree->path . '#cce';

    if($base ne 'anyType')
    {   my $typename = $self->rel2abs($where, $node, $base);
        my $typedef  = $self->namespaces->find(complexType => $typename)
            or error __x"unknown base type '{type}' at {where}"
                 , type => $typename, where => $tree->path, _class => 'schema';

        local @$self{ qw/elems_qual attrs_qual tns/ }
            = $self->nsContext($typedef);

        $type = $self->complexType($tree->descend($typedef->{node}));
    }

    my $own = $self->complexBody($tree, 0);
    unshift @{$own->{$_}}, @{$type->{$_} || []}
        for qw/elems attrs attrs_any/;
    $own->{mixed} ||= $type->{mixed};

    $own;
}

sub complexMixed($)
{   my ($self, $tree) = @_;
    { mixed => 1 };
}

#
# Helper routines
#

# print $self->rel2abs($path, $node, '{ns}type')    ->  '{ns}type'
# print $self->rel2abs($path, $node, 'prefix:type') ->  '{ns(prefix)}type'

sub rel2abs($$$)
{   my ($self, $where, $node, $type) = @_;
    return $type if substr($type, 0, 1) eq '{';

    my ($prefix, $local) = $type =~ m/^(.+?)\:(.*)/ ? ($1, $2) : ('', $type);
    my $url = $node->lookupNamespaceURI($prefix);

    error __x"No namespace for prefix `{prefix}' in `{type}' at {where}"
      , prefix => $prefix, type => $type, where => $where, _class => 'schema'
        if length $prefix && !defined $url;

     pack_type $url, $local;
}

sub anyType($)
{   my ($self, $node) = @_;
    pack_type $node->namespaceURI, 'anyType';
}

sub findHooks($$$)
{   my ($self, $path, $type, $node) = @_;
    # where is before, replace, after

    my %hooks;
    foreach my $hook (@{$self->{hooks}})
    {   my $match;

        $match++
            if !$hook->{path} && !$hook->{id}
            && !$hook->{type} && !$hook->{attribute};

        if(!$match && $hook->{path})
        {   my $p = $hook->{path};
            $match++
               if first {ref $_ eq 'Regexp' ? $path =~ $_ : $path eq $_}
                     ref $p eq 'ARRAY' ? @$p : $p;
        }

        my $id = !$match && $hook->{id} && $node->getAttribute('id');
        if($id)
        {   my $i = $hook->{id};
            $match++
                if first {ref $_ eq 'Regexp' ? $id =~ $_ : $id eq $_} 
                    ref $i eq 'ARRAY' ? @$i : $i;
        }

        if(!$match && defined $type && $hook->{type})
        {   my $t  = $hook->{type};
            my ($ns, $local) = unpack_type $t;
            $match++
                if first {ref $_ eq 'Regexp'     ? $type  =~ $_
                         : substr($_,0,1) eq '{' ? $type  eq $_
                         :                         $local eq $_
                         } ref $t eq 'ARRAY' ? @$t : $t;
        }

        $match or next;

        foreach my $where ( qw/before replace after/ )
        {   my $w = $hook->{$where} or next;
            push @{$hooks{$where}}, ref $w eq 'ARRAY' ? @$w : $w;
        }
    }

    @hooks{ qw/before replace after/ };
}


1;
