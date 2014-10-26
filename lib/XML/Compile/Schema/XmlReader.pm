# Copyrights 2006-2007 by Mark Overmeer.
# For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 0.99.
package XML::Compile::Schema::XmlReader;
use vars '$VERSION';
$VERSION = '0.16';

use strict;
use warnings;
no warnings 'once';

use List::Util  qw/first/;
use Carp        qw/croak/;


# Each action implementation returns a code reference, which will be
# used to do the run-time work.  The principle of closures is used to
# keep the important information.  Be sure that you understand closures
# before you attempt to change anything.
#
# The returned reader subroutines will always be called
#       $reader->($xml_node) 

sub tag_unqualified
{   my $name = $_[3];
    $name =~ s/.*?\://;   # strip prefix, that's all
    $name;
}
*tag_qualified = \&tag_unqualified;

sub wrapper
{   my $processor = shift;
    sub { my $xml = XML::Compile->dataToXML($_[0]);
          defined $xml or return ();
          $xml = $xml->documentElement if $xml->isa('XML::LibXML::Document');
          $processor->($xml);
        };
}

sub wrapper_ns        # no namespaces in the HASH
{   my ($path, $args, $processor, $index) = @_;
    $processor;
}

#
## Element
#

sub element_repeated
{   my ($path, $args, $ns, $childname, $do, $min, $max) = @_;
    my $err  = $args->{err};
    sub { my @nodes = $_[0]->getChildrenByLocalName($childname);
          $err->($path,scalar @nodes,"too few values (need $min)")
             if @nodes < $min;
          $err->($path,scalar @nodes,"too many values (max $max)")
             if $max ne 'unbounded' && @nodes > $max;
          my @r = map { $do->($_) } @nodes;
          @r ? ($childname => \@r) : (); 
        };
}

sub element_array
{   my ($path, $args, $ns, $childname, $do) = @_;
    sub { my @r = map { $do->($_) } $_[0]->getChildrenByLocalName($childname);
          @r ? ($childname => \@r) : ();
        };
}

sub element_obligatory
{   my ($path, $args, $ns, $childname, $do) = @_;
    my $err  = $args->{err};
    sub {
# This should work with namespaces (but doesn't yet)
# because the wrong namespace is passed in $ns
# my @nodes = $_[0]->getChildrenByTagNameNS($ns,$childname);
          my @nodes = $_[0]->getChildrenByLocalName($childname);
          my $node
           = (@nodes==0 || !defined $nodes[0])
           ? $err->($path, undef, "one value required")
           : shift @nodes;
          $node = $err->($path, 'found '.@nodes, "only one value expected")
             if @nodes;
          defined $node ? ($childname => $do->($node)) : ();
        };
}

sub element_default
{   my ($path, $args, $ns, $childname, $do, $min, $max, $default) = @_;
    my $err  = $args->{err};
    my $def  = $do->($default);

    sub { my @nodes = $_[0]->getChildrenByLocalName($childname);
          my $node = shift @nodes;
          $node = $err->($path, 'found '.@nodes, "only one value expected")
             if @nodes;
          ( $childname => (defined $node ? $do->($node) : $def) );
        };
}

sub element_fixed
{   my ($path, $args, $ns, $childname, $do, $min, $max, $fixed) = @_;
    my $err = $args->{err};
    my $def  = $do->($fixed);

    sub { my @nodes = $_[0]->getChildrenByLocalName($childname);
          my $node = shift @nodes;
          $node = $err->($path, 'found '.@nodes, "only one value expected")
              if @nodes;
          my $value = defined $node ? $do->($node) : undef;
          $err->($path, $value,"value fixed to '".$fixed->value."'")
              if !defined $value || $value ne $def;
          ($childname => $def);
        };
}

sub element_fixed_optional
{   my ($path, $args, $ns, $childname, $do, $min, $max, $fixed) = @_;
    my $err = $args->{err};
    my $def  = $do->($fixed);

    sub { my @nodes = $_[0]->getChildrenByLocalName($childname);
          my $node  = shift @nodes or return ();
          $node = $err->($path, 'found '.@nodes, "only one value expected")
              if @nodes;
          my $value = defined $node ? $do->($node) : undef;
          $err->($path, $value,"value fixed to '".$fixed->value."'")
              if !defined $value || $value ne $def;
          ($childname => $def);
        };
}

sub element_nillable
{   my ($path, $args, $ns, $childname, $do) = @_;
    my $err  = $args->{err};
    sub { my @nodes = $_[0]->getChildrenByLocalName($childname);
          my $node
           = (@nodes==0 || !defined $nodes[0])
           ? $err->($path, undef, "one value required")
           : shift @nodes;
          $err->($path, 'found '.@nodes, "only one value expected")
             if @nodes;
          my $nil = $node->getAttribute('nil') || 'false';
          $childname => ($nil eq 'true' ? undef : $do->($node));
        };
}

sub element_optional
{   my ($path, $args, $ns, $childname, $do) = @_;
    my $err  = $args->{err};
    sub { my @nodes = $_[0]->getChildrenByLocalName($childname)
             or return ();
          $err->($path, scalar @nodes, "only one value expected")
             if @nodes > 1;
          my $val = $do->($nodes[0]);
          defined $val ? ($childname => $val) : ();
        };
}

#
# complexType/ComplexContent
#

sub create_complex_element
{   my ($path, $args, $tag, $childs, $any_elem, $any_attr) = @_;

    my @childs = @$childs;
    my @do;
    while(@childs) {shift @childs; push @do, shift @childs}
    push @do, @$any_elem, @$any_attr;

    sub { my @pairs = map {$_->(@_)} @do;
          @pairs ? {@pairs} : ();
        };
}

#
# complexType/simpleContent
#

sub create_tagged_element
{   my ($path, $args, $tag, $st, $attrs, $attrs_any) = @_;
    my @attrs = @$attrs;
    my @do;
    while(@attrs) {shift @attrs; push @do, shift @attrs}
    push @do, @$attrs_any;

    sub { my @a = @do;
          my $simple = $st->(@_);
          my @pairs = map {$_->(@_)} @do;
          defined $simple or @pairs or return ();
          defined $simple or $simple = 'undef';
          {_ => $simple, @pairs};
        };
}

#
# simpleType
#

sub create_simple_element
{   my ($path, $args, $tag, $st) = @_;
    sub { my $value = $st->(@_);
          defined $value ? $value : undef;
        };
}

sub builtin_checked
{   my ($path, $args, $node, $type, $def) = @_;
    my $check = $def->{check};
    defined $check
       or return builtin_unchecked(@_); 
    my $parse = $def->{parse};
    my $err   = $args->{err};

      defined $parse
    ? sub { my $value = ref $_[0] ? $_[0]->textContent : $_[0];
            defined $value or return undef;
              $check->($value)
            ? $parse->($value, $_[0])
            : $err->($path, $value, "illegal value for $type");
          }
    : sub { my $value = ref $_[0] ? $_[0]->textContent : $_[0];
            defined $value or return undef;
              $check->($value)
            ? $value
            : $err->($path, $value, "illegal value for $type");
          };
}

sub builtin_unchecked
{   my $parse = $_[4]->{parse};

      defined $parse
    ? sub { my $v = $_[0]->textContent; defined $v ? $parse->($v,$_[0]) :undef}
    : sub { $_[0]->textContent }
}

# simpleType

sub list
{   my ($path, $args, $st) = @_;
    sub { defined $_[0] or return undef;
          my $v = $_[0]->textContent;
          my @v = grep {defined} map {$st->($_) } split(" ",$v);
          \@v;
        };
}

sub facets_list
{   my ($path, $args, $st, $early, $late) = @_;
    sub { defined $_[0] or return undef;
          my $v = $st->(@_);
          for(@$early) { defined $v or return (); $v = $_->($v) }
          my @v = defined $v ? split(" ",$v) : ();
          my @r;
      EL: for my $e (@v)
          {   for(@$late) { defined $e or next EL; $e = $_->($e) }
              push @r, $e;
          }
          @r ? \@r : ();
        };
}

sub facets
{   my ($path, $args, $st, @do) = @_;
    sub { defined $_[0] or return undef;
          my $v = $st->(@_);
          for(@do) { defined $v or return (); $v = $_->($v) }
          $v;
        };
}

sub union
{   my ($path, $args, $err, @types) = @_;
    sub { defined $_[0] or return undef;
          for(@types) {my $v = $_->($_[0]); defined $v and return $v }
          my $text = $_[0]->textContent;
          substr $text, 10, -1, '...' if length($text) > 13;
          $err->($path, $text, "no match in union");
        };
}

# Attributes

sub attribute_required
{   my ($path, $args, $ns, $tag, $do) = @_;
    my $err  = $args->{err};
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag)
             || $err->($path, undef, "attribute $tag required");
          defined $node or return ();
          my $value = $do->($node);
          defined $value ? ($tag => $value) : ();
        };
}

sub attribute_prohibited
{   my ($path, $args, $ns, $tag, $do) = @_;
    my $err  = $args->{err};
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          defined $node or return ();
          $err->($path, $node->textContent, "attribute $tag prohibited");
          ();
        };
}

sub attribute_optional
{   my ($path, $args, $ns, $tag, $do) = @_;
    my $err  = $args->{err};
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag)
             or return ();
          my $val = $do->($node);
          defined $val ? ($tag => $val) : ();
        };
}

sub attribute_default
{   my ($path, $args, $ns, $tag, $do, $default) = @_;
    my $err  = $args->{err};
    my $def  = $do->($default);

    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          ($tag => defined $node ? $do->($node) : $def);
        };
}

sub attribute_fixed
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    my $err = $args->{err};
    my $def  = $do->($fixed);

    sub { my $node  = $_[0]->getAttributeNodeNS($ns, $tag);
          my $value = defined $node ? $do->($node) : undef;
          $err->($path, $value, "attr value fixed to '".$fixed->value."'")
              if !defined $value || $value ne $def;
          ($tag => $def);
        };
}

sub attribute_fixed_optional
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    my $err = $args->{err};
    my $def  = $do->($fixed);

    sub { my $node  = $_[0]->getAttributeNodeNS($ns, $tag) or return ();
          my $value = $do->($node);
          $err->($path, $value, "attr value fixed to '".$fixed->value."'")
              if !defined $value || $value ne $def;
          ($tag => $def);
        };
}


# SubstitutionGroups

sub element_substgroup
{   my ($path, $args, $name, $defs) = @_;
    my $err  = $args->{err};
    sub { foreach my $def (@$defs)
          {   my $node = $_[0]->getChildrenByLocalName($def->[1])
                 or next;
              return $def->[2]->(@_);
          }
          $err->($path, $name, "none of the substitution alternatives found.");
        };
}

# anyAttribute

sub anyAttribute
{   my ($path, $args, $handler, $yes, $no, $process) = @_;
    return () unless defined $handler;

    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    # Takes all, before filtering
    my $all =
    sub { my @result;
          foreach my $attr ($_[0]->attributes)
          {   $attr->isa('XML::LibXML::Attr') or next;
              my $ns = $attr->namespaceURI || $_[0]->namespaceURI;
              next if keys %yes && !$yes{$ns};
              next if keys %no  &&   $no{$ns};
              my $local = $attr->localName;
              push @result, "{$ns}$local" => $attr;
          }
          @result;
        };

    # Create filter if requested
    $handler eq 'TAKE_ALL' ? $all
    : sub { my @attrs = $all->(@_);
            my @result;
            while(@attrs)
            {   my ($type, $data) = (shift @attrs, shift @attrs);
                my ($label, $out) = $handler->($type, $data, $path, $args);
                push @result, $label, $out if defined $label;
            }
            @result;
          };
}

# anyElement

sub anyElement
{   my ($path, $args, $handler, $yes, $no, $process, $min, $max) = @_;
    defined $handler or return sub { () };
    $handler = sub { @_ } if $handler eq 'TAKE_ALL';

    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    # Takes all, before filtering
    my $all =
    sub { my %result;
          my @elems = grep {$_->isa('XML::LibXML::Element')} $_[0]->childNodes;
          foreach my $elem (@elems)
          {   my $ns = $elem->namespaceURI || $_[0]->namespaceURI;
              next if keys %yes && !$yes{$ns};
              next if keys %no  &&   $no{$ns};
              my ($k, $v) = $handler->("{$ns}".$elem->localName => $elem);
              push @{$result{$k}}, $v;
          }
          %result;
        };
}

# any kind of hook

sub create_hook($$$$$)
{   my ($path, $args, $r, $before, $replace, $after) = @_;
    return $r unless $before || $replace || $after;

    return sub {()} if $replace && grep {$_ eq 'SKIP'} @$replace;

    my @replace = $replace ? map {_decode_replace($path,$_)} @$replace : ();
    my @before  = $before  ? map {_decode_before($path,$_) } @$before  : ();
    my @after   = $after   ? map {_decode_after($path,$_)  } @$after   : ();

    sub
     { my $xml = shift;
       foreach (@before)
       {   $xml = $_->($xml, $path);
           defined $xml or return ();
       }
       my @h = @replace ? map {$_->($xml, $args, $path)} @replace : $r->($xml);
       @h or return ();
       my $h = @h > 1 ? {@h} : $h[0];  # detect simpleType
       foreach (@after)
       {   $h = $_->($xml, $h, $path);
           defined $h or return ();
       }
       $h;
     }
}

sub _decode_before($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub {print "$_[1]\n"; $_[0] }
    : croak "ERROR: labeled hook '$call' undefined.";
}

sub _decode_replace($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

    croak "ERROR: labeled hook '$call' undefined.";
}

sub _decode_after($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub {print "$_[2]\n"; $_[1] }
    : $call eq 'XML_NODE'  ?
      sub { my $values = $_[1];
            $values = { _ => $values } if ref $values ne 'HASH';
            $values->{_XML_NODE} = $_[0];
            $values;
          }
    : $call eq 'ELEMENT_ORDER' ?
      sub { my ($xml, $values) = @_;
            $values = { _ => $values } if ref $values ne 'HASH';
            my @order = map {$_->nodeName}
                grep {$_->isa('XML::LibXML::Element')}
                   $xml->childNodes;
            $values->{_ELEMENT_ORDER} = \@order;
            $values;
          }
    : $call eq 'ATTRIBUTE_ORDER' ?
      sub { my ($xml, $values) = @_;
            $values = { _ => $values } if ref $values ne 'HASH';
            my @order = map {$_->nodeName} $xml->attributes;
            $values->{_ATTRIBUTE_ORDER} = \@order;
            $values;
          }
    : croak "ERROR: labeled hook '$call' undefined.";
}


1;

