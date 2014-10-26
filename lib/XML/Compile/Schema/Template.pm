# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.

package XML::Compile::Schema::Template;
use vars '$VERSION';
$VERSION = '0.5';

use XML::Compile::Schema::XmlWriter;

use strict;
use warnings;
no warnings 'once';

use Carp;

use XML::Compile::Util qw/odd_elements/;
use Log::Report 'xml-compile', syntax => 'SHORT';


BEGIN {
   no strict 'refs';
   *$_ = *{"XML::Compile::Schema::XmlWriter::$_"}
      for qw/tag_qualified tag_unqualified wrapper_ns/;
}

sub wrapper
{   my ($path, $args, $processor) = @_;
    sub { $processor->() };
}

sub _block($@)
{   my ($block, $path, $args, @pairs) = @_;
    sub { my @elems = map { $_->() } odd_elements @pairs;
          my @tags  = map { $_->{tag} } @elems;
          local $" = ', ';
          bless
           { tag    => $block
           , elems  => \@elems
           , struct => "$block of @tags"
           }, 'BLOCK';
        };
}

sub sequence { _block(sequence => @_) }
sub choice   { _block(choice   => @_) }
sub all      { _block(all      => @_) }

sub element_handler
{   my ($path, $args, $label, $min, $max, $req, $opt) = @_;
    sub { my $data = $opt->();
          my $occur
           = $max eq 'unbounded' && $min==0 ? 'occurs any number of times'
           : $max ne 'unbounded' && $max==1 && $min==0 ? 'is optional' 
           : $max ne 'unbounded' && $max==1 && $min==1 ? ''  # the usual case
           :                                  "occurs $min <= # <= $max times";
          $data->{occur}   = $occur if $occur;
          $data->{flatten} = $max ne 'unbounded' && $max==1;
          $data;
        };
}

sub block_handler
{   my ($path, $args, $label, $min, $max, $proc) = @_;
    element_handler($path, $args, $label, $min, $max, undef, $proc);
}

sub required
{   my ($path, $args, $label, $do) = @_;
    sub { $do->() };
}

sub element
{   my ($path, $args, $ns, $childname, $do) = @_;
    sub { $do->() };
}

sub element_fixed
{   my ($path, $args, $ns, $childname, $do, $fixed) = @_;
    $fixed   = $fixed->example;
    sub { (occur => "$childname fixed to example $fixed", $do->()) };
}

sub element_nillable
{   my ($path, $args, $ns, $childname, $do) = @_;
    sub { (occur => "$childname is nillable", $do->()) };
}

sub element_default
{   my ($path, $args, $ns, $childname, $do, $default) = @_;
    sub { (occur => "$childname defaults to example $default",  $do->()) };
}

#
# complexType/ComplexContent
#

sub complex_element
{   my ($path, $args, $tag, $elems, $attrs, $any_attr) = @_;
    my @parts = (odd_elements(@$elems, @$attrs), @$any_attr);

    sub { my (@attrs, @elems);
          foreach my $part (@parts)
          {   my $child = $part->();
              if($child->{attr}) { push @attrs, $child }
              else               { push @elems, $child }
          }

          +{ kind    => 'complex'
#          , struct  => "$tag is complex"  # too simple to mention
           , tag     => $tag
           , attrs   => \@attrs
           , elems   => \@elems
           };
        };
}

#
# complexType/simpleContent
#

sub tagged_element
{   my ($path, $args, $tag, $st, $attrs, $attrs_any) = @_;
    my @parts = (odd_elements(@$attrs), @$attrs_any);

    sub { my @attrs = map {$_->()} @parts;
          +{ kind    => 'tagged'
           , struct  => "$tag is simple value with attributes"
           , tag     => $tag
           , attrs   => \@attrs
           , example => ($st->() || '')
           };
       };
}

#
# simpleType
#

sub simple_element
{   my ($path, $args, $tag, $st) = @_;
    sub { +{ kind    => 'simple'
#          , struct  => "$tag is a single value"  # normal case
           , tag     => $tag
           , $st->()
           };
        };
}

sub builtin
{   my ($path, $args, $node, $type, $def, $check_values) = @_;
    my $example = $def->{example};
    sub { (type => $type, example => $example) };
}

# simpleType

sub list
{   my ($path, $args, $st) = @_;
    sub { (struct => "a (blank separated) list of elements", $st->()) };
}

sub facets_list
{   my ($path, $args, $st, $early, $late) = @_;
    sub { (facets => "with some limits on the list", $st->()) };
}

sub facets
{   my ($path, $args, $st, @do) = @_;
    sub { (facets => "with some limits", $st->()) };
}

sub union
{   my ($path, $args, @types) = @_;
    sub { +{ kind   => 'union'
           , struct => "one of the following (union)"
           , choice => [ map { $_->() } @types ]
           };
        };
}

# Attributes

sub attribute_required
{   my ($path, $args, $ns, $tag, $do) = @_;

    sub { +{ kind   => 'attr'
           , tag    => $tag
           , occurs => "attribute $tag is required"
           , $do->()
           };
        };
}

sub attribute_prohibited
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { () };
}

sub attribute_default
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { +{ kind   => 'attr'
           , tag    => $tag
           , occurs => "attribute $tag has default"
           , $do->()
           };
        };
}

sub attribute_optional
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { +{ kind   => 'attr'
           , tag    => $tag
           , occurs => "attribute $tag is optional"
           , $do->()
           };
        };
}

sub attribute_fixed
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    my $value = $fixed->value;

    sub { +{ kind    => 'attr'
           , tag     => $tag
           , occurs  => "attribute $tag is fixed"
           , example => $value
           };
        };
}

sub attribute_fixed_optional
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    my $value = $fixed->value;

    sub { +{ kind    => 'attr'
           , tag     => $tag
           , occurs  => "attribute $tag is fixed optional"
           , example => $value
           };
        };
}

sub hook($$$$$)
{   my ($path, $args, $r, $before, $produce, $after) = @_;
    return $r if $r;
    warning __x"hooks are not shown in templates";
    ();
}

# any

sub anyAttribute
{   my ($path, $args, $handler, $yes, $no, $process) = @_;
    my $occurs = @$yes ? "in @$yes" : @$no ? "not in @$no" : 'any type';

    sub { +{ kind    => 'attr'
           , struct  => "anyAttribute $occurs"
           };
        };
}

sub anyElement
{   my ($path, $args, $handler, $yes, $no, $process, $min, $max) = @_;
    my $occurs = @$yes ? "in @$yes" : @$no ? "not in @$no" : 'any type';
    sub { +{ kind    => 'element'
           , struct  => 'anyElement'
           };
        };
}

# SubstitutionGroups

sub substgroup
{   my ($path, $args, $type, %do) = @_;
    sub { +{ kind    => 'substitution group'
           , struct  => "one of the following, which extend $type"
           , map { $_->() } values %do
           }
        }
}

###
### toPerl
###

sub toPerl($%)
{   my ($class, $ast, %args) = @_;
    join "\n", perl_any($ast, \%args), '';
}

sub perl_any($$);
sub perl_any($$)
{   my ($ast, $args) = @_;

    my @lines;
    push @lines, "# $ast->{struct}"  if $ast->{struct} && $args->{show_struct};
    push @lines, "# is a $ast->{type}" if $ast->{type} && $args->{show_type};
    push @lines, "# $ast->{occur}"   if $ast->{occur}  && $args->{show_occur};
    push @lines, "# $ast->{facets}"  if $ast->{facets} && $args->{show_facets};

    my @childs;
    push @childs, @{$ast->{attrs}}   if $ast->{attrs};
    push @childs, @{$ast->{elems}}   if $ast->{elems};
    push @childs,   $ast->{body}     if $ast->{body};

    my @subs;
    foreach my $child (@childs)
    {   my @sub = perl_any($child, $args);
        @sub or next;

        # seperator blank between childs when comments
        unshift @sub, '' if @subs && $sub[0] =~ m/^\# /;

        # last line is code and gets comma
        $sub[-1] =~ s/\,?$/,/;

        # all lines get indented, unless flattening block
        push @subs, ref $ast eq 'BLOCK' ? @sub
          : map {length($_) ? "$args->{indent}$_" : ''} @sub;
    }

    if(ref $ast eq 'BLOCK')
    {   if($ast->{flatten}) { push @lines, @subs }
        elsif( @{$ast->{elems}} )
        {  $subs[0] =~ s/^ /{/;
           push @lines, $ast->{elems}[0]->tag. ' => ['. @subs . ']';
        }
    }
    elsif(@subs)
    {   $subs[0] =~ s/^ /{/;
        push @lines, "$ast->{tag} =>", @subs, '}';
    }
    else
    {   my $example = $ast->{example};
        $example = qq{"$example"} if $example !~ m/^\d+(?:\.\d+)?$/;
        push @lines, "$ast->{tag} => $example";
    }

    @lines;
}

###
### toXML
###

sub toXML($$%)
{   my ($class, $doc, $ast, %args) = @_;
    xml_any($doc, $ast, "\n$args{indent}", \%args);
}

sub xml_any($$$$);
sub xml_any($$$$)
{   my ($doc, $ast, $indent, $args) = @_;
    my @res;

    my @comment;
    push @comment, $ast->{struct} if $ast->{struct} && $args->{show_struct};
    push @comment, $ast->{occur}  if $ast->{occur}  && $args->{show_occur};
    push @comment, $ast->{facets} if $ast->{facets} && $args->{show_facets};

    my $nest_indent = $indent.$args->{indent};
    if(@comment)
    {   my $comment = join($nest_indent, '', @comment).$indent;
        push @res
          , $doc->createTextNode($indent)
          , $doc->createComment($comment);
    }

    my @childs;
    push @childs, @{$ast->{attrs}} if $ast->{attrs};
    push @childs, @{$ast->{elems}} if $ast->{elems};

    foreach my $child (@childs)
    {   #push @res,
        if(ref $child eq 'BLOCK')
        {   push @res, xml_any($doc, $child, $indent, $args);
        }
        else
        {   push @res, $doc->createTextNode($indent)
              , scalar xml_any($doc, $child, $nest_indent, $args);
        }
    }

    (my $outdent = $indent) =~ s/$args->{indent}$//;  # sorry

    if(my $example = $ast->{example})
    {  push @res, $doc->createTextNode
          (@comment ? "$indent$example$outdent" : $example)
    }

    if($ast->{type} && $args->{show_type})
    {   my $full = $ast->{type};
        my ($ns, $type) = $full =~ m/^\{([^}]*)\}(.*)/ ? ($1,$2) : ('',$full);
        # Don't known how to encode the namespace (yet)
        push @res, $doc->createAttribute(type => $type);
    }

    return @res
        if wantarray;

    my $node = $doc->createElement($ast->{tag});
    $node->addChild($_) for @res;
    $node->appendText($outdent) if @childs;
    $node;
}


1;
