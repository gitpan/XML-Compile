
use warnings;
use strict;

package XML::Compile::Schema::Translate;
use vars '$VERSION';
$VERSION = '0.06';
use base 'Exporter';

our @EXPORT = 'compile_tree';

use Carp;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInFacets;
use XML::Compile::Schema::BuiltInTypes   qw/%builtin_types/;

sub _rel2abs($$);


sub compile_tree($@)
{   my ($element, %args) = @_;

    ref $element
       and croak 'ERROR: expecting an element name as point to start';
 
#warn "$element";
    my $nss    = $args{nss};
    my $top    = $nss->findID($element)
              || $nss->findElement($element)
       or croak "ERROR: cannot find element $element";

    my $node   = $top->{node};
    my $path   = $element;

    my $local  = $node->localName;
    $local eq 'element'
       or croak "ERROR: $element is not an element";

    local $args{elems_qual} = exists $args{elements_qualified}
     ? $args{elements_qualified} : $top->{efd} eq 'qualified';
    local $args{tns}        = $top->{ns};

    my $make   = _element($path, \%args, $top->{node});
    my $produce= $args{run}{wrapper}->($make);

      $args{include_namespaces}
    ? $args{run}{wrapper_ns}->($produce, $args{output_namespaces})
    : $produce;
}

sub _assert_type($$$$)
{   my ($path, $field, $type, $value) = @_;
    return if $builtin_types{$type}{check}->($value);
    die "ERROR: Field $field contains `$value' which is not a valid $type.\n";
}

sub _childs($)   # returns only elements in same name-space
{   my $node = shift;
    my $ns   = $node->namespaceURI;
    grep {   $_->isa('XML::LibXML::Element')
          && $_->namespaceURI eq $ns
          && $_->localName !~ m/^(?:an)notation$/
         } $node->childNodes;
}

sub in_schema_schema($)
{   my ($uri, $type) = $_[0] =~ m/^\{(.*?)\}(.*)$/
       or croak "ERROR: not a type $_[0]";
    XML::Compile::Schema::Specs->predefinedSchema($uri);
}

sub _type_by_name($$$)
{   my ($path, $args, $typename) = @_;

    my $nss    = $args->{nss};

    #
    # First try to catch build-ins
    #

    my $code = XML::Compile::Schema::Specs->builtInType
       ($typename, sloppy_integers => $args->{sloppy_integers});

    if($code)
    {
#warn "TYPE FINAL: $typename\n";
        my $type = $args->{run}
         ->{$args->{check_values} ? 'builtin_checked' : 'builtin_unchecked'}
         ->($path, $args, $typename, $code);

        return {st => $type};
    }

    #
    # Then try own schema's
    #

    my $top    = $nss->findType($typename)
       or croak "ERROR: cannot find type $typename for $path\n";

    _type_by_top($path, $args, $top);
}

sub _type_by_top($$$)
{   my ($path, $args, $top) = @_;
    my $node = $top->{node};

    #
    # Setup default name-space processing
    #

    my $elems_qual
     = exists $args->{elements_qualified} ? $args->{elements_qualified}
     : $top->{efd} eq 'qualified';

    my $attrs_qual
     = exists $args->{attributes_qualified} ? $args->{attributes_qualified}
     : $top->{afd} eq 'qualified';

    local $args->{elems_qual} = $elems_qual;
    local $args->{attrs_qual} = $attrs_qual;
    local $args->{tns}        = $top->{ns};
    my $local = $node->localName;

      $local eq 'simpleType'  ? _simpleType ($path, $args, $node)
    : $local eq 'complexType' ? _complexType($path, $args, $node)
    : croak "ERROR: expecting simpleType or complexType, not '$local' in $path\n";
}

sub _ref_type($$$$)
{   my ($path, $args, $typename, $kind) = @_;

    my $nss    = $args->{nss};
    my $top    = $nss->findElement($typename)
       or croak "ERROR: cannot find ref-type $typename for $path\n";

    my $node   = $top->{node};
    my $local  = $node->localname;
    if($local ne $kind)
    {   croak "ERROR: $path $typename should refer to a $kind, not a $local";
    }
  
    $node;
}

sub _simpleType($$$$)
{   my ($path, $args, $node, $in_list) = @_;

    my @childs = _childs($node);
    @childs==1
       or croak "ERROR: simpleType must have only one child in $path";

    my $child = shift @childs;
    my $local = $child->localName;

    my $type
    = $local eq 'restriction'
                        ? _simple_restriction($path, $args, $child, $in_list)
    : $local eq 'list'  ? _simple_list($path, $args, $child)
    : $local eq 'union' ? _simple_union($path, $args, $child)
    : croak "ERROR: simpleType contains $local, must be restriction, list, or union in $path\n";

    delete $type->{attrs};

    $type;
}

sub _simple_list($$$)
{   my ($path, $args, $node) = @_;

    my $per_item;
    if(my $type = $node->getAttribute('itemType'))
    {   my $typename = _rel2abs($node, $type);
        $per_item    = _type_by_name($path, $args, $typename);
    }
    else
    {   my @childs   = _childs($node);
        @childs==1
           or croak "ERROR: expected one simpleType child or itemType attribute in $path";

        my $child    = shift @childs;
        my $local    = $child->localName;
        $local eq 'simpleType'
           or croak "ERROR: simple list container can only have simpleType";

        $per_item    = _simpleType($path, $args, $child, 1);
    }

    my $st = $per_item->{st}
        or croak "ERROR: list must be of simple type in $path";

    my $do = $args->{run}{list}->($path, $args, $st);

    $per_item->{st} = $do;
    $per_item->{is_list} = 1;
    $per_item;
}

sub _simple_union($$$)
{   my ($path, $args, $node) = @_;

    my @types;

    # Normal error handling switched off, and check_values must be on
    # When check_values is off, we may decide later to treat that as
    # string, which is faster but not 100% safe, where int 2 may be
    # formatted as float 1.999

    my $err = $args->{err};
    local $args->{err} = sub {undef}; #sub {warn "UNION no match @_\n"; undef};
    local $args->{check_values} = 1;

    if(my $members = $node->getAttribute('memberTypes'))
    {   foreach my $type (split " ", $members)
        {   my $typename = _rel2abs($node, $type);
            my $type = _type_by_name($path, $args, $typename);
            my $st   = $type->{st}
               or croak "ERROR: union only of simpleTypes in $path";

            push @types, $st;
        }
    }

    foreach my $child (_childs($node))
    {   my $local = $child->localName;

        $local eq 'simpleType'
           or croak "ERROR: only simpleType's within union in $path\n";

        my $type = _simpleType($path, $args, $child, 0);
        push @types, $type->{st};
    }

    my $do = $args->{run}{union}->($path, $args, $err, @types);
    { st => $do, is_union => 1 };
}

sub _simple_restriction($$$$)
{   my ($path, $args, $node, $in_list) = @_;
    my $base;

    if(my $basename = $node->getAttribute('base'))
    {   my $typename = _rel2abs($node, $basename);
        $base        = _type_by_name($path, $args, $typename);
        defined $base->{st}
           or croak "ERROR: base $basename for simple-restriction is not simpleType in $path";
    }

    # Collect the facets

    my (%facets, @attr_nodes);
  FACET:
    foreach my $child (_childs($node))
    {   my $facet = $child->localName;

        if($facet eq 'simpleType')
        {   $base = _type_by_name("$path/st", $args, $facet);
            next FACET;
        }

        if($facet eq 'attribute' || $facet eq 'anyAttribute')
        {   push @attr_nodes, $child;
            next FACET;
        }

        my $value = $child->getAttribute('value');
        defined $value or die "ERROR: no value for facet $facet in $path\n";

           if($facet eq 'enumeration') { push @{$facets{enumeration}}, $value }
        elsif($facet eq 'pattern')     { push @{$facets{pattern}}, $value }
        elsif(exists $facets{$facet})
        {   croak "ERROR: facet $facet defined twice in $path\n" }
        else
        {   $facets{$facet} = $value }
    }

    defined $base
       or croak "ERROR: simple-restriction requires either base or simpleType in $path\n";

    my @attrs = _attribute_list($path, $args, @attr_nodes);

    my $st = $base->{st};
    return { st => $st, attrs => \@attrs }
        if $args->{ignore_facets} || !keys %facets;

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
    foreach my $facet ( qw/whiteSpace pattern/ )
    {   my $value = delete $facets{$facet};
        push @early, builtin_facet($path, $args, $facet, $value)
           if defined $value;
    }

    my @late;
    foreach my $facet (keys %facets)
    {   push @late, builtin_facet($path, $args, $facet, $facets{$facet});
    }

    my $do = $in_list
           ? $args->{run}{facets_list}->($path, $args, $st, \@early, \@late)
           : $args->{run}{facets}->($path, $args, $st, @early, @late);

   {st => $do, attrs => \@attrs};
}

sub _element($$$);
sub _element($$$)
{   my ($path, $args, $node) = @_;
#warn "element: $path\n";

    my $do;
    my @childs   = _childs($node);
    if(my $ref = $node->getAttribute('ref'))
    {   @childs
           and croak "ERROR: no childs expected within element ref in $path\n";

        my $typename = _rel2abs($node, $ref);
        my $dest     = _ref_type($path, $args, $typename, 'element')
           or return ();
        $path       .= "/ref($ref)";
        return _element($path, $args, $dest);
    }

    my $name     = $node->getAttribute('name')
       or croak "ERROR: element $path without name";
    _assert_type($path, name => NCName => $name);
    $path       .= "/el($name)";

    my $qual     = $args->{elems_qual};
    if(my $form = $node->getAttribute('form'))
    {   $qual = $form eq 'qualified'   ? 1
              : $form eq 'unqualified' ? 0
              : croak "ERROR: form must be (un)qualified, not $form";
    }

    my $trans    = $qual ? 'tag_qualified' : 'tag_unqualified';
    my $tag      = $args->{run}{$trans}->($args, $node, $name);

    if(my $type = $node->getAttribute('type'))
    {   @childs and warn "ERROR: no childs expected with type in $path\n";
        my $typename = _rel2abs($node, $type);
        $do = _type_by_name($path, $args, $typename);
    }
    elsif(!@childs)
    {   my $typename = _rel2abs($node, 'anyType');
        $do = _type_by_name($path, $args, $typename);
    }
    else
    {   @childs > 1
           and die "ERROR: expected is only one child in $path\n";
 
        # nameless types
        my $child = $childs[0];
        my $local = $child->localname;
        $do = $local eq 'simpleType'  ? _simpleType($path, $args, $child, 0)
            : $local eq 'complexType' ? _complexType($path, $args, $child)
            : $local =~ m/^(sequence|choice|all|group)$/
            ?                           _complexType($path, $args, $child)
            : die "ERROR: unexpected element child $local at $path\n";
    }

    my $attrs = $do->{attrs};
    if(my $elems = $do->{elems})
    {   my @do = @$elems;
        push @do, @$attrs if $attrs;

        return $args->{run}{create_complex_element}
                    ->($path, $args, $tag, @do);
    }

    if(defined $attrs)
    {   return $args->{run}{create_tagged_element}
                    ->($path, $args, $tag, $do->{st}, $attrs);
    }

    $args->{run}{create_simple_element}
         ->($path, $args, $tag, $do->{st});
}

sub _particles($$$$$)
{   my ($path, $args, $node, $min, $max) = @_;
#warn "Particles ".$node->localName;
    map { _particle($path, $args, $_, $min, $max) } _childs($node);
}

sub _particle($$$$$);
sub _particle($$$$$)
{   my ($path, $args, $node, $min_default, $max_default) = @_;

    my $local = $node->localName;
    my $min   = $node->getAttribute('minOccurs');
    my $max   = $node->getAttribute('maxOccurs');

#warn "Particle: $local\n";
    my @do;

    if($local eq 'sequence' || $local eq 'choice' || $local eq 'all')
    {   defined $min or $min = $local eq 'choice' ? 0 : 1;
        defined $max or $max = 1;
        return _particles($path, $args, $node, $min, $max)
    }

    if($local eq 'group')
    {   my $ref = $node->getAttribute('ref')
           or croak "ERROR: group $path without ref";

        $path     .= "/gr";
        my $typename = _rel2abs($node, $ref);
#warn $typename;

        my $dest   = _ref_type("$path/gr", $args, $typename, 'group');
        return _particles($path, $args, $dest, $min, $max);
    }

    return ()
        if $local ne 'element';

    defined $min or $min = $min_default;
    defined $max or $max = $max_default;

    my $do = _element($path, $args, $node);
    my $name = $node->getAttribute('name');
#warn "    is element $name";

    my $nillable = 0;
    if(my $nil = $node->getAttribute('nillable'))
    {    $nillable = $nil eq 'true';
    }

    my $default = $node->getAttributeNode('default');
    my $fixed   = $node->getAttributeNode('fixed');

    my $generate
     = ($max eq 'unbounded' || $max > 1)
     ? ( $args->{check_occurs}
       ? 'element_repeated'
       : 'element_array'
       )
     : ($args->{check_occurs} && $min==1)
     ? ( $nillable        ? 'element_nillable'
       : defined $fixed   ? 'element_fixed'
       :                    'element_obligatory'
       )
     : ( defined $default ? 'element_default'
       : defined $fixed   ? 'element_fixed'
       : 'element_optional'
       );

    my $value = defined $default ? $default : $fixed;
    my $ns    = $node->namespaceURI;

    ( $name
      => $args->{run}{$generate}
            ->("$path/$name", $args, $ns, $name, $do, $min, $max, $value)
    );
}

sub _attribute($$$)
{   my ($path, $args, $node) = @_;

    my $name = $node->getAttribute('name')
       or croak "ERROR: attribute $path without name";

    $path   .= "/at($name)";

    my $qual = $args->{attrs_qual};
    if(my $form = $node->getAttribute('form'))
    {   $qual = $form eq 'qualified'   ? 1
              : $form eq 'unqualified' ? 0
              : croak "ERROR: form must be (un)qualified, not $form";
    }

    my $trans    = $qual ? 'tag_qualified' : 'tag_unqualified';
    my $tag  = $args->{run}{$trans}->($args, $node, $name);

    my $do;
    my $typeattr = $node->getAttribute('type')
       or croak "ERROR: attribute without type in $path\n";

    my $typename = _rel2abs($node, $typeattr);
    my $type     = _type_by_name($path, $args, $typename);
    my $st       = $type->{st}
        or croak "ERROR: attribute not based in simple value type in $path\n";

    my $use     = $node->getAttribute('use') || 'optional';
    my $default = $node->getAttributeNode('default');
    my $fixed   = $node->getAttributeNode('fixed');

    my $generate
     = defined $default    ? 'attribute_default'
     : defined $fixed      ? 'attribute_fixed'
     : $use eq 'required'  ? 'attribute_required'
     : $use eq 'optional'  ? 'attribute_optional'
     : $use eq 'prohibited'? 'attribute_prohibited'
     : croak "ERROR: attribute use is required, optional or prohibited (not '$use') in $path.\n";

    my $value = defined $default ? $default : $fixed;
    $name => $args->{run}{$generate}->($path, $args, $tag, $st, $value);
}

sub _attribute_group($$$);
sub _attribute_group($$$)
{   my ($path, $args, $node) = @_;

    my $ref = $node->getAttribute('ref')
       or croak "ERROR: attributeGroup $path without ref";

    $path     .= "/ag";
    my $typename = _rel2abs($node, $ref);
#warn $typename;

    my @attrs;
    my $dest   = _ref_type($path, $args, $typename, 'attributeGroup');
    defined $dest or return ();

    foreach my $child (_childs($dest))
    {   my $local = $child->localname;
        if($local eq 'attribute')
        {   push @attrs, _attribute($path, $args, $child) }
        elsif($local eq 'attributeGroup')
        {   push @attrs, _attribute_group($path, $args, $child) }
        else
        {   croak "ERROR: unexpected $local in attributeGroup in $path";
        }
    }

    @attrs;
}

sub _complexType($$$)
{   my ($path, $args, $node) = @_;

    my @childs = _childs($node);
    @childs or croak "ERROR: empty contentType";

    my $first  = shift @childs;
    my $local  = $first->localName;

    if($local eq 'simpleContent')
    {   croak "ERROR: simpleContent must be alone in complexType in $path"
           if @childs;

        return _simpleContent($path, $args, $first);
    }

    my $type;
    if($local eq 'complexContent')
    {   @childs
         && croak "ERROR: complexContent must be alone in complexType in $path";

        return _complexContent($path, $args, $first);
    }

    _complex_body($path, $args, $node);
}

sub _complex_body($$$)
{   my ($path, $args, $node) = @_;

    my @childs = _childs($node);

    my $first  = $childs[0] or croak "ERROR: empty body";
    my $local  = $first->localName;

    my @elems;
    if($local =~ m/^(?:sequence|choice|all|group)$/)
    {   @elems = _particle($path, $args, $first, 1, 1);
        shift @childs;
    }
    my @attrs = _attribute_list($path, $args, @childs);

    {elems => \@elems, attrs => \@attrs};
}

sub _attribute_list($$@)
{   my ($path, $args) = (shift, shift);
    my @attrs;

    foreach my $attr (@_)
    {   my $local = $attr->localName;
        if($local eq 'attribute')
        {   push @attrs, _attribute($path, $args, $attr);
        }
        elsif($local eq 'attributeGroup')
        {   push @attrs, _attribute_group($path, $args, $attr);
        }
        else
        {   croak "ERROR: expected is attribute(Group) not $local";
        }
    }

    @attrs;
}

sub _simpleContent($$$)
{   my ($path, $args, $node) = @_;

    my @elems;
    my @childs = _childs($node);
    @childs == 1
      or croak "ERROR: only one simpleContent child";

    my $child  = shift @childs;
    my $name = $child->localName;
 
    return _simpleContent_ext($path, $args, $child)
        if $name eq 'extension';

    # nice for validating, but base can be ignored
    return _simpleContent_res($path, $args, $child)
        if $name eq 'restriction';

    warn "WARN: simpleContent either extension or restriction, not '$name' in $path\n";
    ();
}

sub _simpleContent_ext($$$)
{   my ($path, $args, $node) = @_;

    my $base     = $node->getAttribute('base') || 'anyType';
    my $typename = _rel2abs($node, $base);

    my $basetype = _type_by_name("$path#base", $args, $typename);
    my $st = $basetype->{st}
        or croak "ERROR: base of simpleContent not simple in $path";
 
    my %type     = (st => $st);
    my @attrs    = defined $basetype->{attrs} ? @{$basetype->{attrs}} : ();
    my @childs   = _childs($node);

    push @attrs, _attribute_list($path, $args, @childs)
        if @childs;

    $type{attrs} = \@attrs;
    \%type;
}

sub _simpleContent_res($$$)
{   my ($path, $args, $node) = @_;
    my $type = _simple_restriction($path, $args, $node, 0);

    my $st    = $type->{st}
       or croak "ERROR: not a simpleType in simpleContent/restriction at $path";

    $type;
}

sub _complexContent($$$)
{   my ($path, $args, $node) = @_;

    my @elems;
    my @childs = _childs($node);
    @childs == 1
      or croak "ERROR: only one complexContent child";

    my $child  = shift @childs;
    my $name = $child->localName;
 
    return _complexContent_ext($path, $args, $child)
        if $name eq 'extension';

    # nice for validating, but base can be ignored
    return _complex_body($path, $args, $child)
        if $name eq 'restriction';

    warn "WARN: complexContent either extension or restriction, not '$name' in $path\n";
    ();
}

sub _complexContent_ext($$$)
{   my ($path, $args, $node) = @_;

    my $base = $node->getAttribute('base') || 'anyType';
    my $type = {};

    if($base ne 'anyType')
    {   my $typename = _rel2abs($node, $base);
        my $typedef  = $args->{nss}->findType($typename)
            or die "ERROR: cannot base on unknown $base, at $path";

        $typedef->{type} eq 'complexType'
            or die "ERROR: base $base not complexType, at $path";

        $type = _complex_body($path, $args, $typedef->{node});
    }

    my $own = _complex_body($path, $args, $node);
    push @{$type->{elems}}, @{$own->{elems}};
    push @{$type->{attrs}}, @{$own->{attrs}};
    $type;
}

#
# Helper routines
#

# print _rel2abs($node, '{ns}type')    ->  '{ns}type'
# print _rel2abs($node, 'prefix:type') ->  '{ns(prefix)}type'

sub _rel2abs($$)
{   return $_[1] if substr($_[1], 0, 1) eq '{';

    my ($url, $local)
     = $_[1] =~ m/^(.+?)\:(.*)/
     ? ($_[0]->lookupNamespaceURI($1), $2)
     : ($_[0]->namespaceURI, $_[1]);

     defined $url
         or croak "ERROR: cannot understand type '$_[1]'";

     "{$url}$local";
}

1;
