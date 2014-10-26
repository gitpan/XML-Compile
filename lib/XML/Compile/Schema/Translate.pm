
use warnings;
use strict;

package XML::Compile::Schema::Translate;
use base 'Exporter';

our @EXPORT = 'compile_tree';

use Carp;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInFacets;
use XML::Compile::Schema::BuiltInTypes   qw/%builtin_types/;

sub _rel2abs($$);

=chapter NAME

XML::Compile::Schema::Translate - create an XML data parser

=chapter SYNOPSIS

 # for internal use only!

=chapter DESCRIPTION

This module converts a schema type definition into a code
reference which can be used to interpret a schema.  The sole public
function in this package is M<compile_tree()>, and is called by
M<XML::Compile::Schema::compile()>, which does a lot of set-ups.
Please do not try to use this package directly!

The code in this package interprets schemas; it understands, for
instance, how complexType definitions work.  Then, when the
schema syntax is decoded, it will knot the pieces together into
one CODE reference which can be used in the main user program.

=section Unsupported features

This implementation is work in progress, but most structures in
W3C schema's are implemented.  A few nuts are still to crack:
 schema schemaLocation
 schema noNamespaceSchemaLocation
 schema version
 element mixed
 facets on dates
 limited understanding of patterns
 import
 include
 anyAttribute
 substitutionGroup, final, and abstract
 unique, keyref, selector, field, include, notation
 inherited attributes for simpleContent extend
 simpleContent restrict
 facets on list objects

Of course, these are all fixed in next release ;-)

=section Rules of translation

The following rules are used during translation, applicable to
both the reader as the writer:

=over 4

=item Encoding

this module uses XML::LibXML which does the character encoding for
us: you do not have to escape characters like E<lt> yourself.

=item Nesting

Elements can be complex, and themselve contain elements which
are complex.  In the Perl representation of the data, this will
be shown as nested hashes with the same structure as the XML.

=item Arrays

Any element which has a maxOccurs larger than 1 will be returned
as an array (or undef).  This will avoid the situation where the
user code only handles a single element instance where the schema
defines that multiple values can be returned.  The same is true
for list types.

=item Schema validation

Be warned that the schema itself is NOT VALIDATED; you can easily
construct schema's which do work with this module, but are not
valid according to W3C.  Only in some cases, the translater will
refuse to accept mistakes: mainly because it cannot produce valid
code.

=item Value checking

The code will do its best to produce a correct translation. For
instance, an accidental C<1.9999> will be converted into C<2>
when the schema says that the field is an C<int>.

=item Wildcards

The C<any> and C<anyAttribute> elements frustrate our attempt for
simplification.  Where we normally know which name-space we are
dealing with, these wildcard elements can use any name-space.  Therefore,
in the HASH, these elements will use keys like C<{url}name>, in stead
of simply the name... both in the reader and the writer.

=back

=section Performance optimization

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

=back

=section Qualified XML

The produced XML may not use the name-spaces as defined by the schema's,
just to simplify the input and output.  The structural definition of
the schema's is still in-tact, but name-space collission may appear.

Per schema, it can be specified whether the elements and attributes
defined in-there need to be used qualified (with prefix) or not.
This can cause horrible output when within an unqualified schema
elements are used from an other schema which is qualified.

The suggested solution in articles about the subject is to provide
people with both a schema which is qualified as one which is not.
Perl is known to be blunt in its approach: we simply define a flag
which can force one of both on all schema's together, using
C<elements_qualified> and C<attributes_qualified>.  May people and
applications do not understand name-spaces sufficiently, and these
options may make your day!

=section Name-spaces

The translator does respect name-spaces, but not all senders and
receivers of XML are name-space capable.  Therefore, you have some
options to interfere.

=over 4

=item output_namespaces HASH

The translator will create XML elements (WRITER) which use name-spaces,
based on its own name-space/prefix mapping administration.  This is
needed because the XML tree is formed bottom-up, where XML::LibXML
can only handle this top-down.

When your pass your own HASH as argument, you can explicitly specify
the prefixes you like to be used for which name-space.  Found name-spaces
will be added to the hash, as well the use count.  When a new name-space
URI is discovered, an attempt is made to use the prefix as found in the
schema. Prefix collisions are actively avoided: when two URIs want the
same prefix, a sequence number is added to one of them which makes it
unique.

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

=back

=chapter FUNCTIONS

=c_method compile_tree TYPENAME, OPTIONS
Do not call this function yourself, but use
M<XML::Compile::Schema::compile()> (or wrappers around that).

This function returns a CODE reference, which can translate
between Perl datastructures and XML, based on a schema.  Before
this method is called is the schema already translated into
a table of types.

=required nss M<XML::Compile::Schema::NameSpaces>

=cut

sub compile_tree($@)
{   my ($typename, %args) = @_;

    ref $typename
       and croak 'ERROR: expecting a type name as point to start';
 
    my $processor = _final_type($args{path}, \%args, $typename);
    defined $processor or return ();

    my $produce   = $args{run}{wrapper}->($processor);

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
    
sub _final_type($$$)
{   my ($path, $args, $typename) = @_;

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
         ->($path, $args, $typename, $code);
    }

    #
    # Not a built-in type: a bit more work to do.
    #

    my $nss    = $args->{nss};
    my $top    = $nss->findID($typename)
              || $nss->findElement($typename)
              || $nss->findType($typename)
       or croak "ERROR: cannot find $typename for $path\n";

    my $node   = $top->{node};

    my $elems_qual
     = exists $args->{elements_qualified} ? $args->{elements_qualified}
     : $top->{efd} eq 'qualified';

    my $attrs_qual
     = exists $args->{attributes_qualified} ? $args->{attributes_qualified}
     : $top->{afd} eq 'qualified';

#warn "TYPE: $typename\n";
    my $label  = $top->{name};
    my $name   = $node->localname;

    local $args->{tns}        = $top->{ns};
    local $args->{elems_qual} = $elems_qual;
    local $args->{attrs_qual} = $attrs_qual;

    if($name eq 'simpleType')
    {   return _simpleType($path, $args, $node) }
    elsif($name eq 'complexType')
    {   return _complexType($path, $args, $node) }
    elsif($name eq 'element')
    {   return _element($path, $args, $node) }

    if($name eq 'group' || $name eq 'attributeGroup')
    {   croak "ERROR: $name is not a final type, only for reference\n" }
    else
    {   croak "ERROR: $name is not understood as final type\n" }
}

sub _simple($$$)
{   my ($path, $args, $typename) = @_;

    #
    # Is a built-in type? Those are all simpleTypes.
    # Special handlers
    #

confess if ref $typename;
    my $code = XML::Compile::Schema::Specs->builtInType
       ($typename, sloppy_integers => $args->{sloppy_integers});

    if($code)
    {
#warn "TYPE BASIC: $typename\n";
       return $args->{run}
         ->{$args->{check_values} ? 'builtin_checked' : 'builtin_unchecked'}
         ->($path, $args, $typename, $code);
    }

    #
    # Not a built-in type: a bit more work to do.
    #

    my $nss    = $args->{nss};
    my $top    = $nss->findType($typename)
       or croak "ERROR: cannot find $typename for $path\n";

    my $node   = $top->{node};
    my $name   = $node->localname;
    $name eq 'simpleType'
       or croak "ERROR: expecting simpleType for $typename in $path\n";

    my $elems_qual
     = exists $args->{elements_qualified} ? $args->{elements_qualified}
     : $top->{efd} eq 'qualified';

    my $attrs_qual
     = exists $args->{attributes_qualified} ? $args->{attributes_qualified}
     : $top->{afd} eq 'qualified';

#warn "TYPE: $typename\n";
    my $label  = $top->{name};

    local $args->{tns}        = $top->{ns};
    local $args->{elems_qual} = $elems_qual;
    local $args->{attrs_qual} = $attrs_qual;

    _simpleType($path, $args, $node);
}

sub _ref_type($$$$)
{   my ($path, $args, $typename, $name) = @_;

    my $nss    = $args->{nss};
    my $top    = $nss->findElement($typename)
       or croak "ERROR: cannot find ref-type $typename for $path\n";

    my $node   = $top->{node};
    my $local  = $node->localname;
    if($local ne $name)
    {   croak "ERROR: $path $typename should refer to a $name, not a $local";
    }
  
    $node;
}

sub _simpleType($$$)
{   my ($path, $args, $node) = @_;
#warn "simpleType $path\n";
    my $ns   = $node->namespaceURI;

    my @childs = _childs($node);
    @childs==1
       or croak "ERROR: simpleType must have only one child in $path";

    my $child = shift @childs;
    my $local = $child->localName;

    if($local eq 'restriction')
    {   my ($st) = _simple_restriction($path, $args, $child, 0);
        return $st;
    }

      $local eq 'list'  ? _simple_list($path, $args, $child)
    : $local eq 'union' ? _simple_union($path, $args, $child)
    : croak "ERROR: simpleType contains $local, must be restriction, list, or union in $path\n";
}

sub _simple_list($$$)
{   my ($path, $args, $node) = @_;

    my $ns   = $node->namespaceURI;
    my $per_item;
    if(my $type = $node->getAttribute('itemType'))
    {   my $typename = _rel2abs($node, $type);
        $per_item    = _simple($path, $args, $typename);
    }
    else
    {   my @childs = _childs($node);
        @childs==1
           or croak "ERROR: expected one simpleType child or itemType attribute in $path";

        my $child = shift @childs;
        $per_item    = _simpleType($path, $args, $child);
    }

    $args->{run}{list}->($path, $args, $per_item);
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
            push @types, _simple($path, $args, $typename);
        }
    }

    foreach my $child (_childs($node))
    {   my $local = $child->localName;

        $local eq 'simpleType'
           or croak "ERROR: only simpleType's within union in $path\n";

        push @types, _simpleType($path, $args, $child);
    }

    $args->{run}{union}->($path, $args, $err, @types);
}

sub _simple_restriction($$$;$)
{   my ($path, $args, $node, $has_attr) = @_;
    my $ns = $node->namespaceURI;
    my $st;

    if(my $base = $node->getAttribute('base'))
    {   my $typename = _rel2abs($node, $base);
        $st = _simple($path, $args, $typename);
    }
    elsif($base = $node->getChildrenByTagNameNS($ns,'simpleType'))
    {   $st = _simpleType("$path/st", $args, $base);
    }
    else
    {   die "ERROR: restriction $path requires either base or simpleType\n";
    }

    return $st if $args->{ignore_facets};

    # Collect the facets

    my (%facets, @attrs);
  FACET:
    foreach my $child (_childs($node))
    {   my $facet = $child->localName;
        next if $facet eq 'simpleType';

        if($facet eq 'attribute' || $facet eq 'anyAttribute')
        {   # simpleType/extension
            $has_attr
               or croak "ERROR: not attribute for simpleType $path";

            # complexType/simpleContent/extension
            push @attrs, $child;
            next FACET;
        }

        my $value = $child->getAttribute('value');
        defined $value or die "ERROR: no value for facet $facet in $path\n";

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
        push @rules, builtin_facet($path, $args, $facet, $value)
           if defined $value;
    }

    # <list> types need to split here... which will require some
    # new structural wrappers.

    foreach my $facet (keys %facets)
    {   push @rules, builtin_facet($path, $args, $facet, $facets{$facet});
    }

    my $check_facets
     = @rules==0 ? $st
     : @rules==1 ? _call_facet($st, $rules[0])
     :             _call_facets($st, @rules);

    ($check_facets, @attrs);
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
        return _final_type($path, $args, $typename);
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
        $do = _final_type($path, $args, $typename);
    }
    elsif(!@childs)
    {   my $typename = _rel2abs($node, 'anyType');
        $do = _final_type($path, $args, $typename);
    }
    else
    {   @childs > 1
           and die "ERROR: expected is only one child in $path\n";
 
        # nameless types
        my $child = $childs[0];
        my $local = $child->localname;
        $do = $local eq 'simpleType'  ? _simpleType($path, $args, $child)
            : $local eq 'complexType' ? _complexType($path, $args, $child)
            : $local =~ m/^(sequence|choice|all|group)$/
            ?                           _complexType($path, $args, $child)
            : die "ERROR: unexpected element child $local at $path\n";
    }

    $args->{run}{create_element}->($path, $args, $tag, $do);
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
    if(my $type = $node->getAttribute('type'))
    {   my $typename = _rel2abs($node, $type);
        $do = _simple($path, $args, $typename);
    }
    else
    {   die "attribute without type in $path\n";
    }

    my $use     = $node->getAttribute('use') || 'optional';
    my $default = $node->getAttributeNode('default');
    my $fixed   = $node->getAttributeNode('fixed');

    my $generate
     = defined $default    ? 'attribute_default'
     : defined $fixed      ? 'attribute_fixed'
     : $use eq 'required'  ? 'attribute_required'
     : $use eq 'optional'  ? 'attribute_optional'
     : $use eq 'prohibited' ? 'attribute_prohibited'
     : croak "ERROR: attribute use is required, optional or prohibited (not '$use') in $path.\n";

    my $value = defined $default ? $default : $fixed;
    $name => $args->{run}{$generate}->($path, $args, $tag, $do, $value);
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

        return $args->{run}{simpleContent}
           ->($path, $args, $node, _simpleContent($path, $args, $first));
    }

    my ($elems, $attrs);
    if($local eq 'complexContent')
    {   @childs && croak "ERROR: complexContent must be alone in complexType in $path";
        ($elems, $attrs) = _complexContent($path, $args, $first);
    }
    else
    {   ($elems, $attrs) = _complex_body($path, $args, $node);
    }

    @$elems || @$attrs or return ();
    $args->{run}{complexContent}->($path, $args, $node, @$elems, @$attrs);
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

    (\@elems, \@attrs);
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

    my @childs = _childs($node);

    my $base = $node->getAttribute('base') || 'anyType';
    my $typename = _rel2abs($node, $base);

    ( _ => _simple($path, $args, $typename)
    , _attributes_of("$path#base", $args, $typename)
    , _attribute_list($path, $args, @childs)
    );
}

sub _attributes_of($$$)
{   my ($path, $args, $typename) = @_;

    # no public schema-schema datatypes have attributes
    return ()
        if in_schema_schema($typename);

    my $def  = $args->{nss}->findType($typename)
        or croak "ERROR: cannot base on unknown $typename at $path";

    my $node  = $def->{node};
    my $local = $node->localName;
    return () if $local eq 'simpleType';

    $local eq 'complexType'
        or croak "ERROR: must extend simpleType or complexType";

    my @childs = _childs($node);
    @childs
        or croak "ERROR: did not find any childs for $typename";

  CHILD:
    my $attrs;
    # hum, at least 8 different cases.  Rewrite of type collection
    # required.
    foreach my $child (@childs)
    {   die "ERROR: collecting extension attrs of simpleContent not implemented yet"
            if $child->localName eq 'simpleContent';

        if($child->localname eq 'complexContent')
        {   foreach my $c (_childs($child))
            {   $c->localName =~ m/^extension|restriction$/
                    and croak "ERROR: collecting nested attrs of complexContent not implemented yet";
            }
            (my $elems, $attrs) = _complex_body($path, $args, $node);
            last CHILD;
        }
    }

    (@$attrs);
}

sub _simpleContent_res($$$)
{   my ($path, $args, $node) = @_;
    my ($st, @attrs) = _simple_restriction($path, $args, $node, 1);
    (_ => $st, _attribute_list($path, $args, @attrs));
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
    my (@elems, @attrs);

    if($base ne 'anyType')
    {   my $typename = _rel2abs($node, $base);
        my $typedef  = $args->{nss}->findType($typename)
            or die "ERROR: cannot base on unknown $base, at $path";

        $typedef->{type} eq 'complexType'
            or die "ERROR: base $base not complexType, at $path";

        my ($base_elems, $base_attrs)
            = _complex_body($path, $args, $typedef->{node});
        push @elems, @$base_elems;
        push @attrs, @$base_attrs;
    }

    my ($my_elems, $my_attrs) = _complex_body($path, $args, $node);
    push @elems, @$my_elems;
    push @attrs, @$my_attrs;

    (\@elems, \@attrs);
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
