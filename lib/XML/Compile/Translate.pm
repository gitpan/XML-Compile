# Copyrights 2006-2011 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.00.
use warnings;
use strict;

package XML::Compile::Translate;
use vars '$VERSION';
$VERSION = '1.22';


# Errors are either in _class 'usage': called with request
#                         or 'schema': syntax error in schema

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util  qw/first max/;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInFacets;
use XML::Compile::Schema::BuiltInTypes qw/%builtin_types/;
use XML::Compile::Util      qw/pack_type unpack_type type_of_node SCHEMA2001/;
use XML::Compile::Iterator  ();

my %translators =
 ( READER   => 'XML::Compile::Translate::Reader'
 , WRITER   => 'XML::Compile::Translate::Writer'
 , TEMPLATE => 'XML::Compile::Translate::Template'
 );

# Elements from the schema to ignore: remember, we are collecting data
# from the schema, but only use selective items to produce processors.
# All the sub-elements of these will be ignored automatically
# Don't known whether we ever need the notation... maybe
my $assertions      = qr/assert|report/;
my $id_constraints  = qr/unique|key|keyref/;
my $ignore_elements = qr/^(?:notation|annotation|$id_constraints|$assertions)$/;

my $particle_blocks = qr/^(?:sequence|choice|all|group)$/;
my $attribute_defs  = qr/^(?:attribute|attributeGroup|anyAttribute)$/;


sub new($@)
{   my ($baseclass, $trans) = (shift, shift);
    my $class = $translators{$trans}
       or error __x"translator back-end {name} not defined", name => $trans;

    eval "require $class";
    fault $@ if $@;

    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->{nss}      = $args->{nss} or panic "no namespace tables";
    $self->{prefixes} = $args->{prefixes} || {};
    $self;
}


sub register($)
{  my ($class, $name) = @_;
   UNIVERSAL::isa($class, __PACKAGE__)
       or error __x"back-end {class} does not extend {base}"
            , class => $class, base => __PACKAGE__;
   $translators{$name} = $class;
}


# may disappear, so not documented publicly (yet)
sub actsAs($) { panic "not implemented" }


sub compile($@)
{   my ($self, $item, %args) = @_;
    @$self{keys %args} = values %args;  # dirty

    my $path   = $item;
    ref $item
        and panic "expecting an item as point to start at $path";

    my $hooks   = $self->{hooks}   ||= [];
    my $typemap = $self->{typemap} ||= {};
    $self->typemapToHooks($hooks, $typemap);

    $self->{blocked_nss}
      = $self->decodeBlocked(delete $self->{block_namespace});

    my $nsp     = $self->namespaces;
    foreach my $t (keys %$typemap)
    {   $nsp->find(complexType => $t) || $nsp->find(simpleType => $t)
            or error __x"complex or simpleType {type} for typemap unknown"
                 , type => $t;
    }

    if(my $def = $self->namespaces->findID($item))
    {   my $node = $def->{node};
        my $name = $node->localName;
        $item    = $def->{full};
    }

    delete $self->{_created};
    my $produce = $self->topLevel($path, $item);
    delete $self->{_created};

    my $in = $self->{include_namespaces}
        or return $produce;

    $self->makeWrapperNs($path, $produce, $self->{prefixes}, $in);
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
{   my ($self, $in, $add) = @_;

    if(my $a = $add->{attrs})
    {   # new attrs overrule old definitions (restrictions)
        my (@attrs, %code);
        my @all = (@{$in->{attrs} || []}, @{$add->{attrs} || []});
        while(@all)
        {   my ($type, $code) = (shift @all, shift @all);
            if($code{$type})
            {   $attrs[$code{$type}] = $code;
            }
            else
            {   push @attrs, $type => $code;
                $code{$type} = $#attrs;
            }
        }
        $in->{attrs} = \@attrs;
    }

    # doing this correctly is too complex for now
    unshift @{$in->{attrs_any}}, @{$add->{attrs_any}} if $add->{attrs_any};
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

sub topLevel($$)
{   my ($self, $path, $fullname) = @_;

    # built-in types have to be handled differently.
    my $internal = XML::Compile::Schema::Specs->builtInType(undef, $fullname
       , sloppy_integers => $self->{sloppy_integers}
       , sloppy_floats   => $self->{sloppy_floats});

    if($internal)
    {   my $builtin = $self->makeBuiltin($fullname, undef
            , $fullname, $internal, $self->{check_values});
        my $builder = $self->actsAs('WRITER')
          ? sub { $_[0]->createTextNode($builtin->(@_)) }
          : $builtin;
        return $self->makeElementWrapper($path, $builder);
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
    my $qual
      = exists $self->{elements_qualified} ? ($self->{elements_qualified} || 0)
      : $elems_qual ? 'ALL' : $top->{ns} ? 'TOP' : 'NONE';

    my $remove_form_attribute;

       if($qual eq 'ALL')  { $elems_qual = 1 }
    elsif($qual eq 'NONE') { $elems_qual = 0 }
    elsif($qual eq 'TOP')
    {   unless($elems_qual)
        {   # explitly overrule the name-space qualification of the
            # top-level element, which is dirty but people shouldn't
            # use unqualified schemas anyway!!!
            $node->removeAttribute('form');   # when in schema
            $node->setAttribute(form => 'qualified');
            $elems_qual = 0;
            $remove_form_attribute = 1;
        }
    }
    else {$elems_qual = $qual}

    delete $self->{elements_qualified}
        if $self->{elements_qualified}
        && $self->{elements_qualified} eq 'TOP';

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

    my $data;
    my $name = $node->localName;
    if($name eq 'element')
    {   my $make = $self->element($tree);
        $data    = $self->makeElementWrapper($path, $make) if $make;
    }
    elsif($name eq 'attribute')
    {   my $make = $self->attributeOne($tree);
        $data    = $self->makeAttributeWrapper($path, $make) if $make;
    }
    else
    {   error __x"top-level {full} is not an element or attribute but {name} at {where}"
          , full => $fullname, name => $name, where => $tree->path
          , _class => 'usage';
    }

    $node->removeAttribute('form')
        if $remove_form_attribute;

    $data;
}

sub typeByName($$)
{   my ($self, $tree, $typename) = @_;

    my $node  = $tree->node;

    #
    # Try to detect a built-in type
    #

    my $def   = XML::Compile::Schema::Specs->builtInType($node, $typename
       , sloppy_integers => $self->{sloppy_integers}
       , sloppy_floats   => $self->{sloppy_floats});

    if($def)
    {   # Is built-in
        my $where = $typename;
        my $st = $self->makeBuiltin($where, $node, $typename, $def, $self->{check_values});

        return +{ st => $st, is_list => $def->{is_list} };
    }

    #
    # not a schema standard type
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
        $per_item    = $self->blocked($where, simpleType => $typename)
                    || $self->typeByName($tree, $typename);
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

    $per_item->{st} = $self->makeList($where, $st);
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
            my $type = $self->blocked($where, simpleType => $typename)
                    || $self->typeByName($tree, $typename);
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

    my $do = $self->makeUnion($where, @types);
    { st => $do, is_union => 1 };
}

sub simpleRestriction($$)
{   my ($self, $tree, $in_list) = @_;

    # attributes: id, base = QName
    # content: annotation?, simpleType?, facet*

    my $node  = $tree->node;
    my $where = $tree->path . '#sres';

    my ($base, $typename);
    if(my $basename = $node->getAttribute('base'))
    {   $typename = $self->rel2abs($where, $node, $basename);
        $base     = $self->blocked($where, simpleType => $typename)
                 || $self->typeByName($tree, $typename);
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

    my $do = $self->applySimpleFacets($tree, $st
      , $in_list || $base->{is_list}, $typename);

    $tree->currentChild
        and error __x"elements left at tail at {where}"
                , where => $tree->path, _class => 'schema';

    +{ st => $do };
}

my %facets_early = map +($_ => 1), qw/whiteSpace pattern enumeration/;
#my %facets_late = map +($_ => 1), qw/totalDigits maxScale minScale
#   maxInclusive maxExclusive minInclusive minExclusive fractionDigits
#   length minLength maxLength/;

my $qname_type   = pack_type SCHEMA2001, 'QName';

sub applySimpleFacets($$$$)
{   my ($self, $tree, $st, $is_list, $type) = @_;
    my $nss = $self->{nss};

    # partial
    # content: facet*
    # facet = minExclusive | minInclusive | maxExclusive | maxInclusive
    #   | totalDigits | fractionDigits | maxScale | minScale | length
    #   | minLength | maxLength | enumeration | whiteSpace | pattern

    my $where = $tree->path . '#facet';
    my (%facets, $is_qname);
    for(my $child = $tree->currentChild; $child; $child = $tree->nextChild)
    {   my $facet = $child->localName;
        last if $facet =~ $attribute_defs;

        my $value = $child->getAttribute('value');
        defined $value
            or error __x"no value for facet `{facet}' at {where}"
                   , facet => $facet, where => $where, _class => 'schema';

        if($facet eq 'enumeration')
        {   $is_qname = $nss->doesExtend($type, $qname_type)
                unless defined $is_qname;

            if($is_qname)
            {   # rewrite prefixed values into "{ns}local"
                my ($prefix, $local)
                    = $value =~ m/\:/ ? split(/\:/, $value, 2) : ('', $value);
                my $ns = $child->lookupNamespaceURI($prefix);
                $value = pack_type $ns, $local;
                $self->_registerNSprefix($prefix, $ns, 1);
            }

            push @{$facets{enumeration}}, $value;
        }
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
        $facets{_totalFracDigits} = [$td, $fd];
    }

    my (@early, @late);
    my $action = $self->actsAs('WRITER') ? 'WRITER' : 'READER';
    foreach my $facet (keys %facets)
    {   my $h = builtin_facet($where, $self, $facet
          , $facets{$facet}, $is_list, $type, $nss, $action) or next;

        if($facets_early{$facet})
             { push @early, $h }
        else { push @late,  $h }
    }

      $is_list
    ? $self->makeFacetsList($where, $st, \%facets_info, \@early, \@late)
    : $self->makeFacets($where, $st, \%facets_info, @early, @late);
}

sub element($)
{   my ($self, $tree) = @_;

    # attributes: abstract, default, fixed, form, id, maxOccurs, minOccurs
    #    , name, nillable, ref, substitutionGroup, targetNamespace, type
    # ignored: block, final, targetNamespace additional restrictions
    # content: annotation?
    #        , (simpleType | complexType)?
    #        , (unique | key | keyref)*

    my $node     = $tree->node;
    my $name     = $node->getAttribute('name')
        or error __x"element has no name nor ref at {where}"
             , where => $tree->path, _class => 'schema';
    my $ns       = $node->getAttribute('targetNamespace') || $self->{tns};

    $self->assertType($tree->path, name => NCName => $name);
    my $fullname = pack_type $ns, $name;

    my $abstract = $node->getAttribute('abstract') || 'false';
    $abstract = 'false' if $self->{abstract_types} eq 'ACCEPT';

    # Handle re-usable fragments, fight against combinatorial explosions

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

    my $trans     = $qual ? 'makeTagQualified' : 'makeTagUnqualified';
    my $tag       = $self->$trans($where, $node, $name, $ns);

    # Construct type processor

    my ($comptype, $comps);
    my $nr_childs = $tree->nrChildren;
    if(my $isa    = $node->getAttribute('type'))
    {   $nr_childs==0
            or error __x"no childs expected with attribute `type' at {where}"
                 , where => $where, _class => 'schema';

        $comptype = $self->rel2abs($where, $node, $isa);
        $comps    = $self->blocked($where, anyType => $comptype)
                 || $self->typeByName($tree, $comptype);
    }
    elsif($nr_childs==0)
    {   $comptype = $self->anyType($node);
        $comps    = $self->typeByName($tree, $comptype);
    }
    elsif($nr_childs!=1)
    {   error __x"expected is only one child at {where}"
          , where => $where, _class => 'schema';
    }
    else # nameless types
    {   my $child = $tree->firstChild;
        my $local = $child->localname;
        my $nest  = $tree->descend($child);

        ($comps, $comptype)
          = $local eq 'simpleType'
          ? ($self->simpleType($nest, 0), 'unnamed simple')
          : $local eq 'complexType'
          ? ($self->complexType($nest), 'unnamed complex')
          : error __x"illegal element child `{name}' at {where}"
                , name => $local, where => $where, _class => 'schema';
    }

    my ($st, $elems, $attrs, $attrs_any)
      = @$comps{ qw/st elems attrs attrs_any/ };
    $_ ||= [] for $elems, $attrs, $attrs_any;

    # Construct basic element handler

    my $elem_handler
      = $comps->{mixed}          ? 'makeMixedElement'
      : (! defined $st)          ? 'makeComplexElement' # other complexType
      : (@$attrs || @$attrs_any) ? 'makeTaggedElement'  # complex/simpleContent
      :                            'makeSimpleElement';

    my $r = $self->$elem_handler
      ($where, $tag, ($st||$elems), $attrs, $attrs_any, $comptype);

    # Add defaults and stuff
    my $default  = $node->getAttributeNode('default');
    my $fixed    = $node->getAttributeNode('fixed');
    my $nillable = $node->getAttribute('nillable') || 'false';

    $default && $fixed
        and error __x"element can not have default and fixed at {where}"
              , where => $tree->path, _class => 'schema';

    my $value
      = $default ? $default->textContent
      : $fixed   ? $fixed->textContent
      :            undef;

    my $generate
      = $self->isTrue($abstract) ? 'makeElementAbstract'
      : $self->isTrue($nillable) ? 'makeElementNillable'
      : $default                 ? 'makeElementDefault'
      : $fixed                   ? 'makeElementFixed'
      :                            'makeElement';

    my $nodetype = $qual ? $fullname : $name;
    my $do1 = $self->$generate($where, $ns, $nodetype, $r, $value, $tag);

    # hrefs are used by SOAP-RPC
    my $do2 = $self->{permit_href} && $self->actsAs('READER')
      ? $self->makeElementHref($where, $ns, $nodetype, $do1) : $do1;

    # Implement hooks
    my ($before, $replace, $after)
      = $self->findHooks($where, $comptype, $node);
    my $do3
      = ($before || $replace || $after)
      ? $self->makeHook($where, $do2, $tag, $before, $replace, $after)
      : $do2;

    my $do4 = $do3;
    if($comptype && $self->{xsi_type}{$comptype})
    { 
        # Ugly xsi:type switch needed
        my %alt = ($comptype => $do3);
        foreach my $alttype (@{$self->{xsi_type}{$comptype}})
        {   my ($ns, $local) = unpack_type $alttype;
            my $prefix  = $node->lookupNamespacePrefix($ns);
            defined $prefix
                or $prefix = $self->_registerNSprefix(undef, $ns, 1);

            my $type    = length $prefix ? "$prefix:$local" : $local;

            # do not accidentally use the default namespace, when there
            # may also be namespace-less types used.
            my $doc     = $node->ownerDocument;
            my $altnode = $doc->createElement('element');
            $altnode->setNamespace(SCHEMA2001, 'temp1234', 1);
            $altnode->setNamespace($ns, $prefix);
            $altnode->setAttribute(name => $name);
            $altnode->setAttribute(type => $type);

            my $altnodeid = $altnode->nodePath.'#'.$fullname;
            delete $self->{_created}{$altnodeid}; # clean nesting cache

            $alt{$alttype} = $self->element($tree->descend($altnode));
        }

        $do4 = $self->makeXsiTypeSwitch($where, $name, $comptype, \%alt);
    }

    # handle recursion
    # this must look very silly to you... however, this is resolving
    # recursive schemas: this way nested use of the same element
    # definition will catch the code reference of the outer definition.
    $self->{_nest}{$nodeid}    = $do4;
    delete $self->{_nest}{$nodeid};  # clean the outer definition

    $self->{_created}{$nodeid} = $do4;
}

sub particle($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my $local = $node->localName;
    my $where = $tree->path;

    my $min   = $node->getAttribute('minOccurs');
    my $max   = $node->getAttribute('maxOccurs');

    unless(defined $min)
    {   $min = ($self->actsAs('WRITER') || $self->{default_values} ne 'EXTEND')
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

    my ($label, $process)
      = $local eq 'element'        ? $self->particleElement($tree)
      : $local eq 'group'          ? $self->particleGroup($tree)
      : $local =~ $particle_blocks ? $self->particleBlock($tree)
      : error __x"unknown particle type '{name}' at {where}"
            , name => $local, where => $tree->path, _class => 'schema';

    defined $label
        or return ();

    if(ref $process eq 'BLOCK')
    {   my $key   = $self->keyRewrite($label);
        my $multi = $self->blockLabel($local, $key);
        return $self->makeBlockHandler($where, $label, $min, $max
           , $process, $local, $multi);
    }

    # only elements left
    my $required;
    my $key   = $self->keyRewrite($label);
    $required = $self->makeRequired($where, $key, $process) if $min!=0;

    ($self->actsAs('READER') ? $label : $key) =>
       $self->makeElementHandler($where, $key, $min,$max, $required, $process);
}

# blockLabel KIND, LABEL
# Particle blocks, like `sequence' and `choice', which have a maxOccurs
# (maximum occurrence) which is 2 of more, are represented by an ARRAY
# of HASHs.  The label with such a block is derived from its first element.
# This function determines how.
#  seq_address       sequence get seq_ prepended
#  cho_gender        choices get cho_ before them
#  all_money         an all block can also be repreated in spec >1.1
#  gr_people         group refers to a block of above type, but
#                       that type is not reflected in the name

my %block_abbrev = qw/sequence seq_  choice cho_  all all_  group gr_/;
sub blockLabel($$)
{   my ($self, $kind, $label) = @_;
    return $label if $kind eq 'element';

    $label =~ s/^(?:seq|cho|all|gr)_//;
    $block_abbrev{$kind} . (unpack_type $label)[1];
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
    if(my $blocked = $self->blocked($where, ref => $typename))
    {   return ($typename, $blocked);
    }

    my $dest  = $self->namespaces->find(group => $typename)
        or error __x"cannot find group `{name}' at {where}"
             , name => $typename, where => $where, _class => 'schema';

    local @$self{ qw/elems_qual attrs_qual tns/ }
       = $self->nsContext($dest);

    my $group = $tree->descend($dest->{node}, $dest->{local});
    return () if $group->nrChildren==0;

    $group->nrChildren==1
        or error __x"only one particle block expected in group `{name}' at {where}"
               , name => $typename, where => $where, _class => 'schema';

    my $local = $group->currentLocal;
    $local    =~ m/^(?:all|choice|sequence)$/
        or error __x"illegal group member `{name}' at {where}"
             , name => $local, where => $where, _class => 'schema';

    my ($blocklabel, $code) = $self->particleBlock($group->descend);
    ($typename, $code);
}

sub particleBlock($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my @pairs = map { $self->particle($tree->descend($_)) } $tree->childs;
    @pairs or return ();

    # label is name of first component, only needed when maxOcc > 1
    my $label     = $pairs[0];
    my $blocktype = $node->localName;

    my $call      = 'make'.ucfirst $blocktype;
    ($label => $self->$call($tree->path, @pairs));
}

sub particleElementRef($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my $name  = $node->getAttribute('name'); # toplevel always has a name
    my $type  = pack_type $self->{tns}, $name;
    my @sgs   = $self->namespaces->findSgMembers($node->localName, $type);
    @sgs or return $self->particleElement($tree); # not-extended element

    my ($label, $do) = $self->particleElement($tree);
    $label or return;

    if(Log::Report->needs('TRACE')) # dump table of substgroup alternatives
    {   my $labelrw = $self->keyRewrite($label);
        my @full    = sort map { $_->{full} } @sgs;
        my $longest = max map length, @full;
        my @c = map {sprintf "%-${longest}s %s",$_,$self->keyRewrite($_)} @full;
        local $"    = "\n  ";
        trace "substitutionGroup $type$\"SG=$label ($labelrw)$\"@c";
    }

    my @elems;
    push @elems, $label => [$self->keyRewrite($label), $do] if $do;

    foreach my $subst (@sgs)
    {    local @$self{ qw/elems_qual attrs_qual tns/ }
            = $self->nsContext($subst);

         my $subst_elem = $tree->descend($subst->{node});
         my ($l, $d) = $self->particleElement($subst_elem);
         push @elems, $l => [$self->keyRewrite($l), $d] if defined $d;
    } 

    my $where = $tree->path . '#subst';
    ($type => $self->makeSubstgroup($where, $type, @elems));
}

sub particleElement($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;

    if(my $ref =  $node->getAttribute('ref'))
    {   my $where   = $tree->path . "/$ref";
        my $refname = $self->rel2abs($tree, $node, $ref);
        return () if $self->blocked($where, ref => $refname);
 
        my $def     = $self->namespaces->find(element => $refname)
            or error __x"cannot find ref element '{name}' at {where}"
                   , name => $refname, where => $where, _class => 'schema';

        my $refnode = $def->{node};

        local @$self{ qw/elems_qual attrs_qual tns/ }
          = $self->nsContext($def);

        return $self->particleElementRef($tree->descend($refnode));
    }

    my $name = $node->getAttribute('name')
        or error __x"element needs name or ref at {where}"
             , where => $tree->path, _class => 'schema';

    my $fullname = pack_type $self->{tns}, $name;
    my $nodetype = $self->{elems_qual} ? $fullname : $name;
    my $do       = $self->element($tree->descend($node, $name));
    $do ? ($nodetype => $do) : ();
}

sub keyRewrite($;$)
{   my $self = shift;
    my ($ns, $key) = @_==1 ? unpack_type($_[0]) : @_;
    my $oldkey = $key;

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
            my $prefix = $p->{$ns} ? $p->{$ns}{prefix} : '';
            $key = $prefix . '_' . $key if $prefix ne '';
        }
        elsif($r =~ m/^PREFIXED\(\s*(.*?)\s*\)$/)
        {   my @l = split /\s*\,\s*/, $1;
            my $p = $self->{prefixes};
            my $prefix = $p->{$ns} ? $p->{$ns}{prefix} : '';
            $key = $prefix . '_' . $key if grep {$prefix eq $_} @l;
        }
        else
        {   error __x"key rewrite `{got}' not understood", got => $r;
        }
    }

    trace "rewrote type @_ to $key"
        if $key ne $oldkey;

    $key;
}

sub prefixed($)
{   my ($self, $qname) = @_;
    my ($ns, $local) = unpack_type $qname;
    defined $ns or return $qname;

    my $pn = $self->{prefixes}{$ns} or return;
    $pn->{used}++;
    length $pn->{prefix} ? "$pn->{prefix}:$local" : $local;
}

sub attributeOne($)
{   my ($self, $tree) = @_;

    # attributes: default, fixed, form, id, name, ref, type, use
    # content: annotation?, simpleType?

    my $node = $tree->node;
    my ($type, $tns);

    my($ref, $name, $form, $typeattr);
    if(my $refattr =  $node->getAttribute('ref'))
    {   my $where  = $tree->path;
        my $refname = $self->rel2abs($tree, $node, $refattr);
        return () if $self->blocked($where, ref => $refname);

        my $def     = $self->namespaces->find(attribute => $refname)
            or error __x"cannot find attribute {name} at {where}"
                 , name => $refname, where => $where, _class => 'schema';

        $ref        = $def->{node};
        local $self->{tns} = $tns = $def->{ns};
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

         $type  = $self->blocked($where, simpleType => $typename)
               || $self->typeByName($tree, $typename);
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

    $tns      ||= $node->getAttribute('targetNamespace') || $self->{tns};
    my $trans   = $qual ? 'makeTagQualified' : 'makeTagUnqualified';
    my $ns      = $qual ? $tns : '';
    my $tag     = $self->$trans($where, $node, $name, $ns);

    my $use     = $node->getAttribute('use') || '';
    $use =~ m/^(?:optional|required|prohibited|)$/
        or error __x"attribute use is required, optional or prohibited (not '{use}') at {where}"
             , use => $use, where => $where, _class => 'schema';

    my $default = $node->getAttributeNode('default');
    my $fixed   = $node->getAttributeNode('fixed');

    my $generate
     = defined $default    ? 'makeAttributeDefault'
     : defined $fixed      ? 'makeAttributeFixed'
     : $use eq 'required'  ? 'makeAttributeRequired'
     : $use eq 'prohibited'? 'makeAttributeProhibited'
     :                       'makeAttribute';

    my $value = defined $default ? $default : $fixed;
    my $label = $self->keyRewrite($ns, $name);
    my $do    = $self->$generate($where, $ns, $tag, $label, $st, $value);
    defined $do ? ($label => $do) : ();
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
    return () if $self->blocked($where, ref => $typename);

    my $def  = $self->namespaces->find(attributeGroup => $typename)
        or error __x"cannot find attributeGroup {name} at {where}"
             , name => $typename, where => $where, _class => 'schema';

    local $self->{tns} = $def->{ns};
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

    my $handler   = $self->{any_attribute};
    my $namespace = $node->getAttribute('namespace')       || '##any';
    my $not_ns    = $node->getAttribute('notNamespace');
    my $process   = $node->getAttribute('processContents') || 'strict';

    warn "HELP: please explain me how to handle notQName"
        if $^W && $node->getAttribute('notQName');

    my ($yes, $no) = $self->translateNsLimits($namespace, $not_ns);
    my $do = $self->makeAnyAttribute($where, $handler, $yes, $no, $process);
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
    my $handler   = $self->{any_element};

    my $namespace = $node->getAttribute('namespace')       || '##any';
    my $not_ns    = $node->getAttribute('notNamespace');
    my $process   = $node->getAttribute('processContents') || 'strict';

    info "HELP: please explain me how to handle notQName"
        if $^W && $node->getAttribute('notQName');

    my ($yes, $no) = $self->translateNsLimits($namespace, $not_ns);
    (any => $self->makeAnyElement($where, $handler, $yes, $no
              , $process, $min, $max));
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
        {   foreach my $uri (split " ", $list)
            {   push @list
                 , $uri eq '##targetNamespace' ? $tns
                 : $uri eq '##local'           ? ()
                 : $uri;
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
        if $self->{mixed_elements} eq 'STRUCTURAL';

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
    {   push @elems, $self->particle($tree->descend); # unless $mixed;
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

    my $basetype = $self->blocked($where, simpleType => $typename)
                || $self->typeByName($tree, $typename);
    defined $basetype->{st}
        or error __x"base of simpleContent not simple at {where}"
             , where => $where, _class => 'schema';
 
    $self->extendAttrs($basetype, {$self->attributeList($tree)});

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
    my $first = $tree->currentLocal || '';
    if($first eq 'simpleType')
    {   $type = $self->simpleType($tree->descend);
        $tree->nextChild;
    }
    elsif(my $basename  = $node->getAttribute('base'))
    {   my $typename = $self->rel2abs($where, $node, $basename);
        $type        = $self->blocked($where, simpleType => $type)
                    || $self->typeByName($tree, $typename);
    }
    else
    {   error __x"no base in complex-restriction, so simpleType required at {where}"
          , where => $where, _class => 'schema';
    }

    my $st = $type->{st}
        or error __x"not a simpleType in simpleContent/restriction at {where}"
             , where => $where, _class => 'schema';

    $type->{st} = $self->applySimpleFacets($tree, $st, 0, $type);

    $self->extendAttrs($type, {$self->attributeList($tree)});

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
    if(my $m = $node->getAttribute('mixed'))
    {   $mixed = $self->isTrue($m)
            if $self->{mixed_elements} ne 'STRUCTURAL';
    }

    $tree->nrChildren == 1
        or error __x"only one complexContent child expected at {where}"
             , where => $tree->path, _class => 'schema';

    my $name  = $tree->currentLocal;
    error __x"complexContent needs extension or restriction, not `{name}' at {where}"
       , name => $name, where => $tree->path, _class => 'schema'
           if $name ne 'extension' && $name ne 'restriction';

    $tree     = $tree->descend;
    $node     = $tree->node;
    my $base  = $node->getAttribute('base');
    my $type  = {};
    my $where = $tree->path . '#cce';

    if($base !~ m/\banyType$/)
    {   my $typename = $self->rel2abs($where, $node, $base);
        if($type = $self->blocked($where, complexType => $typename))
        {   # blocked base type
        }
        else
        {   my $typedef  = $self->namespaces->find(complexType => $typename)
               or error __x"unknown base type '{type}' at {where}"
                 , type => $typename, where => $tree->path, _class => 'schema';

            local @$self{ qw/elems_qual attrs_qual tns/ }
                = $self->nsContext($typedef);

            $type = $self->complexType($tree->descend($typedef->{node}));
        }
    }

    my $own = $self->complexBody($tree, $mixed);
    $self->extendAttrs($type, $own);

    if($name eq 'extension')
    {   push @{$type->{elems}}, @{$own->{elems} || []};
    }
    else # restriction
    {   $type->{elems} = $own->{elems};
    }

    $type->{mixed} ||= $own->{mixed};
    $type;
}

#
# Helper routines
#

# print $self->rel2abs($path, $node, '{ns}type')    ->  '{ns}type'
# print $self->rel2abs($path, $node, 'prefix:type') ->  '{ns-of-prefix}type'

sub rel2abs($$$)
{   my ($self, $where, $node, $type) = @_;
    return $type if substr($type, 0, 1) eq '{';

    my ($prefix, $local) = $type =~ m/^(.+?)\:(.*)/ ? ($1, $2) : ('', $type);
    my $uri = $node->lookupNamespaceURI($prefix);
    $self->_registerNSprefix($prefix, $uri, 0) if $uri;

    error __x"No namespace for prefix `{prefix}' in `{type}' at {where}"
      , prefix => $prefix, type => $type, where => $where, _class => 'schema'
        if length $prefix && !defined $uri;

    pack_type $uri, $local;
}

sub _registerNSprefix($$$)
{   my ($self, $prefix, $uri, $used) = @_;
    my $table = $self->{prefixes};

    if(my $u = $table->{$uri})    # namespace already has a prefix
    {   $u->{used} += $used;
        return $u->{prefix};
    }

    my %prefs = map { ($_->{prefix} => 1) } values %$table;
    my $take;
    if(defined $prefix && !$prefs{$prefix}) {   $take = $prefix }
    elsif(!$prefs{''}) { $take = '' }
    else
    {   # prefix already in use; create a new x\d+ prefix
        my $count = 0;
        $count++ while exists $prefs{"x$count"};
        $take    = 'x'.$count;
    }
    $table->{$uri} = {prefix => $take, uri => $uri, used => $used};
    $take;
}

sub anyType($)
{   my ($self, $node) = @_;
    pack_type $node->namespaceURI, 'anyType';
}

sub findHooks($$$)
{   my ($self, $path, $type, $node) = @_;
    # where is before, replace, after

#warn $type;
#use Data::Dumper;
#warn Dumper $self->{hooks};
    my %hooks;
    foreach my $hook (@{$self->{hooks}})
    {   my $match;

        $match++
            if !$hook->{path} && !$hook->{id} && !$hook->{type};

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
            my ($ns, $local) = unpack_type $type;
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

# Namespace blocks, in most cases because the schema refers to an
# older version of itself, which is deprecated.
# performance is important, because it is called increadably often.

sub decodeBlocked($)
{   my ($self, $what) = @_;
    defined $what or return;
    my @blocked;   # code-refs called with ($type, $ns, $local, $path)
    foreach my $w (ref $what eq 'ARRAY' ? @$what : $what)
    {   push @blocked,
            !ref $w             ? sub { $_[0] eq $w || $_[1] eq $w }
          : ref $w eq 'HASH'
          ? sub { defined $w->{$_[0]} ? $w->{$_[0]} : $w->{$_[1]} }
          : ref $what eq 'CODE' ? $w
          : error __x"blocking rule with {what} not supported", what => $w;
    }
    \@blocked;
}

sub blocked($$$)
{   my ($self, $path, $class, $type) = @_;
    # $class = simpleType, complexType, or ref
    @{$self->{blocked_nss}} or return ();

    my ($ns, $local) = unpack_type $type;
    my $is_blocked;
    foreach my $blocked ( @{$self->{blocked_nss}} )
    {   $is_blocked = $blocked->($type, $ns, $local, $path);
        last if defined $is_blocked;
    }
    $is_blocked or return;

    trace "$type of $class is blocked";

    $self->makeBlocked($path, $class, $type);
}


1;
