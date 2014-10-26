use warnings;
use strict;

package XML::Compile::Translate;

# Errors are either in _class 'usage': called with request
#                         or 'schema': syntax error in schema

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util  'first';

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInFacets;
use XML::Compile::Schema::BuiltInTypes qw/%builtin_types/;
use XML::Compile::Util                 qw/pack_type unpack_type type_of_node/;
use XML::Compile::Iterator             ();

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

=chapter NAME

XML::Compile::Translate - create an XML data parser

=chapter SYNOPSIS

 # for internal use only
 my $code = XML::Compile::Translate->compile(...);

=chapter DESCRIPTION

This module converts a schema type definition into a code
reference which can be used to interpret a schema.  The sole public
function in this package is M<compile()>, and is called by
M<XML::Compile::Schema::compile()>, which does a lot of set-ups.
Please do not try to use this package directly!

The code in this package interprets schemas; it understands, for
instance, how complexType definitions work.  Then, when the
schema syntax is decoded, it will knot the pieces together into
one CODE reference which can be used in the main user program.

=section Unsupported features

This implementation is work in progress, but by far most structures in
W3C schemas are implemented (and tested!).

Missing are
 schema noNamespaceSchemaLocation
 any ##local
 anyAttribute ##local

Some things do not work in schemas anyway: C<import>, C<include>.  They
only work if everyone always has a working connection to internet.  You
have to require them manually.  Include also does work, because it does not
use namespaces.  (see M<XML::Compile::Schema::importDefinitions()>)

Ignored, because not for our purpose is the search optimization
information: C<key, unique, keyref, selector, field>, and de schema
documentation: C<notation, annotation>.  Compile the schema schema itself
to interpret the message if you need them.

A few nuts are still to crack:
 any* processContents always interpreted as lax
 openContent
 attribute limitiations (facets) on dates
 full understanding of patterns (now limited)
 final is not protected

Of course, the latter list is all fixed in next release ;-)
See chapter L</DETAILS> for more on how the tune the translator.

=chapter METHODS

=section Constructors

=method new TRANSLATOR, OPTIONS
The OPTIONS are described in M<XML::Compile::Schema::compile()>.  Those
descriptions will probably move here, eventually.

=requires nss L<XML::Compile::Schema::NameSpaces>
=cut

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

    $self->{nss} = $args->{nss} or panic "no namespace tables";
    $self->{prefixes} ||= {};

    $self;
}

=ci_method register NAME
Register a new back-end.
=example
 use XML::Compile::Translate::SomeBackend;
 XML::Compile::Translate::SomeBackend->register('SomeNAME');
 my $coderef = $schemas->compile('SomeNAME' => ...);
=cut

sub register($)
{  my ($class, $name) = @_;
   UNIVERSAL::isa($class, __PACKAGE__)
       or error __x"back-end {class} does not extend {base}"
            , class => $class, base => __PACKAGE__;
   $translators{$name} = $class;
}

=section Attributes
=cut

# may disappear, so not documented publicly (yet)
sub actsAs($) { panic "not implemented" }

=section Handlers

=c_method compile ELEMENT|ATTRIBUTE|TYPE, OPTIONS
Do not call this function yourself, but use
M<XML::Compile::Schema::compile()> (or wrappers around that).

This function returns a CODE reference, which can translate
between Perl datastructures and XML, based on a schema.  Before
this method is called is the schema already translated into
a table of types.
=cut

sub compile($@)
{   my ($self, $item, %args) = @_;
    @$self{keys %args} = values %args;  # dirty

    my $path   = $item;
    ref $item
        and panic "expecting an item as point to start at $path";

    my $hooks   = $self->{hooks}   ||= [];
    my $typemap = $self->{typemap} ||= {};
    $self->typemapToHooks($hooks, $typemap);

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

      $self->{include_namespaces}
    ? $self->makeWrapperNs($path, $produce, $self->{prefixes})
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
    my $internal = XML::Compile::Schema::Specs->builtInType
       (undef, $fullname, sloppy_integers => $self->{sloppy_integers});

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

      $name eq 'element'
    ? $self->makeElementWrapper($path, $make)
    : $self->makeAttributeWrapper($path, $make);
}

sub typeByName($$)
{   my ($self, $tree, $typename) = @_;

    #
    # First try to catch build-ins
    #

    my $node  = $tree->node;
    my $def   = XML::Compile::Schema::Specs->builtInType
       ($node, $typename, sloppy_integers => $self->{sloppy_integers});

    if($def)
    {   my $where = $typename;
        my $st = $self->makeBuiltin($where, $node, $typename, $def, $self->{check_values});

        return +{ st => $st, is_list => $def->{is_list} };
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

    my $do = $self->makeUnion($where, @types);
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

    my $do = $self->applySimpleFacets($tree, $st, $in_list || $base->{is_list});

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
    foreach my $ordered ( qw/whiteSpace/ )
    {   my $limit = delete $facets{$ordered};
        push @early, builtin_facet($where, $self, $ordered, $limit)
           if defined $limit;
    }

    my @late
      = map { builtin_facet($where, $self, $_, $facets{$_}) }
            keys %facets;

      $in_list
    ? $self->makeFacetsList($where, $st, \%facets_info, \@early, \@late)
    : $self->makeFacets($where, $st, \%facets_info, @early, @late);
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

    my ($componentsname, $components);
    my $nr_childs = $tree->nrChildren;
    if(my $isa = $node->getAttribute('type'))
    {   $nr_childs==0
            or error __x"no childs expected with attribute `type' at {where}"
                   , where => $where, _class => 'schema';

        $componentsname = $self->rel2abs($where, $node, $isa);
        $components     = $self->typeByName($tree, $componentsname);
    }
    elsif($nr_childs==0)
    {   $componentsname = $self->anyType($node);
        $components     = $self->typeByName($tree, $componentsname);
    }
    elsif($nr_childs!=1)
    {   error __x"expected is only one child at {where}"
          , where => $where, _class => 'schema';
    }
    else # nameless types
    {   my $child = $tree->firstChild;
        my $local = $child->localname;
        my $nest  = $tree->descend($child);

        $components
          = $local eq 'simpleType'  ? $self->simpleType($nest, 0)
          : $local eq 'complexType' ? $self->complexType($nest)
          : error __x"illegal element child `{name}' at {where}"
                , name => $local, where => $where, _class => 'schema';
    }

    my ($st, $elems, $attrs, $attrs_any)
      = @$components{ qw/st elems attrs attrs_any/ };
    $_ ||= [] for $elems, $attrs, $attrs_any;

    # Collect the hooks

    my ($before, $replace, $after)
      = $self->findHooks($where, $componentsname, $node);

    # Construct basic element handler
    my $r;
    if($replace) { ; }             # do not attempt to compile
    elsif($components->{mixed})    # complexType mixed
    {   $r = $self->makeMixedElement($where, $tag, $elems, $attrs, $attrs_any);
    }
    elsif(! defined $st)           # complexType
    {   $r = $self->makeComplexElement($where, $tag, $elems, $attrs,$attrs_any);
    }
    elsif(@$attrs || @$attrs_any)  # complex simpleContent
    {   $r = $self->makeTaggedElement($where, $tag, $st, $attrs, $attrs_any);
    }
    else                           # simple
    {   $r = $self->makeSimpleElement($where, $tag, $st);
    }

    # Implement hooks

    my $do = ($before || $replace || $after)
      ? $self->makeHook($where, $r, $tag, $before, $replace, $after)
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

    my $required;
    $required = $self->makeRequired($where, $label, $process) if $min!=0;

    my $key   = $local eq 'element' ? $self->keyRewrite($label) : $label;
    my $do    =
        $self->makeElementHandler($where, $key, $min, $max, $required,$process);

    ( ($self->actsAs('READER') ? $label : $key) => $do);
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

sub findSgMembers($)
{   my ($self, $type) = @_;
    my @subgrps;
    foreach my $s ($self->namespaces->findSgMembers($type))
    {   push @subgrps, $s, $self->findSgMembers($s->{full});
    }

#warn "SUBGRPS for $type\n  ", join "\n  ", map {$_->{full}} @subgrps;
    @subgrps;
}

sub particleElementRef($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;
    my $where = $tree->path . '#subst';

    my $name  = $node->getAttribute('name'); # toplevel always has a name
    my $type  = pack_type $self->{tns}, $name;

    my @sgs   = $self->findSgMembers($type);
    @sgs or return $self->particleElement($tree); # simple

#warn "SUBST $type\n";
#warn "  $_->{full}\n" for @sgs;
    my ($label, $do) = $self->particleElement($tree);
    my @elems = ($label => [$self->keyRewrite($label), $do]);

    foreach my $subst (@sgs)
    {    local @$self{ qw/elems_qual attrs_qual tns/ }
            = $self->nsContext($subst);

         my $subst_elem = $tree->descend($subst->{node});
         my ($l, $d) = $self->particleElement($subst_elem);
         push @elems, $l => [$self->keyRewrite($l), $d];
    } 

    ($name => $self->makeSubstgroup($where, $type, @elems));
}

sub particleElement($)
{   my ($self, $tree) = @_;

    my $node  = $tree->node;

    if(my $ref =  $node->getAttribute('ref'))
    {   my $refname  = $self->rel2abs($tree, $node, $ref);
        my $where    = $tree->path . "/$ref";
 
        my $def      = $self->namespaces->find(element => $refname)
            or error __x"cannot find ref element '{name}' at {where}"
                   , name => $refname, where => $where, _class => 'schema';

        my $refnode  = $def->{node};

        local @$self{ qw/elems_qual attrs_qual tns/ }
            = $self->nsContext($def);

        return $self->particleElementRef($tree->descend($refnode));
    }

    my $name     = $node->getAttribute('name')
        or error __x"element needs name or ref at {where}"
             , where => $tree->path, _class => 'schema';
    my $full     = pack_type $self->{tns}, $name;

    my $where    = $tree->path . '/' . $name;
    my $default  = $node->getAttributeNode('default');
    my $fixed    = $node->getAttributeNode('fixed');

    $default && $fixed
        and error __x"element can not have default and fixed at {where}"
              , where => $tree->path, _class => 'schema';

    my $nillable = $node->getAttribute('nillable') || 'false';
    my $abstract = $node->getAttribute('abstract') || 'false';

    my $do       = $self->element($tree->descend($node, $name));

    my $value
       = $default ? $default->textContent
       : $fixed   ? $fixed->textContent
       :            undef;

    my $generate
     = $self->isTrue($abstract) ? 'makeElementAbstract'
     : $self->isTrue($nillable) ? 'makeElementNillable'
     : $default   ? 'makeElementDefault'
     : $fixed     ? 'makeElementFixed'
     :              'makeElement';

    my $nodetype  = $self->{elems_qual} ? $full : $name;
    my $ns    = $self->{tns}; #$node->namespaceURI;
    my $do_el = $self->$generate($where, $ns, $nodetype, $do, $value);

    # hrefs are used by SOAP-RPC
    $do_el    = $self->makeElementHref($where, $ns, $nodetype, $do_el)
        if $self->{permit_href} && $self->actsAs('READER');
 
    ($nodetype => $do_el);
}

sub keyRewrite($)
{   my ($self, $label) = @_;
    my ($ns, $key) = unpack_type $label;
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
        if $key ne $oldkey;

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

    my $trans   = $qual ? 'makeTagQualified' : 'makeTagUnqualified';
    my $ns      = $qual ? $self->{tns} : '';
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
    my $do    = $self->$generate($where, $ns, $tag, $st, $value);
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
    $mixed ||= $self->isTrue($node->getAttribute('mixed') || 'false');
  
    $tree->nrChildren == 1
        or error __x"only one complexContent child expected at {where}"
             , where => $tree->path, _class => 'schema';

    my $name  = $tree->currentLocal;
 
    error __x"complexContent needs extension or restriction, not `{name}' at {where}"
       , name => $name, where => $tree->path, _class => 'schema'
           if $name ne 'extension' && $name ne 'restriction';

# variable rename needed
    $tree     = $tree->descend;
    $node     = $tree->node;
    my $base  = $node->getAttribute('base') || 'anyType';
    my $type  = {};
    my $where = $tree->path . '#cce';

use Data::Dumper;
    if($base ne 'anyType')
    {   my $typename = $self->rel2abs($where, $node, $base);
        my $typedef  = $self->namespaces->find(complexType => $typename)
            or error __x"unknown base type '{type}' at {where}"
                 , type => $typename, where => $tree->path, _class => 'schema';

        local @$self{ qw/elems_qual attrs_qual tns/ }
            = $self->nsContext($typedef);

        $type = $self->complexType($tree->descend($typedef->{node}));
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

sub complexMixed($)
{   my ($self, $tree) = @_;
    { mixed => 1 };
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
    $self->_registerNSprefix($self->{prefixes}, $prefix, $uri) if $uri;

    error __x"No namespace for prefix `{prefix}' in `{type}' at {where}"
      , prefix => $prefix, type => $type, where => $where, _class => 'schema'
        if length $prefix && !defined $uri;

    pack_type $uri, $local;
}

sub _registerNSprefix($$$)
{   my ($self, $table, $prefix, $uri) = @_;

    return $table->{$uri}{prefix}
        if $table->{$uri}; # namespace already has a prefix

    my %prefs = map { ($_->{prefix} => 1) } values %$table;
    my $take;
    if(!$prefs{$prefix}) { $take = $prefix }
    elsif(!$prefs{''})   { $take = '' }
    else
    {   # prefix already in use; create a new x\d+ prefix
        my $count = 0;
        $count++ while exists $prefs{"x$count"};
        $take    = 'x'.$count;
    }
    $self->{prefixes}{$uri} = {prefix => $take, uri => $uri, used => 0};
    $take;
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

=chapter DETAILS

=section Translator options

=subsection performance optimization

The M<XML::Compile::Schema::compile()> method (and wrappers) defines
a set options to improve performance or usability.  These options
are translated into the executed code: compile time, not run-time!

The following options with their implications:

=over 4

=item sloppy_integers BOOLEAN

The C<integer> type, as defined by the schema built-in specification,
accepts really huge values.  Also the derived types, like
C<nonNegativeInteger> can contain much larger values than Perl's
internal C<long>.  Therefore, the module will start to use M<Math::BigInt>
for these types if needed.

However, in most cases, people design C<integer> where an C<int> suffices.
The use of big-int values comes with heigh performance costs.  Set this
option to C<true> when you are sure that ALL USES of C<integer> in the
scheme will fit into signed longs (are between -2147483648 and 2147483647
inclusive)

If you do not want limit the number-space, you can safely add
  use Math::BigInt try => 'GMP'
to the top of your main program, and install M<Math::BigInt::GMP>.  Then,
a C library will do the work, much faster than the Perl implementation.

=item check_values BOOLEAN

Check the validity of the values, before parsing them.  This will
report errors for the reader, instead of crashes.  The writer will
not produce invalid data.

=item check_occurs BOOLEAN

Checking whether the number of occurrences for an item are between
C<minOccurs> and C<maxOccurs> (implied for C<all>, C<sequence>, and
C<choice> or explictly specified) takes time.  Of course, in cases
errors must be handled.  When this option is set to C<false>, 
only distinction between single and array elements is made.

=item ignore_facets BOOLEAN

Facets limit field content in the restriction block of a simpleType.
When this option is C<true>, no checks are performed on the values.
In some cases, this may cause problems: especially with whiteSpace and
digits of floats.  However, you may be able to control this yourself.
In most cases, luck even plays a part in this.  Less checks means a
better performance.

Simple type restrictions are not implemented by other XML perl
modules.  When the schema is nicely detailed, this will give
extra security.

=item validation BOOLEAN

When used, it overrules the above C<check_values>, C<check_occurs>, and
C<ignore_facets> options.  A true value enables all checks, a false
value will disable them all.  Of course, the latter is the fastest but
also less secure: your program will need to validate the values in some
other way.

XML::LibXML has its own validate method, but I have not yet seen any
performance figures on that.  If you use it, however, it is of course
a good idea to turn XML::Compile's validation off.

=back

=subsection qualified XML

The produced XML may not use the name-spaces as defined by the schemas,
just to simplify the input and output.  The structural definition of
the schemas is still in-tact, but name-space collission may appear.

Per schema, it can be specified whether the elements and attributes
defined in-there need to be used qualified (with prefix) or not.
This can cause horrible output when within an unqualified schema
elements are used from an other schema which is qualified.

The suggested solution in articles about the subject is to provide
people with both a schema which is qualified as one which is not.
Perl is known to be blunt in its approach: we simply define a flag
which can force one of both on all schemas together, using
C<elements_qualified> and C<attributes_qualified>.  May people and
applications do not understand name-spaces sufficiently, and these
options may make your day!

=subsection Name-spaces

The translator does respect name-spaces, but not all senders and
receivers of XML are name-space capable.  Therefore, you have some
options to interfere.

=over 4

=item prefixes HASH|ARRAY-of-PAIRS
The translator will create XML elements (WRITER) which use name-spaces,
based on its own name-space/prefix mapping administration.  This is
needed because the XML tree is created bottom-up, where XML::LibXML
namespace management can only handle this top-down.

When your pass your own HASH as argument, you can explicitly specify the
prefixes you like to be used for which name-space.  Found name-spaces
will be added to the HASH, as well the use count.  When a new name-space
URI is discovered, an attempt is made to use the prefix as found in
the schema. Prefix collisions are actively avoided: when two URIs want
the same prefix, a sequence number is added to one of them which makes
it unique.

The HASH structure looks like this:

  my %namespaces =
    ( myns => { uri => 'myns', prefix => 'mypref', used => 1}
    , ...  => { uri => ... }
    );

  my $make = $schema->compile
    ( WRITER => ...
    , prefixes => \%namespaces
    );

  # share the same namespace defs with an other component
  my $other = $schema->compile
    ( WRITER => ...
    , prefixes => \%namespaces
    );

When used is specified and larger than 0, then the namespace will
appear in the top-level output element (unless C<include_namespaces>
is false).

Initializing using an ARRAY is a little simpler:

 prefixes => [ mypref => 'myns', ... => ... ];

However, be warned that this does not work well with a false value
for C<include_namespaces>: detected namespaces are added to an
internal HASH now, which is not returned; that information is lost.
You will need to know each used namespace beforehand.

=item include_namespaces BOOLEAN
When true and WRITER, the top level returned XML element will contain
the prefix definitions.  Only name-spaces which are actually used
will be included (a count is kept by the translator).  It may
very well list name-spaces which are not in the actual output
because the fields which require them are not included for there is
not value for those fields.

If you like to combine XML output from separate translated parts
(for instance in case of generating SOAP), you may want to delay
the inclusion of name-spaces until a higher level of the XML
hierarchy which is produced later.

=item namespace_reset BOOLEAN
You can pass the same HASH to a next call to a reader or writer to get
consistent name-space usage.  However, when C<include_namespaces> is
used, you may get ghost name-space listings.  This option will reset
the counts on all defined name-spaces.

=item use_default_namespace BOOLEAN (added in release 0.57)
When a true value, the blank prefix will be used for the first namespace
URI which requires a auto-generated prefix.  However, in quite some
environments, people mix horrible non-namespace qualified elements with 
nice namespace qualified elements.  In such situations, namespace the
qualified-but-default prefix (i.e., no prefix) is confusing.  Therefore,
the option defaults to false: do not use the invisible prefix.

You may explicitly specify a blank prefix with C<prefixes>,
which will be used when applicable.
=back

=subsection Wildcards handlers

Wildcards are a serious complication: the C<any> and C<anyAttribute>
entities do not describe exactly what can be found, which seriously
hinders the quality of validation and the preparation of M<XML::Compile>.
Therefore, if you use them then you need to process that parts of
XML yourself.  See the various backends on how to create or process
these elements.

Automatic decoding is problematic: you do not know what to expect, so
cannot prepare for these data-structures compile-time.  However,
M<XML::Compile::Cache> offers a way out: you can declare the handlers
for these "any" components and therewith be prepared for them.  With
C<XML::Compile::Cache::new(allow_undeclared)>, you can permit run-time
compilation of  the found components.

=over 4

=item any_element CODE|'TAKE_ALL'|'SKIP_ALL'
[0.89] This will be called when the type definition contains an C<any>
definition, after processing the other element components.  By
default, all C<any> specifications will be ignored.

=item any_attribute CODE|'TAKE_ALL'|'SKIP_ALL'
[0.89] This will be called when the type definitions contains an
C<anyAttribute> definition, after processing the other attributes.
By default, all C<anyAttribute> specifications will be ignored.

=back

=cut

1;
