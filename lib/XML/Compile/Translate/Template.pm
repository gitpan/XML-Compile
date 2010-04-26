# Copyrights 2006-2010 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.06.

package XML::Compile::Translate::Template;
use vars '$VERSION';
$VERSION = '1.14';

use base 'XML::Compile::Translate';

use strict;
use warnings;
no warnings 'once';

use XML::Compile::Util qw/odd_elements pack_type unpack_type/;
use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util  qw/max/;

our $VERSION;         # OODoc adds $VERSION to the script
$VERSION ||= 'undef';


sub makeTagQualified
{   my ($self, $path, $node, $local, $ns) = @_;
    my $prefix = $self->_registerNSprefix('', $ns, 1);

      $self->{_output} eq 'PERL' ? $self->keyRewrite(pack_type $ns,$local)
    : length $prefix             ? $prefix .':'. $local
    :                              $local;
}

sub makeTagUnqualified
{   my ($self, $path, $node, $name) = @_;
    $name =~ s/.*\://;
    $name;
}

my (%recurse, %reuse);
sub compile($@)
{   my ($self, $type, %args) = @_;
    $self->{_output} = $args{output};
    (%recurse, %reuse) = ();
    $self->SUPER::compile($type, %args);
}

sub actsAs($)
{   my ($self, $as) = @_;
       ($as eq 'READER' && $self->{_output} eq 'PERL')
    || ($as eq 'WRITER' && $self->{_output} eq 'XML')

}

sub makeWrapperNs($$$$$)
{   my ($self, $path, $processor, $index, $filter) = @_;

    my @entries;
    $filter = sub {1} if ref $filter ne 'CODE';

    foreach my $entry (sort {$a->{prefix} cmp $b->{prefix}} values %$index)
    {   $entry->{used} or next;
        $filter->($entry->{uri}, $entry->{prefix}) or next;
        push @entries, [ $entry->{uri}, $entry->{prefix} ];
        $entry->{used} = 0;
    }

    sub { my $data = $processor->(@_) or return ();
          if($self->{include_namespaces})
          {   $data->{"xmlns:$_->[1]"} = $_->[0] for @entries;
          }
          $data;
        };
}

sub typemapToHooks($$)
{   my ($self, $hooks, $typemap) = @_;

    while(my($type, $action) = each %$typemap)
    {   defined $action or next;

        my ($struct, $example)
          = $action =~ s/^[\\]?\&/\$/
          ? ( "call on converter function with object"
            , "$action->('WRITER', \$object, '$type', \$doc)")
          : $action =~ m/^\$/
          ? ( "call on converter with object"
            , "$action->toXML(\$object, '$type', \$doc)")
          : ( [ "calls toXML() on $action objects", "  with $type and doc" ]
            , "bless({}, '$action')" );

        my $details  =
          { struct  => $struct
          , example => $example
          };

        push @$hooks, { type => $type, replace => sub { $details} };
    }

    $hooks;
}

sub makeElementWrapper
{   my ($self, $path, $processor) = @_;
    sub { $processor->() };
}
*makeAttributeWrapper = \&makeElementWrapper;

sub _block($@)
{   my ($self, $block, $path, @pairs) = @_;
    bless
    sub { my @elems  = map { $_->() } odd_elements @pairs;
          my @tags   = map { $_->{tag} } @elems;

          local $" = ', ';
          my $struct = @tags ? "$block of @tags" : "empty $block";
          my @lines;
          while(length $struct > 65)
          {   $struct =~ s/(.{1,60})(\s)//;
              push @lines, $1;
          }
          push @lines, $struct;
          $lines[$_] =~ s/^/  / for 1..$#lines;

           { tag    => $block
           , elems  => \@elems
           , struct => \@lines
           };
        }, 'BLOCK';
}

sub makeSequence { my $self = shift; $self->_block(sequence => @_) }
sub makeChoice   { my $self = shift; $self->_block(choice   => @_) }
sub makeAll      { my $self = shift; $self->_block(all      => @_) }

sub makeBlockHandler
{   my ($self, $path, $label, $min, $max, $proc, $kind, $multi) = @_;

    my $code =
    sub { my $data = $proc->();
          my $occur
           = $max eq 'unbounded' && $min==0 ? 'occurs any number of times'
           : $max ne 'unbounded' && $max==1 && $min==0 ? 'is optional' 
           : $max ne 'unbounded' && $max==1 && $min==1 ? ''  # the usual case
           :       "occurs $min <= # <= $max times";

          $data->{occur} ||= $occur if $occur;
          if($max ne 'unbounded' && $max==1)
          {   bless $data, 'BLOCK';
          }
          else
          {   $data->{tag}      = $multi;
              $data->{is_array} = 1;
              bless $data, 'REP-BLOCK';
          }
          $data;
        };
    ($label => $code);
}

sub makeElementHandler
{   my ($self, $path, $label, $min, $max, $req, $opt) = @_;
    sub { my $data = $opt->() or return;
          my $occur
           = $max eq 'unbounded' && $min==0 ? 'occurs any number of times'
           : $max ne 'unbounded' && $max==1 && $min==0 ? 'is optional' 
           : $max ne 'unbounded' && $max==1 && $min==1 ? ''  # the usual case
           :                                  "occurs $min <= # <= $max times";
          $data->{occur}  ||= $occur if $occur;
          $data->{is_array} = $max eq 'unbounded' || $max > 1;
          $data;
        };
}

sub makeRequired
{   my ($self, $path, $label, $do) = @_;
    $do;
}

sub makeElementHref
{   my ($self, $path, $ns, $childname, $do) = @_;
    $do;
}

sub makeElement
{   my ($self, $path, $ns, $childname, $do) = @_;
    sub {
       my $h = $do->(@_);
       $h->{_NAME} = $childname;
       $h;
    };
}

sub makeElementDefault
{   my ($self, $path, $ns, $childname, $do, $default) = @_;
    sub { my $h = $do->(@_);
          $h->{occur}   = "$childname defaults to $default";
          $h->{example} = $default;
          $h;
        };
}

sub makeElementFixed
{   my ($self, $path, $ns, $childname, $do, $fixed) = @_;
    sub { my $h = $do->(@_);
          $h->{occur}   = "$childname fixed to $fixed";
          $h->{example} = $fixed;
          $h;
        };
}

sub makeElementNillable
{   my ($self, $path, $ns, $childname, $do) = @_;
    sub { +{occur => "$childname is nillable", $do->()} };
}

sub makeElementAbstract
{   my ($self, $path, $ns, $childname, $do) = @_;
    sub { () };
}

sub makeComplexElement
{   my ($self, $path, $tag, $elems, $attrs, $any_attr) = @_;
    my @parts = (odd_elements(@$elems, @$attrs), @$any_attr);

    sub { my (@attrs, @elems);

          if($recurse{$tag})
          {   return
              +{ kind   => 'complex'
               , struct => 'probably a recursive complex'
               , tag    => $tag
               };
          }

          if($reuse{$tag})
          {   return
              +{ kind   => 'complex'
               , struct => 'complex structure shown above'
               , tag    => $tag
               };
          }

          $recurse{$tag}++;
          $reuse{$tag}++;
          foreach my $part (@parts)
          {   my $child = $part->();
              if($child->{attr}) { push @attrs, $child }
              else               { push @elems, $child }
          }
          $recurse{$tag}--;

          +{ kind    => 'complex'
#          , struct  => "$tag is complex"  # too obvious to mention
           , tag     => $tag
           , attrs   => \@attrs
           , elems   => \@elems
           };
        };
}

sub makeTaggedElement
{   my ($self, $path, $tag, $st, $attrs, $attrs_any) = @_;
    my @parts = (odd_elements(@$attrs), @$attrs_any);

    my %content =
     ( tag     => '_'
     , struct  => 'string content of the container'
     , example => 'Hello, World!' 
     );

    sub { my @attrs  = map {$_->()} @parts;
          my $simple = $st->() || '';

          +{ kind    => 'tagged'
           , struct  => "$tag is simple value with attributes"
           , tag     => $tag
           , attrs   => \@attrs
           , elems   => [ \%content ]
           };
        };
}

sub makeMixedElement
{   my ($self, $path, $tag, $elems, $attrs, $attrs_any) = @_;
    my @parts = (odd_elements(@$attrs), @$attrs_any);

    my %mixed =
     ( tag     => '_'
     , struct  => "mixed content cannot be processed automatically"
     , example => "XML::LibXML::Element->new('$tag')"
     );

    unless(@parts)   # show simpler alternative
    {   $mixed{tag} = $tag;
        return sub { \%mixed };
    }

    sub { my @attrs = map {$_->()} @parts;
          +{ kind    => 'mixed'
           , struct  => "$tag has a mixed content"
           , tag     => $tag
           , elems   => [ \%mixed ]
           , attrs   => \@attrs
           };
        };
}

sub makeSimpleElement
{   my ($self, $path, $tag, $st) = @_;
    sub { +{ kind    => 'simple'
#          , struct  => "elem $tag is a single value"  # too obvious
           , tag     => $tag
           , $st->()
           };
        };
}

sub makeBuiltin
{   my ($self, $path, $node, $type, $def, $check_values) = @_;
    my $example = $def->{example};
    my ($ns, $local) = unpack_type $type;
    my $prefix       = $self->_registerNSprefix('', $ns, 1);
    my $preftype     = length $prefix ? "$prefix:$local" : $local;
    sub { (type => $preftype, example => $example) };
}

sub makeList
{   my ($self, $path, $st) = @_;
    sub { (struct => "a (blank separated) list of elements", $st->()) };
}

sub makeFacetsList
{   my ($self, $path, $st, $info) = @_;
    $self->makeFacets($path, $st, $info);
}

sub _ff($@)
{  my ($self,$type) = (shift, shift);
    my @lines = $type.':';
    while(@_)
    {   my $facet = shift;
        push @lines, '  ' if length($lines[-1]) + length($facet) > 55;
        $lines[-1] .= ' '.$facet;
    }
    @lines;
}

sub makeFacets
{   my ($self, $path, $st, $info) = @_;
    my @comment;
    foreach my $k (sort keys %$info)
    {   my $v = $info->{$k};
        push @comment
        , $k eq 'enumeration'  ? $self->_ff('Enum', sort @$v)
        : $k eq 'pattern'      ? $self->_ff('Pattern', @$v)
        : $k eq 'length'       ? "fixed length of $v"
        : $k eq 'maxLength'    ? "length <= $v"
        : $k eq 'minLength'    ? "length >= $v"
        : $k eq 'totalDigits'  ? "total digits is $v"
        : $k eq 'maxScale'     ? "scale <= $v"
        : $k eq 'minScale'     ? "scale >= $v"
        : $k eq 'maxInclusive' ? "value <= $v"
        : $k eq 'maxExclusive' ? "value < $v"
        : $k eq 'minInclusive' ? "value >= $v"
        : $k eq 'minExclusive' ? "value >  $v"
        : $k eq 'fractionDigits' ? "faction digits is $v"
        : "restriction $k = $v";
    }
    sub { (facets => \@comment, $st->()) };
}

sub makeUnion
{   my ($self, $path, @types) = @_;
    sub { my @choices = map { +{$_->()} } @types;
          +( kind    => 'union'
           , struct  => "one of the following (union)"
           , choice  => \@choices
           , example => $choices[0]->{example}
           );
        };
}

sub makeAttributeRequired
{   my ($self, $path, $ns, $tag, $label, $do) = @_;

    sub { +{ kind   => 'attr'
           , tag    => $label
           , occur  => "attribute $tag is required"
           , $do->()
           };
        };
}

sub makeAttributeProhibited
{   my ($self, $path, $ns, $tag, $label, $do) = @_;
    ();
}

sub makeAttribute
{   my ($self, $path, $ns, $tag, $label, $do) = @_;
    sub { +{ kind    => 'attr'
           , tag     => $label
           , $do->()
           };
        };
}

sub makeAttributeDefault
{   my ($self, $path, $ns, $tag, $label, $do) = @_;
    sub { +{ kind  => 'attr'
           , tag   => $label
           , occur => "attribute $tag has default"
           , $do->()
           };
        };
}

sub makeAttributeFixed
{   my ($self, $path, $ns, $tag, $label, $do, $fixed) = @_;
    my $value = $fixed->value;

    sub { +{ kind   => 'attr'
           , tag    => $label
           , occur  => "attribute $tag is fixed"
           , example => $value
           };
        };
}

sub makeSubstgroup
{   my ($self, $path, $type, @do) = @_;
    my @tags    = sort map { $_->[0] } odd_elements @do;

    my $longest = max map length, @tags;
    my $columns = int(60 / ($longest + 2));
    my $rows    = int(@tags / $columns) + (@tags % $columns ? 1 : 0);

    my @lines;
    foreach (0..@tags)
    {   defined $tags[$_] or next;
        $lines[$_ % $rows] .= sprintf "  %-${longest}s", $tags[$_];
    }

    sub { +{ kind    => 'substitution group'
           , tag     => $do[1][0]
           , struct  => [ "substitutionGroup", "$type:", @lines ]
           , example => "{ $tags[0] => {...} }"
           }
        };
}

sub makeXsiTypeSwitch($$$$)
{   my ($self, $where, $elem, $default_type, $types) = @_;

    sub { +{ kind    => 'xsi:type switch'
           , tag     => $elem
           , struct  => [ 'xsi:type alternatives:', sort keys %$types ]
           , example => "{ XSI_TYPE => '$default_type', %data }"
           }
        };
}

sub makeAnyAttribute
{   my ($self, $path, $handler, $yes, $no, $process) = @_;
    $yes ||= []; $no ||= [];
    my $occurs = @$yes ? "in @$yes" : @$no ? "not in @$no" : 'any type';
    bless sub { +{kind => 'attr' , struct  => "anyAttribute $occurs"
                 , tag => 'ANYATTR', example => 'AnySimple'} }, 'ANY';
}

sub makeAnyElement
{   my ($self, $path, $handler, $yes, $no, $process, $min, $max) = @_;
    $yes ||= []; $no ||= [];
    my $occurs = @$yes ? "in @$yes" : @$no ? "not in @$no" : 'any type';
    bless sub { +{ kind => 'element', struct  => 'anyElement'
                 , tag => "ANY", example => 'ANY' } }, 'ANY';
}

sub makeHook($$$$$$)
{   my ($self, $path, $r, $tag, $before, $replace, $after) = @_;

    return $r unless $before || $replace || $after;

    error __x"template only supports one production (replace) hook"
        if $replace && @$replace > 1;

    return sub {()} if $replace && grep {$_ eq 'SKIP'} @$replace;

    my @replace = $replace ? map {$self->_decodeReplace($path,$_)} @$replace:();
    my @before  = $before  ? map {$self->_decodeBefore($path,$_) } @$before :();
    my @after   = $after   ? map {$self->_decodeAfter($path,$_)  } @$after  :();

    sub
    {  for(@before) { $_->($tag, $path) or return }

       my $d = @replace ? $replace[0]->($tag, $path, $r) : $r->();
       defined $d or return ();

       for(@after) { $d = $_->($d, $tag, $path) or return }
       $d;
     }
}

sub _decodeBefore($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';
    error __x"labeled before hook `{name}' undefined", name => $call;
}

sub _decodeReplace($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

    if($call eq 'COLLAPSE')
    {   return sub 
         {  my ($tag, $path, $do) = @_;
            my $h = $do->();
            $h->{elems} = [ { struct => [ 'content collapsed' ]
                            , kind   => 'collapsed' } ];
            delete $h->{attrs};
            $h;
         };
    }

    # SKIP already handled
    error __x"labeled replace hook `{name}' undefined", name => $call;
}

sub _decodeAfter($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';
    error __x"labeled after hook `{name}' undefined", name => $call;
}


###
### toPerl
###

sub toPerl($%)
{   my ($self, $ast, %args) = @_;
    $ast or return undef;

    my @lines;
    push @lines, "# Describing $ast->{kind} ".($ast->{_NAME}||$ast->{tag})
        if $ast->{kind};

    push @lines
      , "#"
      , "# Produced by ".__PACKAGE__." version $VERSION"
      , "#          on ".localtime()
      , "#"
      , "# BE WARNED: in most cases, the example below cannot be used without"
      , "# interpretation.  The comments will guide you."
      , "#"
        unless $args{skip_header};

    # add info about name-spaces
    foreach my $nsdecl (grep /^xmlns\:/, sort keys %$ast)
    {   push @lines, sprintf "# %-15s %s", $nsdecl, $ast->{$nsdecl} || '(none)';
    }
    push @lines, '' if @lines;
    
    # produce data tree
    push @lines, $self->_perlAny($ast, \%args);

    # remove leading  'type =>'
    for(my $linenr = 0; $linenr < @lines; $linenr++)
    {   next if $lines[$linenr] =~ m/^\s*\#/;
        next unless $lines[$linenr] =~ s/.* \=\>\s*//;
        $lines[$linenr] =~ m/\S/ or splice @lines, $linenr, 1;
        last;
    }

    my $lines = join "\n", @lines;
    $lines =~ s/\,?\s*$/\n/;
    $lines;
}

my %seen;
sub _perlAny($$);
sub _perlAny($$)
{   my ($self, $ast, $args) = @_;

    my @lines;
    if($ast->{struct} && $args->{show_struct})
    {   my $struct = $ast->{struct};
        my @struct = ref $struct ? @$struct : $struct;
        s/^/# /gm for @struct;
        push @lines, @struct;
    }
    push @lines, "# is a $ast->{type}" if $ast->{type} && $args->{show_type};
    push @lines, "# $ast->{occur}"  if $ast->{occur}   && $args->{show_occur};

    if($ast->{facets}  && $args->{show_facets})
    {   my $facets = $ast->{facets};
        my @facets = ref $facets ? @$facets : $facets;
        s/^/# /gm for @facets;
        push @lines, @facets;
    }

    my @childs;
    push @childs, @{$ast->{attrs}}  if $ast->{attrs};
    push @childs, @{$ast->{elems}}  if $ast->{elems};
    push @childs,   $ast->{body}    if $ast->{body};

    my @subs;
    foreach my $child (@childs)
    {   my @sub = $self->_perlAny($child, $args);
        @sub or next;

        # last line is code and gets comma
        $sub[-1] =~ s/\,?\s*$/,/ if $sub[-1] !~ m/\#\s/;

        if(ref $ast ne 'BLOCK')
        {   s/^(.)/$args->{indent}$1/ for @sub;
        }

        # seperator blank, sometimes
        unshift @sub, '' if $sub[0] =~ m/^\s*[#{]/;  # } 

        push @subs, @sub;
    }

    if(ref $ast eq 'REP-BLOCK')
    {  # repeated block
       @subs or @subs = '';
       $subs[0]  =~ s/^  /{ /;
       if($subs[-1] =~ m/\#\s/) { push @subs, "}," }
       else { $subs[-1] =~ s/$/ },/ }
    }

    # XML does not permit difficult tags, but we still check.
    my $tag = $ast->{tag} || '';
    if(defined $tag && $tag !~ m/^[\w_][\w\d_]*$/)
    {   $tag =~ s/\\/\\\\/g;
        $tag =~ s/'/\\'/g;
        $tag = qq{'$tag'};
    }

    my $kind = $ast->{kind} || '';
    if(ref $ast eq 'REP-BLOCK')
    {   s/^(.)/  $1/ for @subs;
        $subs[0] =~ s/^ ?/[/;
        push @lines, "$tag => ", @subs , ']';
    }
    elsif(ref $ast eq 'BLOCK')
    {   push @lines, @subs;
    }
    elsif(@subs)
    {   length $subs[0] or shift @subs;
        if($ast->{is_array})
        {   s/^(.)/  $1/ for @subs;
            $subs[0]  =~ s/^[ ]{0,3}/[ {/;
            if($subs[-1] =~ m/\#\s/) { push @subs, "}, ], " }
            else {$subs[-1] =~ s/$/ }, ], / }
            push @lines, "$tag =>", @subs;
        }
        else
        {   $subs[0]  =~ s/^  /{ /;
            if($subs[-1] =~ m/\#\s/) { push @subs, "}, " }
            else {$subs[-1] =~ s/$/ },/ }
            push @lines, "$tag =>", @subs;
        }
    }
    elsif($kind eq 'complex' || $kind eq 'mixed')  # empty complex-type
    {   push @lines, "$tag => {}";
    }
    elsif($kind eq 'collapsed') {;}
    elsif($kind eq 'union')    # union type
    {   foreach my $union ( @{$ast->{choice}} )
        {  # remove examples
           my @l = grep { m/^#/ } $self->_perlAny($union, $args);
           s/^\#/#  -/ for $l[0];
           s/^\#/#   / for @l[1..$#l];
           push @lines, @l;
        }
    }
    elsif(!$ast->{example})
    {   push @lines, "$tag => 'TEMPLATE-ERROR $ast->{kind}'";
    }

    if(my $example = $ast->{example})
    {   $example = qq{"$example"}      # in quotes unless
          if $example !~ m/^[+-]?\d+(?:\.\d+)?$/  # numeric or
          && $example !~ m/^\$/                   # variable or
          && $example !~ m/^bless\b/              # constructor or
          && $example !~ m/^\$?[\w:]*\-\>/        # method call example
          && $example !~ m/^\{.*\}$/              # anon HASH example
          && $example !~ m/^\[.*\]$/;             # anon ARRAY example

        push @lines, "$tag => "
          . ($ast->{is_array} ? " [ $example, ]" : $example);
    }
    @lines;
}

###
### toXML
###

sub toXML($$%)
{   my ($self, $doc, $ast, %args) = @_;
    my $xml = $self->_xmlAny($doc, $ast, "\n$args{indent}", \%args);

    UNIVERSAL::isa($xml, 'XML::LibXML::Element')
        or return $xml;

    # add comment
    my $pkg = __PACKAGE__;
    my $now = localtime();

    my $header = $doc->createComment( <<_HEADER . '    ' );
 BE WARNED: in most cases, the example below cannot be used without
    -- interpretation.  The comments will guide you.
    -- Produced by $pkg version $VERSION
    --          on $now
_HEADER

    unless($args{skip_header})
    {   $xml->insertBefore($header, $xml->firstChild);
        $xml->insertBefore($doc->createTextNode("\n  "), $header);
    }

    # add info about name-spaces
    foreach (sort keys %$ast)
    {   if( m/^xmlns\:(.*)/ )
        {   $xml->setNamespace($ast->{$_}, $1, 0);
        }
    }

    $xml;
}

sub _xmlAny($$$$);
sub _xmlAny($$$$)
{   my ($self, $doc, $ast, $indent, $args) = @_;
    my @res;

    my @comment;
    if($ast->{struct} && $args->{show_struct})
    {   my $struct = $ast->{struct};
        push @comment, ref $struct ? @$struct : $struct;
    }

    push @comment, $ast->{occur}  if $ast->{occur}  && $args->{show_occur};

    if($ast->{facets}  && $args->{show_facets})
    {   my $facets = $ast->{facets};
        push @comment, ref $facets eq 'ARRAY' ? @$facets : $facets;
    }

    if(defined $ast->{kind} && $ast->{kind} eq 'union')
    {   push @comment, map { "  $_->{type}"} @{$ast->{choice}};
    }

    my @attrs = @{$ast->{attrs} || []};
    foreach my $attr (@attrs)
    {   push @res, $doc->createAttribute($attr->{tag}, $attr->{example});
        push @comment, "$attr->{tag}: $attr->{type}"
            if $args->{show_type};
    }

    my $nest_indent = $indent.$args->{indent};
    if(@comment)
    {   my $comment = ' '.join("$nest_indent   ", @comment) .' ';
        push @res
          , $doc->createTextNode($indent)
          , $doc->createComment($comment);
    }

    my @elems = @{$ast->{elems} || []};
    foreach my $elem (@elems)
    {   if(ref $elem eq 'BLOCK' || ref $elem eq 'REP-BLOCK')
        {   push @res, $self->_xmlAny($doc, $elem, $indent, $args);
        }
        elsif($elem->{tag} eq '_')
        {   push @res, $doc->createTextNode($indent.$elem->{example});
        }
        else
        {   push @res, $doc->createTextNode($indent)
              , scalar $self->_xmlAny($doc, $elem, $nest_indent, $args);
        }
    }

    (my $outdent = $indent) =~ s/$args->{indent}$//;  # sorry

    if(my $example = $ast->{example})
    {  push @res, $doc->createTextNode
          (@comment ? "$indent$example$outdent" : $example)
    }

    if($ast->{type} && $args->{show_type})
    {   my $full = $ast->{type};
        my ($ns, $type) = unpack_type $full;
        # Don't known how to encode the namespace (yet)
        push @res, $doc->createAttribute(type => $type);
    }

    return @res
        if wantarray;

    my $node = $doc->createElement($ast->{tag});
    $node->addChild($_) for @res;
    $node->appendText($outdent) if @elems;
    $node;
}

sub makeBlocked($$$)
{   my ($self, $where, $class, $type) = @_;
    panic "namespace blocking not yet supported for Templates";
}


1;
