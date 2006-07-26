
use warnings;
use strict;

package XML::Compile::Schema::Translate;
use vars '$VERSION';
$VERSION = '0.01';
use base 'Exporter';

our @EXPORT = 'compile_tree';

use Carp;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInFacets;

sub _rel2abs($$);


sub compile_tree($@)
{   my ($typename, %args) = @_;

    ref $typename
       and croak 'ERROR: expecting a type name as point to start';
 
    my $processor = _final_type($args{path}, $typename, \%args);
    defined $processor or return ();

    my $produce   = $args{run}{wrapper}->($processor);

      $args{include_namespaces}
    ? $args{run}{wrapper_ns}->($produce, $args{output_namespaces})
    : $produce;
}

sub _final_type($$$)
{   my ($path, $typename, $args) = @_;

    #
    # Is a built-in type?  Special handlers
    #

    my $code = XML::Compile::Schema::Specs->builtInType
       ($typename, sloppy_integers => $args->{sloppy_integers});

    if($code)
    {
#warn "TYPE FINAL: $typename\n";
        return $args->{run}
         ->{$args->{check_values} ? 'builtin_checked' : 'builtin_unchecked'}
         ->($path, $typename, $code, $args);
    }

    #
    # Not a built-in type: a bit more work to do.
    #

    my $top    = $args->{types}{$typename}
       or croak "ERROR: cannot find type $typename for $path\n";

    my $node   = $top->{node};

    my $ns     = $node->namespaceURI;
    my $schema = XML::Compile::Schema::Specs->predefinedSchema($ns);
    defined $schema
       or croak "ERROR: $typename not in a predefined schema namespace";

#warn "TYPE: $typename\n";
    my $label  = $top->{name};
    my $name   = $node->localname;
    local $args->{tns} = $top->{ns};

    if($name eq 'simpleType')
    {   return _simpleType($path, $node, $args) }
    elsif($name eq 'complexType')
    {   return _complexType($path, $node, $args) }
    elsif($name eq 'element')
    {   return _element($path, $node, $args) }

    if($name eq 'group' || $name eq 'attributeGroup')
    {   croak "ERROR: $name is not a final type, only for reference\n" }
    else
    {   croak "ERROR: $name is not understood as final type\n" }
}

sub _ref_type($$$$)
{   my ($path, $typename, $name, $args) = @_;

    my $top    = $args->{types}{$typename}
       or croak "ERROR: cannot find ref-type $typename for $path\n";

    my $node   = $top->{node};
    my $local  = $node->localname;
    if($local ne $name)
    {   croak "ERROR: $path $typename should refer to a $name, not a $local";
    }
  
    $node;
}

sub _simpleType($$$)
{   my ($path, $node, $args) = @_;
#warn "simpleType $path\n";
    my $ns   = $node->namespaceURI;

    foreach my $child ($node->childNodes)
    {   next unless $child->isa('XML::LibXML::Element');
        next if $child->namespaceURI ne $ns;

        my $local = $child->localName;
        next if $local eq 'notation';

        return
        $local eq 'restriction' ? _simple_restriction($path, $child, $args)
      : $local eq 'list'        ? _simple_list($path, $child, $args)
      : $local eq 'union'       ? _simple_union($path, $child, $args)
      : die "ERROR: do not understand simpleType component $local in $path\n";
    }

    die "ERROR: no definition in simpleType in $path\n";
}

sub _simple_list($$$)
{   my ($path, $node, $args) = @_;

    my $type = $node->getAttribute('itemType')
        or die "ERROR: list requires attribute itemType in $path\n";

    my $typename = _rel2abs($node, $type);
    my $per_item = _final_type($path, $typename, $args);

    $args->{run}{list}->($path, $per_item, $args);
}

sub _simple_union($$$)
{   my ($path, $node, $args) = @_;
    my $ns   = $node->namespaceURI;

    my @types;

    # Normal error handling switched off, and check_values must be on
    # When check_values is off, we may decide later to treat that as
    # string, which is faster but not 100% safe, where int 2 may be
    # formatted as float 1.999

    my $err = $args->{err};
    local $args->{err} = sub {undef}; #sub {warn "UNION no match @_\n"; undef};
    local $args->{check_values} = 1;

    foreach my $child ($node->childNodes)
    {   next unless $child->isa('XML::LibXML::Element');
        next if $child->namespaceURI ne $ns;

        my $local = $child->localName;
        next if $local eq 'notation';

        die "ERROR: only simpleType's within union in $path\n"
            if $local ne 'simpleType';

        push @types, _simpleType($path, $child, $args);
    }

    $args->{run}{union}->($path, $args, $err, @types);
}

sub _simple_restriction($$$)
{   my ($path, $node, $args) = @_;
    my $ns = $node->namespaceURI;
    my $st;

    if(my $base = $node->getAttribute('base'))
    {   my $typename = _rel2abs($node, $base);
        $st = _final_type($path, $typename, $args);
    }
    elsif($base = $node->getChildrenByTagNameNS($ns,'simpleType'))
    {   # untested
        $st = _simpleType("$path/st", $base, $args);
    }
    else
    {   die "ERROR: restriction $path requires either base or simpleType\n";
    }

    return $st if $args->{ignore_facets};

    # Collect the facets

    my @childs = grep {$_->isa('XML::LibXML::Element')} $node->childNodes;
    return $st unless @childs;

    my %facets;
    foreach my $child (@childs)
    {   next unless $child->namespaceURI eq $ns;
        my $facet = $child->localName;
        my $value    = $child->getAttribute('value');
        defined $value or die "ERROR: no value for $facet in $path\n";

           if($facet eq 'enumeration') { push @{$facets{enumeration}}, $value }
        elsif($facet eq 'pattern')     { push @{$facets{pattern}}, $value }
        elsif(exists $facets{$facet})
        {   die "ERROR: facet $facet defined twice in $path\n" }
        else
        {   $facets{$facet} = $value }
    }

    if(defined $facets{totalDigits} && defined $facets{fractionDigits})
    {   my $td = delete $facets{totalDigits};
        my $fd = delete $facets{fractionDigits};
        $facets{totalFracDigits} = [$td, $fd];
    }

    # First the strictly ordered facets, then the other facets
    my @rules;

    foreach my $facet ( qw/whiteSpace pattern/ )
    {   my $value = delete $facets{$facet};
        push @rules, builtin_facet($path,$args, $facet, $value)
           if defined $value;
    }

    # <list> types need to split here

    foreach my $facet (keys %facets)
    {   push @rules, builtin_facet($path, $args, $facet, $facets{$facet});
    }

      @rules==0 ? $st
    : @rules==1 ? _call_facet($st, $rules[0])
    :             _call_facets($st, @rules);
}

sub _call_facet($$)
{   my ($st, $facet) = @_;
    sub { my $v = $st->(@_);
          defined $v ? $facet->($v) : $v;
        };
}

sub _call_facets($@)
{   my ($st, @facets) = @_;
    sub { my $v = $st->(@_);
          for(@facets) {defined $v or last; $v = $_->($v)}
          $v;
        };
}

sub _element($$$)
{   my ($path, $node, $args) = @_;
#warn "element: $path\n";

    my $name   = $node->getAttribute('name')
       or croak "ERROR: element $path without name";

    $path     .= "/el($name)";
    my $tag    = $args->{run}{translate_tag}->($node, $name, $args);
    my @childs = grep {$_->isa('XML::LibXML::Element')} $node->childNodes;

    my $do;
    if(my $fixed = $node->getAttribute('fixed'))
    {   @childs and warn "ERROR: no childs expected with fixed in $path\n";
        $do = $args->{run}{element_fixed}->($path, $fixed, $args);
    }
    elsif(my $type = $node->getAttribute('type'))
    {   @childs and warn "ERROR: no childs expected with type in $path\n";
        my $typename = _rel2abs($node, $type);
        $do = _final_type($path, $typename, $args);
    }
    elsif(my $ref = $node->getAttribute('ref'))
    {   @childs and warn "ERROR: no childs expected with ref in $path\n";
        my $typename = _rel2abs($node, $ref);
        my $dest     = _ref_type($path, $typename, 'element', $args)
           or return ();
        $do = _final_type($path, $typename, $args);
        return $args->{run}{rename_element}->($tag, $do);
    }
    elsif(!@childs)
    {   my $typename = _rel2abs($node, 'anyType');
        $do = _final_type($path, $typename, $args);
    }
    else
    {   @childs > 1
           and die "ERROR: expected is only one child in $path\n";
 
        # nameless types
        my $child = $childs[0];
        my $local = $child->localname;
        $do = $local eq 'simpleType'  ? _simpleType($path, $child, $args)
            : $local eq 'complexType' ? _complexType($path, $child, $args)
            : $local =~ m/^(sequence|choice|all|group)$/
            ?                           _complexType($path, $child, $args)
            : die "ERROR: unexpected element child $local at $path\n";
    }

    $args->{run}{create_element}->($path, $tag, $do, $args);
}

sub _choice($$$)
{   my ($path, $node, $args) = @_;
    my $min = $node->getAttribute('minOccurs');
    my $max = $node->getAttribute('maxOccurs');
    defined $min or $min = 0;
    defined $max or $max = 1;

    # sloppy: sum should not exceed max, we let each to max.
    # nested sequences not supported correctly
    map {_particle($path, $_, $min, $max, 0, $max, $args)}
       grep {$_->isa('XML::LibXML::Element')}
           $node->childNodes;
}

sub _particle($$$$$$$)
{   my ( $path, $node, $min_default, $max_default, $min_perm, $max_perm
       , $args) = @_;

    my $ns     = $node->namespaceURI;
    my @childs = $node;
    my @do;

    while(my $child = shift @childs)
    {   next unless $child->isa('XML::LibXML::Element');
        next if $child->namespaceURI ne $ns;
        my $name = $child->localName;

        if($name eq 'sequence')
        {   unshift @childs, $child->childNodes;
            next;
        }

        if($name eq 'group')
        {   unshift @childs, _group_particle($path, $child, $args);
            next;
        }

        if($name eq 'choice')
        {   push @do, _choice($path, $child, $args);
            next;
        }
        # 'all' is not permitted

        next if $name ne 'element';

        my $do = _element($path, $child, $args);
        my $childname = $child->getAttribute('name');

        my $min = $child->getAttribute('minOccurs');
        my $max = $child->getAttribute('maxOccurs');
        defined $min or $min = $min_default;
        defined $max or $max = $max_default;

        if($args->{check_occurs})
        {  $min >= $min_perm
              or croak "ERROR: element min-occur $min below permitted $min_perm\n";

           $max_perm eq 'unbounded' || $max ne 'unbounded' || $max <= $max_perm
              or croak "ERROR: element max-occur $max larger than permitted $max_perm\n";
        }
 
        my $nillable = 0;
        if(my $nil = $child->getAttribute('nillable'))
        {    $nillable = $nil eq 'true';
        }

        my $generate
         = ($max eq 'unbounded' || $max > 1)
         ? ( $args->{check_occurs}
           ? 'element_repeated'
           : 'element_array'
           )
         : ($args->{check_occurs} && $min==1)
         ? ( $nillable
           ? 'element_nillable'
           : 'element_obligatory'
           )
         : 'element_optional';

        push @do, $childname => 
           $args->{run}{$generate}
                ->("$path/$childname", $ns, $childname, $do, $args, $min, $max);
    }

    @do;
}

sub _attribute($$$)
{   my ($path, $node, $args) = @_;

    my $name = $node->getAttribute('name')
       or croak "ERROR: attribute $path without name";

    $path   .= "/at($name)";
    my $tag  = $args->{run}{translate_tag}->($node, $name, $args);

    my $do;
    if(my $type = $node->getAttribute('type'))
    {   my $typename = _rel2abs($node, $type);
        $do = _final_type($path, $typename, $args);
    }
    else
    {   die "attribute without type in $path\n";
    }

    my $use     = $node->getAttribute('use') || 'optional';
    my $generate
     = $use eq 'required' ? 'attribute_required'
     : $use eq 'optional' ? 'attribute_optional'
     : die "attribute should be required or optional (not $use) in $path.\n";

    $name => $args->{run}{$generate}->($path, $tag, $do, $args);
}

sub _group_particle($$$)
{   my ($path, $node, $args) = @_;

    my $ref = $node->getAttribute('ref')
       or croak "ERROR: group $path without ref";

    $path     .= "/gr";
    my $typename = _rel2abs($node, $ref);
#warn $typename;

    my $dest   = _ref_type($path, $typename, 'group', $args);
    defined $dest ? $dest->childNodes : ();
}

sub _attribute_group($$$);
sub _attribute_group($$$)
{   my ($path, $node, $args) = @_;

    my $ref = $node->getAttribute('ref')
       or croak "ERROR: attributeGroup $path without ref";

    $path     .= "/ag";
    my $typename = _rel2abs($node, $ref);
#warn $typename;

    my @res;
    my $dest   = _ref_type($path, $typename, 'attributeGroup', $args);
    defined $dest or return ();

    foreach my $child ($dest->childNodes)
    {   next unless $child->isa('XML::LibXML::Element');
        my $local = $child->localname;
        if($local eq 'attribute')
        {   push @res, _attribute($path, $child, $args) }
        elsif($local eq 'attributeGroup')
        {   push @res, _attribute_group($path, $child, $args) }
    }

    @res;
}

sub _complexType($$$)
{   my ($path, $node, $args) = @_;
    my @elems = _complex_elems($path, $node, $args);
    @elems ? $args->{run}{complexType}->($path, $args, @elems) : ();
}

sub _complex_elems($$$)
{   my ($path, $node, $args) = @_;

    my @childs = $node->localName eq 'complexType' ? $node->childNodes : $node;
    my @elems;

    while(my $child = shift @childs)
    {   next unless $child->isa('XML::LibXML::Element');
        my $name = $child->localName;

        if($name eq 'simpleContent')
        {   # incorrect
            unshift @childs, $child->childNodes;
            next;
        }
        if($name eq 'complexContent')
        {   push @elems, _complexContent($path, $child, $args) }
        elsif($name eq 'attribute')
        {   push @elems, _attribute($path, $child, $args) }
        elsif($name eq 'attributeGroup')
        {   push @elems, _attribute_group($path, $child, $args) }
        else
        {   push @elems, _particles($path, $child, $args) }
    }

    @elems;
}

sub _complexContent($$$)
{   my ($path, $node, $args) = @_;

    my @childs = $node->childNodes;
    my @elems;

    while(my $child = shift @childs)
    {   next unless $child->isa('XML::LibXML::Element');
        my $name = $child->localName;
    
        if(   $name eq 'sequence' || $name eq 'choice' || $name eq 'all'
           || $name eq 'element'  || $name eq 'group')
        {   push @elems, _particles($path, $child, $args);
        }
        elsif($name eq 'extension')
        {   push @elems, _complex_extension($path, $child, $args);
        }
        elsif($name eq 'restriction')
        {   # nice for validating, but base can be ignored
            push @elems, map {_particles($path, $_, $args)}
               grep {$_->isa('XML::LibXML::Element')} $child->childNodes;
        }
        else
        {   warn "WARN: unrecognized complexContent element '$name' in $path\n";
        }
    }

    @elems;
}

sub _complex_extension($$$)
{   my ($path, $node, $args) = @_;

    my $base = $node->getAttribute('base') || 'anyType';
    my @elems;

    if($base ne 'anyType')
    {   my $typename = _rel2abs($node, $base);
        my $typedef  = $args->{types}{$typename}
            or die "ERROR: cannot base on unknown $base, at $path";

        $typedef->{type} eq 'complexType'
            or die "ERROR: base $base not complexType, at $path";

        push @elems, _complex_elems("$path#base", $typedef->{node}, $args);
    }

    push @elems, map {_particles($path, $_, $args)}
        grep {$_->isa('XML::LibXML::Element')} $node->childNodes;

    @elems;
}

sub _particles($$$)
{   my ($path, $node, $args) = @_;

    my $name = $node->localName;

      $name eq 'sequence' || $name eq 'element' || $name eq 'group'
    ? _particle($path, $node, 1, 1, 0, 'unbounded', $args)
    : $name eq 'choice'
    ? _choice($path, $node, $args)
    : $name eq 'all'
    ? _particle($path, $node, 1, 1, 1, 'unbounded', $args)
    : die "ERROR: unrecognized particle '$name' in $path\n";
}

#
# Helper routines
#

# print _rel2abs($node, 'ns#type')     ->  'ns#type'
# print _rel2abs($node, 'prefix:type') ->  'ns(prefix)#type'

sub _rel2abs($$)
{   return $_[1] if index($_[1], '#') >= 0;

    my ($url, $local)
     = $_[1] =~ m/^(.+?)\:(.*)/
     ? ($_[0]->lookupNamespaceURI($1), $2)
     : ($_[0]->namespaceURI, $_[1]);

     defined $url
         or croak "ERROR: cannot understand type '$_[1]'";

     "$url#$local";
}

1;
