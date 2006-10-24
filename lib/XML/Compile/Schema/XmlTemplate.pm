
package XML::Compile::Schema::XmlTemplate;
use vars '$VERSION';
$VERSION = '0.10';

use XML::Compile::Schema::XmlWriter;

use strict;
use warnings;
no warnings 'once';


BEGIN {
   no strict 'refs';
   *$_ = *{"XML::Compile::Schema::XmlWriter::$_"}
      for qw/tag_qualified tag_unqualified wrapper wrapper_ns/;
}

#
## Element
#

sub element_repeated
{   my ($path, $args, $ns, $childname, $do, $min, $max) = @_;
    my $err  = $args->{err};
    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("$childname $min <= # <= $max times")
          , $do->($doc)
          );
        };
}

sub element_array
{   my ($path, $args, $ns, $childname, $do) = @_;
    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("$childname in any number")
          , $do->($doc)
          );
        };
}

sub element_obligatory
{   my ($path, $args, $ns, $childname, $do) = @_;
    my $err  = $args->{err};
    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("$childname required")
          , $do->($doc)
          )
        };
}

sub element_fixed
{   my ($path, $args, $ns, $childname, $do, $min, $max, $fixed) = @_;
    my $err  = $args->{err};
    $fixed   = $fixed->value;

    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("$childname fixed to $fixed")
          , $do->($doc)
          );
        };
}

sub element_nillable
{   my ($path, $args, $ns, $childname, $do) = @_;
    my $err  = $args->{err};
    sub { my $doc = shift;
           ( XML::LibXML::Comment->new("$childname is nillable")
           , $do->($doc)
           );
        };
}

sub element_default
{   my ($path, $args, $ns, $childname, $do, $min, $max, $default) = @_;
    sub { my $doc = shift;
           ( XML::LibXML::Comment->new("childname defaults to $default")
           , $doc->($doc)
           );
        }
}

sub element_optional
{   my ($path, $args, $ns, $childname, $do) = @_;
    my $err  = $args->{err};
    sub { my $doc = shift;
           ( XML::LibXML::Comment->new("$childname is optional")
           , $do->($doc)
           );
        };
}

#
# complexType/ComplexContent
#

sub create_complex_element
{   my ($path, $args, $tag, @do) = @_;
    sub { my $doc = shift;
          my @elems = @do;
          my @childs;
          while(@elems)
          {   my $childname = shift @elems;
              push @childs, (shift @elems)->($doc);
          }
          my $node  = $doc->createElement($tag);
          $node->addChild
            ( ref $_ && $_->isa('XML::LibXML::Node') ? $_
            : $doc->createTextNode(defined $_ ? $_ : ''))
               for @childs;

          $node;
        };
}

#
# complexType/simpleContent
#

sub create_tagged_element
{   my ($path, $args, $tag, $st, $attrs) = @_;
    my @do  = @$attrs;
    sub { my $doc = shift;
          my $content = $st->($doc);
          my @childs  = $doc->createTextNode($content);

          my @attrs   = @do;
          while(@attrs)
          {   my $childname = shift @attrs;
              push @childs, (shift @attrs)->($doc);
          }
          my $node  = $doc->createElement($tag);
          $node->addChild
            ( ref $_ && $_->isa('XML::LibXML::Node') ? $_
            : $doc->createTextNode(defined $_ ? $_ : ''))
               for @childs;
          $node;
       };
}

#
# simpleType
#

sub create_simple_element
{   my ($path, $args, $tag, $st) = @_;
    sub { my $doc     = shift;
          my $node    = $doc->createElement($tag);
          my $example = $st->($doc);
          $example = $doc->createTextNode($example)
              unless ref $example && $example->isa('XML::LibXML::Node');
          $node->addChild($example);
          $node;
        };
}

sub builtin_checked
{   my ($path, $args, $type, $def) = @_;
    my $example = $def->{example};
    sub { $example };
}

sub builtin_unchecked(@) { &builtin_checked };

# simpleType

sub list
{   my ($path, $args, $st) = @_;
    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("a (blank separated) list of elements")
          , $st->($doc)
          );
        };
}

sub facets_list
{   my ($path, $args, $st, $early, $late) = @_;
    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("with some limits on the list")
          , $st->($doc)
          );
        };
}

sub facets
{   my ($path, $args, $st, @do) = @_;
    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("with some limits")
          , $st->($doc)
          );
        };
}

sub union
{   my ($path, $args, $err, @types) = @_;
    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("one of the following (union)")
          , map { $_->($doc) } @types
          );
        };
}

# Attributes

sub attribute_required
{   my ($path, $args, $ns, $tag, $do) = @_;

    sub { my $doc     = shift;
          my $example = $do->($doc);
          $doc->createAttributeNS($ns, $tag, $example);
        };
}

sub attribute_prohibited
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { () };
}

sub attribute_default
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { my $doc     = shift;
          my $example = $do->($doc);
          ( XML::LibXML::Comment->new("attribute $tag has default")
          , $doc->createAttributeNS($ns, $tag, $example)
          );
        };
}

sub attribute_optional
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { my $doc     = shift;
          my $example = $do->($doc);
          ( XML::LibXML::Comment->new("attribute $tag is optional")
          , $doc->createAttributeNS($ns, $tag, $example)
          );
        };
}

sub attribute_fixed
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    $fixed   = $fixed->value;

    sub { my $doc = shift;
          ( XML::LibXML::Comment->new("attribute $tag is fixed")
          , $doc->createAttributeNS($ns, $tag, $fixed)
          );
        };
}

1;

