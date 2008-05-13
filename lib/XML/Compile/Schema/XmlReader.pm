# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.04.
package XML::Compile::Schema::XmlReader;
use vars '$VERSION';
$VERSION = '0.82';


use strict;
use warnings;
no warnings 'once';

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util qw/first/;

use XML::Compile::Util qw/pack_type odd_elements block_label type_of_node/;
use XML::Compile::Iterator ();


# Each action implementation returns a code reference, which will be
# used to do the run-time work.  The mechanism of `closures' is used to
# keep the important information.  Be sure that you understand closures
# before you attempt to change anything.

# The returned reader subroutines will always be called
#      my @pairs = $reader->($tree);

# Some error messages are labeled with 'misfit' which is used to indicate
# that the structure of found data is not conforming the needs. For optional
# blocks, these errors are caught and un-done.

sub tag_unqualified
{   my $name = $_[3];
    $name =~ s/.*?\://;   # strip prefix, that's all
    $name;
}
*tag_qualified = \&tag_unqualified;

sub typemap_to_hooks($$)
{   my ($hooks, $typemap) = @_;
    while(my($type, $action) = each %$typemap)
    {   defined $action or next;
        my $hook;
        if(!ref $action)
        {   my $class = $action;
            no strict 'refs';
            keys %{$class.'::'}
                or error __x"class {pkg} for typemap {type} is not loaded"
                     , pkg => $class, type => $type;

            $class->can('fromXML')
                or error __x"class {pkg} does not implement fromXML(), required for typemap {type}"
                     , pkg => $class, type => $type;

            trace "created reader hook for type $type to class $class";
            $hook = sub { $class->fromXML($_[1], $type) };
        }
        elsif(ref $action eq 'CODE')
        {   $hook = sub { $action->(READER => $_[1], $type) };
            trace "created reader hook for type $type to CODE";
        }
        else
        {   my $object = $action;
            $object->can('fromXML')
                or error __x"object of class {pkg} does not implement fromXML(), required for typemap {type}"
                     , pkg => ref($object), type => $type;

            trace "created reader hook for type $type to object";
            $hook = sub {$object->fromXML($_[1], $type)};
        }

        push @$hooks, { type => $type, after => $hook };
    }
    $hooks;
}

sub element_wrapper
{   my ($path, $args, $processor) = @_;
    # no copy of $_[0], because it may be a large string
    sub { my $tree;
          if(ref $_[0] && UNIVERSAL::isa($_[0], 'XML::LibXML::Iterator'))
          {   $tree = $_[0];
          }
          else
          {   my $xml = XML::Compile->dataToXML($_[0])
                  or return ();
              $xml    = $xml->documentElement
                  if $xml->isa('XML::LibXML::Document');
              $tree   = XML::Compile::Iterator->new($xml, 'top',
                  sub { $_[0]->isa('XML::LibXML::Element') } );
          }

          ($processor->($tree))[-1];
        };
}

sub attribute_wrapper
{   my ($path, $args, $processor) = @_;

    sub { my $attr = shift;
          ref $attr && $attr->isa('XML::LibXML::Attr')
              or error __x"expects an attribute node, but got `{something}' at {path}"
                   , something => (ref $attr || $attr), path => $path;

          my $node = XML::LibXML::Element->new('dummy');
          $node->addChild($attr);

          $processor->($node);
        };
}

sub wrapper_ns        # no namespaces in the HASH
{   my ($path, $args, $processor, $index) = @_;
    $processor;
}

#
## Element
#

sub sequence($@)
{   my ($path, $args, @pairs) = @_;
    if(@pairs==2 && !ref $pairs[1])
    {   my ($take, $action) = @pairs;
        return bless
        sub { my $tree = shift;
              $action->($tree && $tree->currentLocal eq $take ? $tree : undef);
            }, 'BLOCK';
    }

    bless
    sub { my $tree = shift;
          my @res;
          my @do = @pairs;
          while(@do)
          {   my ($take, $do) = (shift @do, shift @do);
              push @res, ref $do eq 'BLOCK'
                      || ref $do eq 'ANY'
                      || ! defined $tree
                      || $tree->currentLocal eq $take
                       ? $do->($tree) : $do->(undef);
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

    if(keys %do==1 && !@specials)
    {   my ($option, $action) = %do;
        return bless
        sub { my $tree  = shift;
              my $local = defined $tree  ? $tree->currentLocal : '';
              return $action->($tree)
                  if $local eq $option;

              try { $action->(undef) };  # minOccurs=0
              $@ or return ();

              $local
                 or error __x"element `{tag}' expected for choice at {path}"
                   , tag => $option, path => $path, _class => 'misfit';

              error __x"single choice option `{option}' for `{tag}' at {path}"
                , option => $option, tag => $local, path => $path
                , _class => 'misfit';
         }, 'BLOCK';
    }

    @specials or return bless
    sub { my $tree  = shift;
          my $local = defined $tree  ? $tree->currentLocal : undef;
          my $elem  = defined $local ? $do{$local} : undef;
          return $elem->($tree) if $elem;

          # very silly situation: some people use a minOccurs within
          # a choice, instead on choice itself.  That always succeeds.
          foreach my $some (values %do)
          {   try { $some->(undef) };
              $@ or return ();
          }

          $local
              or error __x"no element left to pick choice at {path}"
                   , path => $path, _class => 'misfit';

          trace "choose element from @{[sort keys %do]}";

          error __x"no applicable choice for `{tag}' at {path}"
            , tag => $local, path => $path, _class => 'misfit';
    }, 'BLOCK';

    return bless
    sub { my $tree  = shift;
          my $local = defined $tree  ? $tree->currentLocal : undef;
          my $elem  = defined $local ? $do{$local} : undef;
          return $elem->($tree) if $elem;

          my @special_errors;
          foreach (@specials)
          {   my @d = try { $_->($tree) };
              $@ or return @d;
              push @special_errors, $@->wasFatal->message;
          }

          foreach my $some (values %do, @specials)
          {   try { $some->(undef) };
              $@ or return ();
          }

          $local
              or error __x"choice needs more elements at {path}"
                   , path => $path, _class => 'misfit';

          my @elems = sort keys %do;
          trace "choose element from @elems or fix special" if @elems;
          trace "failed specials in choice: $_" for @special_errors;

          error __x"no applicable choice for `{tag}' at {path}"
            , tag => $local, path => $path, _class => 'misfit';
    }, 'BLOCK';
}

sub all($@)
{   my ($path, $args, %pairs) = @_;
    my %specials;
    foreach my $el (keys %pairs)
    {   $specials{$el} = delete $pairs{$el}
            if ref $pairs{$el} eq 'BLOCK' || ref $pairs{$el} eq 'ANY';
    }

    if(!%specials && keys %pairs==1)
    {   my ($take, $do) = %pairs;
        return bless
        sub { my $tree = shift;
              $do->($tree && $tree->currentLocal eq $take ? $tree : undef);
            }, 'BLOCK';
    }

    keys %specials or return bless
    sub { my $tree = shift;
          my %do   = %pairs;
          my @res;
          while(1)
          {   my $local = $tree && $tree->currentLocal or last;
              my $do    = delete $do{$local}  or last; # already seen?
              push @res, $do->($tree);
          }

          # saw all of all?
          push @res, $_->(undef)
              for values %do;

          @res;
        }, 'BLOCK';

    # an 'all' block with nested structures or any is quite nasty.  Don't
    # forget that 'all' can have maxOccurs > 1 !
    bless
    sub { my $tree = shift;
          my %do   = %pairs;
          my %spseen;
          my @res;
       PARTICLE:
          while(1)
          {   my $local = $tree->currentLocal or last;
              if(my $do = delete $do{$local})
              {   push @res, $do->($tree);
                  next PARTICLE;
              }

              foreach (keys %specials)
              {   next if $spseen{$_};
                  my @d = try { $specials{$_}->($tree) };
                  next if $@;

                  $spseen{$_}++;
                  push @res, @d;
                  next PARTICLE;
              }

              last;
          }
          @res or return ();

          # saw all of all?
          push @res, $_->(undef)
              for values %do;

          push @res, $_->(undef)
              for map {$spseen{$_} ? () : $specials{$_}} keys %specials;

          @res;
        }, 'BLOCK';
}

sub block_handler
{   my ($path, $args, $label, $min, $max, $process, $kind) = @_;
    my $multi = block_label $kind, $label;

    # flatten the HASH: when a block appears only once, there will
    # not be an additional nesting in the output tree.
    if($max ne 'unbounded' && $max==1)
    {   return ($label => $process) if $min==1;
        my $code =      # $min==0
        sub { my $tree    = shift or return ();
              my $starter = $tree->currentChild or return;
              my @pairs   = try { $process->($tree) };
              if($@->wasFatal(class => 'misfit'))
              {   # error is ok, if nothing consumed
                  my $ending = $tree->currentChild;
                  $@->reportAll if !$ending || $ending!=$starter;
                  return ();
              }
              elsif($@) {$@->reportAll};

              @pairs;
            };
         return ($label => bless($code, 'BLOCK'));
    }

    if($max ne 'unbounded' && $min>=$max)
    {   my $code =
        sub { my $tree = shift;
              my @res;
              while(@res < $min)
              {   my @pairs = $process->($tree);
                  push @res, {@pairs};
              }
              ($multi => \@res);
            };
         return ($label => bless($code, 'BLOCK'));
    }

    if($min==0)
    {   my $code =
        sub { my $tree = shift or return ();
              my @res;
              while($max eq 'unbounded' || @res < $max)
              {   my $starter = $tree->currentChild or last;
                  my @pairs   = try { $process->($tree) };
                  if($@->wasFatal(class => 'misfit'))
                  {   # misfit error is ok, if nothing consumed
                      my $ending = $tree->currentChild;
                      $@->reportAll if !$ending || $ending!=$starter;
                      last;
                  }
                  elsif($@) {$@->reportAll}

                  @pairs or last;
                  push @res, {@pairs};
              }

              @res ? ($multi => \@res) : ();
            };
         return ($label => bless($code, 'BLOCK'));
    }

    my $code =
    sub { my $tree = shift or error __xn
             "block with `{name}' is required at least once at {path}"
           , "block with `{name}' is required at least {_count} times at {path}"
           , $min, name => $label, path => $path;

          my @res;
          while(@res < $min)
          {   my @pairs = $process->($tree);
              push @res, {@pairs};
          }
          while($max eq 'unbounded' || @res < $max)
          {   my $starter = $tree->currentChild or last;
              my @pairs   = try { $process->($tree) };
              if($@->wasFatal(class => 'misfit'))
              {   # misfit error is ok, if nothing consumed
                  my $ending = $tree->currentChild;
                  $@->reportAll if !$ending || $ending!=$starter;
                  last;
              }
              elsif($@) {$@->reportAll};

              @pairs or last;
              push @res, {@pairs};
          }
          ($multi => \@res);
        };

    ($label => bless($code, 'BLOCK'));
}

sub element_handler
{   my ($path, $args, $label, $min, $max, $required, $optional) = @_;
    $max eq "0" and return sub {};

    if($max ne 'unbounded' && $max==1)
    {   return $min==1
        ? sub { my $tree  = shift;
                my @pairs = $required->(defined $tree ? $tree->descend :undef);
                $tree->nextChild if defined $tree;
                ($label => $pairs[1]);
              }
        : sub { my $tree  = shift or return ();
                $tree->currentChild or return ();
                my @pairs = $optional->($tree->descend);
                @pairs or return ();
                $tree->nextChild;
                ($label => $pairs[1]);
              };
    }
        
    if($max ne 'unbounded' && $min>=$max)
    {   return
        sub { my $tree = shift;
              my @res;
              while(@res < $min)
              {   my @pairs = $required->(defined $tree ? $tree->descend:undef);
                  push @res, $pairs[1];
                  $tree->nextChild if defined $tree;
              }
              @res ? ($label => \@res) : ();
            };
    }

    if(!defined $required)
    {   return
        sub { my $tree = shift or return ();
              my @res;
              while($max eq 'unbounded' || @res < $max)
              {   $tree->currentChild or last;
                  my @pairs = $optional->($tree->descend);
                  @pairs or last;
                  push @res, $pairs[1];
                  $tree->nextChild;
              }
              @res ? ($label => \@res) : ();
            };
    }

    sub { my $tree = shift;
          my @res;
          while(@res < $min)
          {   my @pairs = $required->(defined $tree ? $tree->descend : undef);
              push @res, $pairs[1];
              $tree->nextChild if defined $tree;
          }
          while(defined $tree && ($max eq 'unbounded' || @res < $max))
          {   $tree->currentChild or last;
              my @pairs = $optional->($tree->descend);
              @pairs or last;
              push @res, $pairs[1];
              $tree->nextChild;
          }
          ($label => \@res);
        };
}

sub required
{   my ($path, $args, $label, $do) = @_;
    my $req =
    sub { my $tree  = shift;  # can be undef
          my @pairs = $do->($tree);
          @pairs
              or error __x"data for element or block starting with `{tag}' missing at {path}"
                     , tag => $label, path => $path, _class => 'misfit';
          @pairs;
        };
    ref $do eq 'BLOCK' ? bless($req, 'BLOCK') : $req;
}

sub element_href
{   my ($path, $args, $ns, $childname, $do) = @_;

    sub { my $tree  = shift;
          return ($childname => $tree->node)
              if defined $tree
              && $tree->nodeLocal eq $childname
              && $tree->node->hasAttribute('href');

          $do->($tree);
        };
}

sub element
{   my ($path, $args, $ns, $childname, $do) = @_;

    sub { my $tree  = shift;
          my $value = defined $tree && $tree->nodeLocal eq $childname
             ? $do->($tree) : $do->(undef);
          defined $value ? ($childname => $value) : ();
        };
}

sub element_default
{   my ($path, $args, $ns, $childname, $do, $default) = @_;
    my $def  = $do->($default);

    sub { my $tree = shift;
          defined $tree && $tree->nodeLocal eq $childname
              or return ($childname => $def);
          $do->($tree);
        };
}

sub element_fixed
{   my ($path, $args, $ns, $childname, $do, $fixed) = @_;
    my $fix  = $do->($fixed);

    sub { my $tree = shift;
          my ($label, $value)
            = $tree && $tree->nodeLocal eq $childname ? $do->($tree) : ();

          defined $value
              or error __x"element `{name}' with fixed value `{fixed}' missing at {path}"
                     , name => $childname, fixed => $fix, path => $path;

          $value eq $fix
              or error __x"element `{name}' must have fixed value `{fixed}', got `{value}' at {path}"
                     , name => $childname, fixed => $fix, value => $value
                     , path => $path;

          ($label => $value);
        };
}

sub element_nillable
{   my ($path, $args, $ns, $childname, $do) = @_;

    # some people cannot read the specs.
    my $inas = $args->{interpret_nillable_as_optional};

    sub { my $tree = shift;
          my $value;
          if(defined $tree && $tree->nodeLocal eq $childname)
          {   my $nil  = $tree->node->getAttribute('nil') || 'false';
              return ($childname => 'NIL')
                  if $nil eq 'true' || $nil eq '1';
              $value = $do->($tree);
          }
          elsif($inas) { return ($childname => undef) }
          else { $value = $do->(undef) }

          defined $value ? ($childname => $value) : ();
        };
}

#
# complexType and complexType/ComplexContent
#

sub complex_element
{   my ($path, $args, $tag, $elems, $attrs, $attrs_any) = @_;
    my @elems = odd_elements @$elems;
    my @attrs = (odd_elements(@$attrs), @$attrs_any);

    sub { my $tree    = shift or return ();
          my $node    = $tree->node;
          my %complex
           = ( (map {$_->($tree)} @elems)
             , (map {$_->($node)} @attrs)
             );

          defined $tree->currentChild
              and error __x"element `{name}' not processed at {path}"
                      , name => $tree->currentLocal, path => $path
                      , _class => 'misfit';

          ($tag => \%complex);
        };
}

#
# complexType/simpleContent
#

sub tagged_element
{   my ($path, $args, $tag, $st, $attrs, $attrs_any) = @_;
    my @attrs = (odd_elements(@$attrs), @$attrs_any);

    sub { my $tree   = shift or return ();
          my $simple = $st->($tree);
          my $node   = $tree->node;
          my @pairs  = map {$_->($node)} @attrs;
          defined $simple or @pairs or return ();
          defined $simple or $simple = 'undef';
          ($tag => {_ => $simple, @pairs});
        };
}

#
# complexType mixed or complexContent mixed
#

sub mixed_element
{   my ($path, $args, $tag, $attrs, $attrs_any) = @_;
    my @attrs = (odd_elements(@$attrs), @$attrs_any);

    @attrs
    ? sub { my $tree   = shift or return ();
            my $node   = $tree->node;
            my @pairs  = map {$_->($node)} @attrs;
            ($tag => {_ => $node, @pairs});
          }
    : sub { my $tree   = shift;
            $tree ? ($tag => $tree->node) : ();
          };
}

#
# simpleType
#

sub simple_element
{   my ($path, $args, $tag, $st) = @_;
    sub { my $value = $st->(@_);
          defined $value ? ($tag => $value) : ();
        };
}

sub builtin
{   my ($path, $args, $node, $type, $def, $check_values) = @_;
    my $check = $check_values ? $def->{check} : undef;
    my $parse = $def->{parse};
    my $err   = $path eq $type
      ? N__"illegal value `{value}' for type {type}"
      : N__"illegal value `{value}' for type {type} at {path}";

    $check
    ? ( defined $parse
      ? sub { my $value = ref $_[0] ? $_[0]->textContent : $_[0];
              defined $value or return undef;
              return $parse->($value, $_[0])
                  if $check->($value);
              error __x$err, value => $value, type => $type, path => $path;
            }
      : sub { my $value = ref $_[0] ? $_[0]->textContent : $_[0];
              defined $value or return undef;
              return $value if $check->($value);
              error __x$err, value => $value, type => $type, path => $path;
            }
      )

    : ( defined $parse
      ? sub { my $value = ref $_[0] ? shift->textContent : $_[0];
              defined $value or return undef;
              $parse->($value);
            }
      : sub { ref $_[0] ? shift->textContent : $_[0] }
      );
}

# simpleType

sub list
{   my ($path, $args, $st) = @_;
    sub { my $tree = shift or return undef;
          my $v = $tree->textContent;
          my @v = grep {defined} map {$st->($_)} split(" ",$v);
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
              push @r, $e if defined $e;
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
{   my ($path, $args, @types) = @_;
    sub { my $tree = shift or return undef;
          for(@types) { my $v = try { $_->($tree) }; $@ or return $v }
          my $text = $tree->textContent;

          substr $text, 20, -1, '...' if length($text) > 73;
          error __x"no match for `{text}' in union at {path}"
             , text => $text, path => $path;
        };
}

# Attributes

sub attribute_required
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          defined $node
             or error __x"attribute `{name}' is required at {path}"
                    , name => $tag, path => $path;

          defined $node or return ();
          my $value = $do->($node);
          defined $value ? ($tag => $value) : ();
        };
}

sub attribute_prohibited
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          defined $node or return ();
          error __x"attribute `{name}' is prohibited at {path}"
              , name => $tag, path => $path;
          ();
        };
}

sub attribute
{   my ($path, $args, $ns, $tag, $do) = @_;
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          defined $node or return ();;
          my $val = $do->($node);
          defined $val ? ($tag => $val) : ();
        };
}

sub attribute_default
{   my ($path, $args, $ns, $tag, $do, $default) = @_;
    my $def  = $do->($default);

    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          ($tag => (defined $node ? $do->($node) : $def))
        };
}

sub attribute_fixed
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    my $def  = $do->($fixed);

    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          my $value = defined $node ? $do->($node) : undef;

          defined $value && $value eq $def
              or error __x"value of attribute `{tag}' is fixed to `{fixed}', not `{value}' at {path}"
                  , tag => $tag, fixed => $def, value => $value, path => $path;

          ($tag => $def);
        };
}

sub attribute_fixed_optional
{   my ($path, $args, $ns, $tag, $do, $fixed) = @_;
    my $def  = $do->($fixed);

    sub { my $node  = $_[0]->getAttributeNodeNS($ns, $tag)
              or return ($tag => $def);

          my $value = $do->($node);
          defined $value && $value eq $def
              or error __x"value of attribute `{tag}' is fixed to `{fixed}', not `{value}' at {path}"
                  , tag => $tag, fixed => $def, value => $value, path => $path;

          ($tag => $def);
        };
}

# SubstitutionGroups

sub substgroup
{   my ($path, $args, $type, %do) = @_;

    bless
    sub { my $tree  = shift;
          my $local = ($tree ? $tree->currentLocal : undef)
              or error __x"no data for substitution group {type} at {path}"
                    , type => $type, path => $path;

          my $do    = $do{$local}
              or return;

          my @subst = $do->($tree->descend);
          $tree->nextChild;
          @subst;
        }, 'BLOCK';
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
              my $ns = $attr->namespaceURI || $_[0]->namespaceURI || '';
              next if keys %yes && !$yes{$ns};
              next if keys %no  &&   $no{$ns};

              push @result, pack_type($ns, $attr->localName) => $attr;
          }
          @result;
        };

    # Create filter if requested
    my $run = $handler eq 'TAKE_ALL'
    ? $all
    : sub { my @attrs = $all->(@_);
            my @result;
            while(@attrs)
            {   my ($type, $data) = (shift @attrs, shift @attrs);
                my ($label, $out) = $handler->($type, $data, $path, $args);
                push @result, $label, $out if defined $label;
            }
            @result;
          };

     bless $run, 'ANY';
}

# anyElement

sub anyElement
{   my ($path, $args, $handler, $yes, $no, $process, $min, $max) = @_;
    $handler ||= 'SKIP_ALL';

    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    # Takes all, before filtering
    my $all = bless
    sub { my $tree  = shift or return ();
          my $count = 0;
          my %result;
          while(   (my $child = $tree->currentChild)
                && ($max eq 'unbounded' || $count < $max))
          {   my $ns = $child->namespaceURI || '';
              $yes{$ns} or last if keys %yes;
              $no{$ns} and last if keys %no;

              my $k = pack_type $ns, $child->localName;
              push @{$result{$k}}, $child;

              $count++;
              $tree->nextChild;
          }

          $count >= $min
              or error __x"too few any elements, requires {min} and got {found}"
                    , min => $min, found => $count;
          %result;
        }, 'ANY';

    # Create filter if requested
    my $run
     = $handler eq 'TAKE_ALL' ? $all
     : $handler eq 'SKIP_ALL' ? sub { $all->(@_); () }
     : sub { my @elems = $all->(@_);
             my @result;
             while(@elems)
             {   my ($type, $data) = (shift @elems, shift @elems);
                 my ($label, $out) = $handler->($type, $data, $path, $args);
                 push @result, $label, $out if defined $label;
             }
             @result;
           };

     bless $run, 'ANY';
}

# any kind of hook

sub hook($$$$$$)
{   my ($path, $args, $r, $tag, $before, $replace, $after) = @_;
    return $r unless $before || $replace || $after;

    return sub { ($_[0]->node->localName => 'SKIPPED') }
        if $replace && grep {$_ eq 'SKIP'} @$replace;

    my @replace = $replace ? map {_decode_replace($path,$_)} @$replace : ();
    my @before  = $before  ? map {_decode_before($path,$_) } @$before  : ();
    my @after   = $after   ? map {_decode_after($path,$_)  } @$after   : ();

    sub
     { my $tree = shift or return ();
       my $xml  = $tree->node;
       foreach (@before)
       {   $xml = $_->($xml, $path);
           defined $xml or return ();
       }
       my @h = @replace
             ? map {$_->($xml,$args,$path,$tag)} @replace
             : $r->($tree->descend($xml));
       @h or return ();
       my $h = @h==1 ? {_ => $h[0]} : $h[1];  # detect simpleType
       foreach my $after (@after)
       {   $h = $after->($xml, $h, $path);
           defined $h or return ();
       }
       $h;
     }
}

sub _decode_before($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub {print "$_[1]\n"; $_[0] }
    : error __x"labeled before hook `{call}' undefined", call => $call;
}

sub _decode_replace($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

    error __x"labeled replace hook `{call}' undefined", call => $call;
}

sub _decode_after($$)
{   my ($path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub {print "$_[2]\n"; $_[1] }
    : $call eq 'XML_NODE'  ?
      sub { my $h = $_[1];
            ref $h eq 'HASH' or $h = { _ => $h };
            $h->{_XML_NODE} = $_[0];
            $h;
          }
    : $call eq 'ELEMENT_ORDER' ?
      sub { my ($xml, $h) = @_;
            ref $h eq 'HASH' or $h = { _ => $h };
            my @order = map {type_of_node $_}
                grep { $_->isa('XML::LibXML::Element') }
                    $xml->childNodes;
            $h->{_ELEMENT_ORDER} = \@order;
            $h;
          }
    : $call eq 'ATTRIBUTE_ORDER' ?
      sub { my ($xml, $h) = @_;
            ref $h eq 'HASH' or $h = { _ => $h };
            my @order = map {$_->nodeName} $xml->attributes;
            $h->{_ATTRIBUTE_ORDER} = \@order;
            $h;
          }
    : error __x"labeled after hook `{call}' undefined", call => $call;
}


1;
