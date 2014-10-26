# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.05.

package XML::Compile::Schema::XmlWriter;
use vars '$VERSION';
$VERSION = '0.89';


use strict;
use warnings;
no warnings 'once';

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util    qw/first/;
use Scalar::Util  qw/blessed/;
use XML::Compile::Util qw/pack_type unpack_type odd_elements
   block_label type_of_node/;


# Each action implementation returns a code reference, which will be
# used to do the run-time work.  The principle of closures is used to
# keep the important information.  Be sure that you understand closures
# before you attempt to change anything.
#
# The returned writer subroutines will always be called
#       $writer->($doc, $value) 

sub tag_qualified
{   my ($path, $args, $node, $local, $ns) = @_;

    my $out_ns = $args->{prefixes} ||= {};
    my $out;
    if($out = $out_ns->{$ns})
    {   # re-use existing prefix
    }
    elsif(! grep {$_->{prefix} eq ''} values %$out_ns)
    {   # the default (blank) prefix is free
        $out = $out_ns->{$ns} = {uri => $ns, prefix => ''};
    }
    else
    {   # create a new x\d+ prefix
        # get (also the user defined) x\d+ prefixes used, and add one
        my ($last) = sort {$b cmp $a} grep /^x\d+$/, 
          , map {$_->{prefix}} values %$out_ns;
        my $next   = defined $last && $last =~ m/^x(\d+)/ ? 'x'.($1+1) : 'x0';
        $out = $out_ns->{$ns} = {uri => $ns, prefix => $next};
    }

    $out->{used}++;
    my $prefix = $out->{prefix};
    length($prefix) ? "$prefix:$local" : $local;
}

sub tag_unqualified
{   my ($path, $args, $node, $name) = @_;
    $name =~ s/.*\://;
    $name;
}

sub _typemap_class($$)
{   my ($type, $class) = @_;

    no strict 'refs';
    keys %{$class.'::'}
        or error __x"class {pkg} for typemap {type} is not loaded"
             , pkg => $class, type => $type;

    $class->can('toXML')
        or error __x"class {pkg} does not implement toXML(), required for typemap {type}"
             , pkg => $class, type => $type;

    sub { my ($doc, $values, $path) = @_;
            UNIVERSAL::isa($values, $class)
          ? $values->toXML($type, $doc)
          : $values;
    };
}

sub _typemap_object($$)
{   my ($type, $object) = @_;

    $object->can('toXML')
        or error __x"object of class {pkg} does not implement toXML(), required for typemap {type}"
             , pkg => ref($object), type => $type;

    sub { my ($doc, $values, $path) = @_;
          blessed($values) ? $object->toXML($values, $type, $doc) : $values;
    };
}

sub typemap_to_hooks($$)
{   my ($hooks, $typemap) = @_;
    while(my($type, $action) = each %$typemap)
    {   defined $action or next;
        my $hook;
        if(!ref $action)
        {   $hook = _typemap_class $type, $action;
            trace "created writer hook for type $type to class $action";
        }
        elsif(ref $action eq 'CODE')
        {   $hook = sub {
               my ($doc, $values, $path) = @_;
                 blessed($values)
               ? $action->(WRITER => $values, $type, $doc)
               : $values;
            };
            trace "created writer hook for type $type to CODE";
        }
        else
        {   $hook = _typemap_object $type, $action;
            trace "created reader hook for type $type to object";

        }

        push @$hooks, { type => $type, before => $hook };
    }
    $hooks;
}

sub element_wrapper
{   my ($path, $args, $processor) = @_;
    sub { my ($doc, $data) = @_;
          UNIVERSAL::isa($doc, 'XML::LibXML::Document')
              or error __x"first argument of call to writer must be an XML::LibXML::Document";

          my $top = $processor->(@_);
          $doc->indexElements;
          $top;
        };
}
*attribute_wrapper = \&element_wrapper;

sub wrapper_ns
{   my ($path, $args, $processor, $index) = @_;
    my @entries;
    foreach my $entry (values %$index)
    {   $entry->{used} or next;
        push @entries, [ $entry->{uri}, $entry->{prefix} ];
#       $entry->{used} = 0;
    }

    @entries or return $processor;

    sub { my $node = $processor->(@_) or return ();
          $node->setNamespace(@$_, 0) foreach @entries;
          $node;
        };
}

sub sequence($@)
{   my ($path, $args, @pairs) = @_;

    if(@pairs==2 && !ref $pairs[1])
    {   my ($take, $do) = @pairs;
        return bless
        sub { my ($doc, $values) = @_;
              defined $values or return;
              $do->($doc, delete $values->{$take});
            }, 'BLOCK';
    }
 
    return bless
    sub { my ($doc, $values) = @_;
          defined $values or return;

          my @res;
          my @do = @pairs;
          while(@do)
          {   my ($take, $do) = (shift @do, shift @do);
              push @res
                 , ref $do eq 'BLOCK' ? $do->($doc, $values)
                 : ref $do eq 'ANY'   ? $do->($doc, $values)
                 : $do->($doc, delete $values->{$take});
          }
          @res;
        }, 'BLOCK';
}

sub choice($@)
{   my ($path, $args, %do) = @_;
    my @specials;
    foreach my $el (keys %do)
    {   push @specials, delete $do{$el}
            if ref $do{$el} eq 'BLOCK' || ref $do{$el} eq 'ANY';
    }
 
    if(!@specials && keys %do==1)
    {   my ($take, $do) = %do;
        return bless
        sub { my ($doc, $values) = @_;
                defined $values && $values->{$take}
              ? $do->($doc, delete $values->{$take}) : ();
            }, 'BLOCK';
    }

    bless
    sub { my ($doc, $values) = @_;
          defined $values or return ();
          foreach my $take (keys %do)
          {  return $do{$take}->($doc, delete $values->{$take})
                 if $values->{$take};
          }
          
          foreach (@specials)
          {  my @d = try { $_->($doc, $values) };
             $@ or return @d;
          }
          ();
        }, 'BLOCK';
}

sub all($@)
{   my ($path, $args, @pairs) = @_;

    if(@pairs==2 && !ref $pairs[1])
    {   my ($take, $do) = @pairs;
        return bless
        sub { my ($doc, $values) = @_;
              $do->($doc, delete $values->{$take});
            }, 'BLOCK';
    }

    return bless
    sub { my ($doc, $values) = @_;

          my @res;
          my @do = @pairs;
          while(@do)
          {   my ($take, $do) = (shift @do, shift @do);
              push @res
                 , ref $do eq 'BLOCK' || ref $do eq 'ANY'
                 ? $do->($doc, $values)
                 : $do->($doc, delete $values->{$take});
          }
          @res;
        }, 'BLOCK';
}
 
#
## Element
#

sub element_handler
{   my ($path, $args, $label, $min, $max, $required, $optional) = @_;
    $max eq "0" and return sub {};

    if($min==0 && $max eq 'unbounded')
    {   return
        sub { my ($doc, $values) = @_;
                ref $values eq 'ARRAY' ? map {$optional->($doc,$_)} @$values
              : defined $values        ? $optional->($doc, $values)
              :                          ();
            };
    }

    if($max eq 'unbounded')
    {   return
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();
              ( (map { $required->($doc, shift @values) } 1..$min)
              , (map { $optional->($doc, $_) } @values)
              );
            };
    }

    return $optional
        if $min==0 && $max==1;

    if($min==1 && $max==1)
    {   return
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();

              error __x"exactly one value needed for `{tag}', not {count} at {path}"
                , tag => $label, count => scalar @values, path => $path
                    if @values > 1;

              $required->($doc, $values[0]);
            };
    }

    my $opt = $max - $min;
    sub { my ($doc, $values) = @_;
          my @values = ref $values eq 'ARRAY' ? @$values
                     : defined $values ? $values : ();

          ( (map { $required->($doc, shift @values) } 1..$min)
          , (map { $optional->($doc, shift @values) } 1..$opt)
          );
        };
}

sub block_handler
{   my ($path, $args, $label, $min, $max, $process, $kind) = @_;
    my $multi = block_label $kind, $label;

    if($min==0 && $max eq 'unbounded')
    {   my $code =
        sub { my $doc    = shift;
              my $values = delete shift->{$multi};
                ref $values eq 'ARRAY' ? (map {$process->($doc, $_)} @$values)
              : defined $values        ? $process->($doc, $values)
              :                          ();
            };
        return ($multi, bless($code, 'BLOCK'));
    }

    if($max eq 'unbounded')
    {   my $code =
        sub { my $doc    = shift;
              my $values = delete shift->{$multi};
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();

              @values >= $min
                  or error __x"too few blocks specified for `{tag}', got {found} need {min} at {path}"
                        , tag => $label, found => scalar @values
                        , min => $min, path => $path;

              map { $process->($doc, $_) } @values;
            };
        return ($multi, bless($code, 'BLOCK'));
    }

    if($min==0 && $max==1)
    {   my $code =
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();

              @values <= 1
                  or error __x"maximum only block needed for `{tag}', not {count} at {path}"
                        , tag => $label, count => scalar @values, path => $path;

              map { $process->($doc, $_) } @values;
            };
        return ($label, bless($code, 'BLOCK'));
    }

    if($min==1 && $max==1)
    {   my $code =
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();
              @values==1
                  or error __x"exactly one block needed for `{tag}', not {count} at {path}"
                        , tag => $label, count => scalar @values, path => $path;

              $process->($doc, $values[0]);
            };
        return ($label, bless($code, 'BLOCK'));
    }

    my $opt  = $max - $min;
    my $code =
    sub { my $doc    = shift;
          my $values = delete shift->{$multi};
          my @values = ref $values eq 'ARRAY' ? @$values
                     : defined $values ? $values : ();

          @values >= $min && @values <= $max
              or error __x"found {found} blocks for `{tag}', must be between {min} and {max} inclusive"
                   , tag => $label, min => $min, max => $max
                   , found => scalar @values;

          map { $process->($doc, $_) } @values;
        };
    ($multi, bless($code, 'BLOCK'));
}

sub required
{   my ($path, $args, $label, $do) = @_;
    my $req =
    sub { my @nodes = $do->(@_);
          return @nodes if @nodes;

          error __x"required data for block starting with `{tag}' missing at {path}"
             , tag => $label, path => $path
                 if ref $do eq 'BLOCK';

          error __x"required value for element `{tag}' missing at {path}"
             , tag => $label, path => $path;
        };
    bless $req, 'BLOCK' if ref $do eq 'BLOCK';
    $req;
}

sub element
{   my ($path, $args, $ns, $childname, $do) = @_;
    sub { defined $_[1] ? $do->(@_) : () }
}

sub element_fixed
{   my ($path, $args, $ns, $childname, $do, $fixed) = @_;
    $fixed   = $fixed->value if ref $fixed;

    sub { my ($doc, $value) = @_;
          my $ret = defined $value ? $do->($doc, $value) : return;
          return $ret if defined $ret && $ret->textContent eq $fixed;

          defined $ret
              or error __x"required element `{name}' with fixed value `{fixed}' missing at {path}"
                     , name => $childname, fixed => $fixed, path => $path;

          error __x"element `{name}' has value fixed to `{fixed}', got `{value}' at {path}"
             , name => $childname, fixed => $fixed
             , value => $ret->textContent, path => $path;
        };
}

sub element_nillable
{   my ($path, $args, $ns, $childname, $do) = @_;
    my $inas = $args->{interpret_nillable_as_optional};

    sub
    {   my ($doc, $value) = @_;
        return $do->($doc, $value)
            if !defined $value || $value ne 'NIL';

        return $doc->createTextNode('')
            if $inas;

        my $node = $doc->createElement($childname);
        $node->setAttribute(nil => 'true');
        $node;
    };
}

sub element_default
{   my ($path, $args, $ns, $childname, $do, $default) = @_;
    sub { defined $_[1] ? $do->(@_) : (); };
}

sub element_abstract
{   my ($path, $args, $ns, $childname, $do, $default) = @_;
    sub { defined $_[1] or return ();
          error __x"attempt to instantiate abstract element `{name}' at {where}"
            , name => $childname, where => $path;
        };
}

#
# complexType/ComplexContent
#

sub complex_element
{   my ($path, $args, $tag, $elems, $attrs, $any_attr) = @_;
    my @elems = odd_elements @$elems;
    my @attrs = @$attrs;
    my @anya  = @$any_attr;
    my $iut   = $args->{ignore_unused_tags};

    return
    sub
    {   my ($doc, $data) = @_;
        return $doc->importNode($data)
            if UNIVERSAL::isa($data, 'XML::LibXML::Element');

        unless(UNIVERSAL::isa($data, 'HASH'))
        {   defined $data
                or error __x"complex `{tag}' requires data at {path}"
                      , tag => $tag, path => $path;

            error __x"complex `{tag}' requires a HASH of input data, not `{found}' at {path}"
               , tag => $tag, found => $data, path => $path;
        }

        my $copy   = { %$data };  # do not destroy caller's hash
        my @childs = map {$_->($doc, $copy)} @elems;
        for(my $i=0; $i<@attrs; $i+=2)
        {   push @childs, $attrs[$i+1]->($doc, delete $copy->{$attrs[$i]});
        }

        push @childs, $_->($doc, $copy)
            for @anya;

        if(%$copy)
        {   my @not_used
              = defined $iut ? grep({$_ !~ $iut} keys %$copy) : keys %$copy;

            mistake __xn "tag `{tags}' not used at {path}"
              , "unused tags {tags} at {path}"
              , scalar @not_used, tags => [sort @not_used], path => $path
                 if @not_used;
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

sub tagged_element
{   my ($path, $args, $tag, $st, $attrs, $attrs_any) = @_;
    my @attrs = @$attrs;
    my @anya  = @$attrs_any;

    return
    sub { my ($doc, $data) = @_;
          return $doc->importNode($data)
              if UNIVERSAL::isa($data, 'XML::LibXML::Element');

          UNIVERSAL::isa($data, 'HASH')
             or error __x"tagged `{tag}' requires a HASH of input data, not `{found}' at {path}"
                   , tag => $tag, found => $data, path => $path;

          my $copy    = { %$data };
          my $content = delete $copy->{_};

          my ($node, @childs);
          if(UNIVERSAL::isa($content, 'XML::LibXML::Node'))
          {   $node = $doc->importNode($content);
          }
          elsif(defined $content)
          {   push @childs, $content;
          }

          for(my $i=0; $i<@attrs; $i+=2)
          {   push @childs, $attrs[$i+1]->($doc, delete $copy->{$attrs[$i]});
          }

          push @childs, $_->($doc, $copy)
              for @anya;

          if(my @not_used = sort keys %$copy)
          {   error __xn "tag `{tags}' not processed at {path}"
                       , "unprocessed tags {tags} at {path}"
                       , scalar @not_used, tags => \@not_used, path => $path;
          }

          $node or @childs or return ();
          $node ||= $doc->createElement($tag);
          $node->addChild
            ( UNIVERSAL::isa($_, 'XML::LibXML::Node') ? $_
            : $doc->createTextNode(defined $_ ? $_ : ''))
               for @childs;
          $node;
       };
}

#
# complexType mixed or complexContent mixed
#

sub mixed_element
{   my ($path, $args, $tag, $elems, $attrs, $attrs_any) = @_;
    my @attrs = @$attrs;
    my @anya  = @$attrs_any;

    my $mixed = $args->{mixed_elements};
    if($mixed eq 'ATTRIBUTES') { ; }
    elsif($mixed eq 'STRUCTURAL')
    {   # mixed_element eq STRUCTURAL is handled earlier
        panic "mixed structural handled as normal element";
    }
    else { error __x"unknown mixed_elements value `{value}'", value => $mixed }

    if(!@attrs && !@anya)
    {   return
        sub { my ($doc, $data) = @_;
              my $node = ref $data eq 'HASH' ? $data->{_} : $data;
              return $doc->importNode($node)
                  if UNIVERSAL::isa($node, 'XML::LibXML::Element');
              error __x"mixed `{tag}' requires XML::LibXML::Node, not `{found}' at {path}"
                 , tag => $tag, found => $data, path => $path;
            };
    }

    sub { my ($doc, $data) = @_;
          return $doc->importNode($data)
              if UNIVERSAL::isa($data, 'XML::LibXML::Element');

          UNIVERSAL::isa($data, 'HASH')
             or error __x"mixed `{tag}' requires a HASH of input data, not `{found}' at {path}"
                   , tag => $tag, found => $data, path => $path;

          my $copy    = { %$data };
          my $content = delete $copy->{_};
          UNIVERSAL::isa($content, 'XML::LibXML::Node')
              or error __x"mixed `{tag}' value `_' must be XML::LibXML::Node, not `{found}' at {path}"
                   , tag => $tag, found => $data, path => $path;

          my $node = $doc->importNode($content);

          my @childs;
          for(my $i=0; $i<@attrs; $i+=2)
          {   push @childs, $attrs[$i+1]->($doc, delete $copy->{$attrs[$i]});
          }

          push @childs, $_->($doc, $copy)
              for @anya;

          if(my @not_used = sort keys %$copy)
          {   error __xn "tag `{tags}' not processed at {path}"
                       , "unprocessed tags {tags} at {path}"
                       , scalar @not_used, tags => \@not_used, path => $path;
          }

          @childs or return $node;
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

sub simple_element
{   my ($path, $args, $tag, $st) = @_;
    sub { my ($doc, $data) = @_;
          return $doc->importNode($data)
              if UNIVERSAL::isa($data, 'XML::LibXML::Element');
          
          my $value = $st->($doc, $data);
          my $node  = $doc->createElement($tag);
          error __x"expected single value for {tag}, but got {type}"
             , tag => $tag, type => ref($value)
              if ref $value eq 'ARRAY' || ref $value eq 'HASH';
          $node->addChild
            ( UNIVERSAL::isa($value, 'XML::LibXML::Node') ? $value
            : $doc->createTextNode(defined $value ? $value : ''));
          $node;
        };
}

sub builtin
{   my ($path, $args, $node, $type, $def, $check_values) = @_;
    my $check  = $check_values ? $def->{check} : undef;
    my $err    = $path eq $type
      ? N__"illegal value `{value}' for type {type}"
      : N__"illegal value `{value}' for type {type} at {path}";

    my $format = $def->{format};
    my $trans  = $args->{prefixes};

    $check
    ? ( defined $format
      ? sub { defined $_[1] or return undef;
              my $value = $format->($_[1], $trans);
              return $value if defined $value && $check->($value);
              error __x$err, value => $value, type => $type, path => $path;
            }
      : sub { return $_[1] if !defined $_[1] || $check->($_[1]);
              error __x$err, value => $_[1], type => $type, path => $path;
            }
      )
    : ( defined $format
      ? sub { defined $_[1] ? $format->($_[1], $trans) : undef }
      : sub { $_[1] }
      );
}

# simpleType

sub list
{   my ($path, $args, $st) = @_;
    sub { defined $_[1] or return undef;
          my @el = ref $_[1] eq 'ARRAY' ? @{$_[1]} : $_[1];
          my @r = grep {defined} map {$st->($_[0], $_)} @el;
          join ' ', @r;
        };
}

sub facets_list
{   my ($path, $args, $st, $info, $early, $late) = @_;
    sub { defined $_[1] or return undef;
          my @el = ref $_[1] eq 'ARRAY' ? (grep {defined} @{$_[1]}) : $_[1];

          my @r = grep {defined} map {$st->($_[0], $_)} @el;

      EL: for(@r)
          {   for my $l (@$late)
              { defined $_ or next EL; $_ = $l->($_) }
          }

          @r or return undef;
          my $r = join ' ', grep {defined} @r;

          my $v = $r;  # do not test with original
          for(@$early) { defined $v or return (); $v = $_->($v) }
          defined $v ? $r : ();
        };
}

sub facets
{   my ($path, $args, $st, $info, @do) = @_;
    sub { defined $_[1] or return undef;
          my $v = $st->(@_);
          for(reverse @do)
          { defined $v or return (); $v = $_->($v) }
          $v;
        };
}

sub union
{   my ($path, $args, @types) = @_;
    sub { my ($doc, $value) = @_;
          defined $value or return undef;
          for(@types) {my $v = try { $_->($doc, $value) }; $@ or return $v }
          

          substr $value, 10, -1, '...' if length($value) > 13;
          error __x"no match for `{text}' in union at {path}"
             , text => $value, path => $path;
        };
}

sub substgroup
{   my ($path, $args, $type, %done) = @_;

    keys %done or return bless sub { () }, 'BLOCK';
    my %do = map { @$_ } values %done;

    bless
    sub { my ($doc, $values) = @_;
          foreach my $take (keys %do)
          {   my $subst = delete $values->{$take}
                  or next;

              return $do{$take}->($doc, $subst);
          }
          ();
        }, 'BLOCK';
}

# Attributes

sub attribute_required
{   my ($path, $args, $ns, $tag, $do) = @_;

    sub { my $value = $do->(@_);
          return $_[0]->createAttributeNS($ns, $tag, $value)
              if defined $value;

          error __x"attribute `{tag}' is required at {path}"
             , tag => $tag, path => $path;
        };
}

sub attribute_prohibited
{   my ($path, $args, $ns, $tag, $do) = @_;

    sub { my $value = $do->(@_);
          defined $value or return ();

          error __x"attribute `{tag}' is prohibited at {path}"
             , tag => $tag, path => $path;
        };
}

sub attribute
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { my $value = $do->(@_);
          defined $value ? $_[0]->createAttribute($tag, $value) : ();
        };
}
*attribute_default = \&attribute;

sub attribute_fixed
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    $fixed   = $fixed->value if ref $fixed;

    sub { my ($doc, $value) = @_;
          defined $value or return ();

          $value eq $fixed
              or error __x"value of attribute `{tag}' is fixed to `{fixed}', not `{got}' at {path}"
                   , tag => $tag, got => $value, fixed => $fixed, path => $path;

          $doc->createAttributeNS($ns, $tag, $fixed);
        };
}

# any

sub _split_any_list($$$)
{   my ($path, $type, $v) = @_;
    my @nodes = ref $v eq 'ARRAY' ? @$v : defined $v ? $v : return ([], []);
    my (@attrs, @elems);

    foreach my $node (@nodes)
    {   ref $node && !UNIVERSAL::isa($node, 'XML::LibXML')
            or error __x"elements for 'any' are XML::LibXML nodes, not {string} at {path}"
                  , string => $node, path => $path;

        if($node->isa('XML::LibXML::Attr'))
        {   push @attrs, $node;
            next;
        }

        if($node->isa('XML::LibXML::Element'))
        {   push @elems, $node;
            next;
        }

        error __x"an XML::LibXML::Element or ::Attr is expected as 'any' or 'anyAttribute value with {type}, but a {kind} was found at {path}"
           , type => $type, kind => ref $node, path => $path;
    }

    return (\@attrs, \@elems);
}

sub anyAttribute
{   my ($path, $args, $handler, $yes, $no, $process) = @_;
    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    bless
    sub { my ($doc, $values) = @_;

          my @res;
          foreach my $type (keys %$values)
          {   my ($ns, $local) = unpack_type $type;
              defined $ns or next;
              my @elems;

              $yes{$ns} or next if keys %yes;
              $no{$ns} and next if keys %no;

              my ($attrs, $elems)
                = _split_any_list $path, $type, delete $values->{$type};

              $values->{$type} = $elems if @$elems;
              @$attrs or next;

              foreach my $node (@$attrs)
              {   my $nodetype = type_of_node $node;
                  next if $nodetype eq $type;

                  error __x"provided 'anyAttribute' node has type {type}, but labeled with {other} at {path}"
                     , type => $nodetype, other => $type, path => $path
              }

              push @res, @$attrs;
          }
          @res;
        }, 'ANY';
}

sub anyElement
{   my ($path, $args, $handler, $yes, $no, $process, $min, $max) = @_;
    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    $handler ||= 'SKIP_ALL';

    bless
    sub { my ($doc, $values) = @_;
          my @res;

          foreach my $type (keys %$values)
          {   my ($ns, $local) = unpack_type $type;

              # name-spaceless Perl, then not for any(Attribute)
              defined $ns && length $ns or next;

              $yes{$ns} or next if keys %yes;
              $no{$ns} and next if keys %no;

              my ($attrs, $elems)
                 = _split_any_list $path, $type, delete $values->{$type};

              $values->{$type} = $attrs if @$attrs;
              @$elems or next;

              foreach my $node (@$elems)
              {   my $nodens = $node->namespaceURI;
                  defined $nodens or next; # see README.todo work-around

                  my $nodetype = type_of_node $node;
                  next if $nodetype eq $type;

                  error __x"provided 'any' element node has type {type}, but labeled with {other} at {path}"
                     , type => $nodetype, other => $type, path => $path
              }

              push @res, @$elems;
              $max eq 'unbounded' || @res <= $max
                  or error __x"too many 'any' elements after consuming {count} nodes of {type}, max {max} at {path}"
                       , count => scalar @$elems, type => $type
                       , max => $max, path => $path;
          }

          @res >= $min
              or error __x"too few 'any' elements, got {count} for minimum {min} at {path}"
                   , count => scalar @res, min => $min, path => $path;

          @res;
        }, 'ANY';
}

sub hook($$$$$$)
{   my ($path, $args, $r, $tag, $before, $replace, $after) = @_;
    return $r unless $before || $replace || $after;

    error __x"writer only supports one production (replace) hook"
        if $replace && @$replace > 1;

    return sub {()} if $replace && grep {$_ eq 'SKIP'} @$replace;

    my @replace = $replace ? map {_decode_replace($path,$_)} @$replace : ();
    my @before  = $before  ? map {_decode_before($path,$_) } @$before  : ();
    my @after   = $after   ? map {_decode_after($path,$_)  } @$after   : ();

    sub
    {  my ($doc, $val) = @_;
       foreach (@before)
       {   $val = $_->($doc, $val, $path);
           defined $val or return ();
       }

       my $xml = @replace
               ? $replace[0]->($doc, $val, $path, $tag)
               : $r->($doc, $val);
       defined $xml or return ();

       foreach (@after)
       {   $xml = $_->($doc, $xml, $path);
           defined $xml or return ();
       }

       $xml;
     }
}

sub _decode_before($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub { print "$_[2]\n"; $_[1] }
    : error __x"labeled before hook `{name}' undefined", name => $call;
}

sub _decode_replace($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

    # SKIP already handled
    error __x"labeled replace hook `{name}' undefined", name => $call;
}

sub _decode_after($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub { print "$_[2]\n"; $_[1] }
    : error __x"labeled after hook `{name}' undefined", name => $call;
}


1;

