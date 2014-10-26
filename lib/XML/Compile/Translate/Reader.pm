package XML::Compile::Translate::Reader;
use base 'XML::Compile::Translate';

use strict;
use warnings;
no warnings 'once';

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util qw/first/;

use XML::Compile::Util qw/pack_type odd_elements type_of_node/;
use XML::Compile::Iterator ();

=chapter NAME

XML::Compile::Translate::Reader - translate XML to HASH

=chapter SYNOPSIS

 my $schema = XML::Compile::Schema->new(...);
 my $code   = $schema->compile(READER => ...);

=chapter DESCRIPTION
The translator understands schemas, but does not encode that into
actions.  This module implements those actions to translate from XML
into a (nested) Perl HASH structure.

=chapter METHODS

=cut

# Each action implementation returns a code reference, which will be
# used to do the run-time work.  The mechanism of `closures' is used to
# keep the important information.  Be sure that you understand closures
# before you attempt to change anything.

# The returned reader subroutines will always be called
#      my @pairs = $reader->($tree);

# Some error messages are labeled with 'misfit' which is used to indicate
# that the structure of found data is not conforming the needs. For optional
# blocks, these errors are caught and un-done.

sub actsAs($) { $_[1] eq 'READER' }

sub makeTagUnqualified
{   my ($self, $path, $node, $local, $ns) = @_;
    $local =~ s/.*?\://;   # strip prefix, that's all
    $local;
}
*makeTagQualified = \&makeTagUnqualified;

sub typemapToHooks($$)
{   my ($self, $hooks, $typemap) = @_;
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

sub makeElementWrapper
{   my ($self, $path, $processor) = @_;
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

sub makeAttributeWrapper
{   my ($self, $path, $processor) = @_;

    sub { my $attr = shift;
          ref $attr && $attr->isa('XML::LibXML::Attr')
              or error __x"expects an attribute node, but got `{something}' at {path}"
                   , something => (ref $attr || $attr), path => $path;

          my $node = XML::LibXML::Element->new('dummy');
          $node->addChild($attr);

          $processor->($node);
        };
}

sub makeWrapperNs        # no namespaces in the HASH
{   my ($self, $path, $processor, $index) = @_;
    $processor;
}

#
## Element
#

sub makeSequence($@)
{   my ($self, $path, @pairs) = @_;
    if(@pairs==2)
    {   my ($take, $action) = @pairs;
        my $code
         = (ref $action eq 'BLOCK' || ref $action eq 'ANY')
         ? sub { $action->($_[0])}
         : sub { $action->($_[0] && $_[0]->currentType eq $take ? $_[0]:undef)};
        return bless $code, 'BLOCK';
    }

    bless
    sub { my $tree = shift;
          my @res;
          my @do = @pairs;
          while(@do)
          {   my ($take, $do) = (shift @do, shift @do);
              push @res, ref $do eq 'BLOCK'
                      || ref $do eq 'ANY'
                      || (defined $tree && $tree->currentType eq $take)
                       ? $do->($tree) : $do->(undef);
          }

          @res;
        }, 'BLOCK';
}

sub makeChoice($@)
{   my ($self, $path, %do) = @_;
    my @specials;
    foreach my $el (keys %do)
    {   push @specials, delete $do{$el}
            if ref $do{$el} eq 'BLOCK' || ref $do{$el} eq 'ANY';
    }

    if(keys %do==1 && !@specials)
    {   my ($option, $action) = %do;
        return bless
        sub { my $tree = shift;
              my $type = defined $tree ? $tree->currentType : '';
              return $action->($tree)
                  if $type eq $option;

              try { $action->(undef) };  # minOccurs=0
              $@ or return ();

              $type
                  or error __x"element `{tag}' expected for choice at {path}"
                       , tag => $option, path => $path, _class => 'misfit';

              error __x"single choice option `{option}' at `{type}' at {path}"
                , option => $option, type => $type, path => $path
                , _class => 'misfit';
         }, 'BLOCK';
    }

    @specials or return bless
    sub { my $tree = shift;
          my $type = defined $tree ? $tree->currentType : undef;
          my $elem = defined $type ? $do{$type} : undef;
          return $elem->($tree) if $elem;

          # very silly situation: some people use a minOccurs within
          # a choice, instead on choice itself.  That always succeeds.
          foreach my $some (values %do)
          {   try { $some->(undef) };
              $@ or return;
          }

          $type
              or error __x"no element left to pick choice at {path}"
                   , path => $path, _class => 'misfit';

          trace "choose element from @{[sort keys %do]}";
          error __x"no applicable choice for `{tag}' at {path}"
            , tag => $type, path => $path, _class => 'misfit';
    }, 'BLOCK';

    return bless
    sub { my $tree = shift;
          my $type = defined $tree ? $tree->currentType : undef;
          my $elem = defined $type ? $do{$type} : undef;
          return $elem->($tree) if $elem;

          my @special_errors;
          foreach (@specials)
          {
              my @d = try { $_->($tree) };
              return @d if !$@ && @d;
              push @special_errors, $@->wasFatal->message if $@;
          }

          foreach my $some (values %do, @specials)
          {   try { $some->(undef) };
              $@ or return ();
          }

          $type
              or error __x"choice needs more elements at {path}"
                   , path => $path, _class => 'misfit';

          my @elems = sort keys %do;
          trace "choose element from @elems or fix special" if @elems;
          trace "failed specials in choice: $_" for @special_errors;

          error __x"no applicable choice for `{tag}' at {path}"
            , tag => $type, path => $path, _class => 'misfit';
    }, 'BLOCK';
}

sub makeAll($@)
{   my ($self, $path, %pairs) = @_;
    my %specials;
    foreach my $el (keys %pairs)
    {   $specials{$el} = delete $pairs{$el}
            if ref $pairs{$el} eq 'BLOCK' || ref $pairs{$el} eq 'ANY';
    }

    if(!%specials && keys %pairs==1)
    {   my ($take, $do) = %pairs;
        return bless
        sub { my $tree = shift;
              $do->($tree && $tree->currentType eq $take ? $tree : undef);
            }, 'BLOCK';
    }

    keys %specials or return bless
    sub { my $tree = shift;
          my %do   = %pairs;
          my @res;
          while(1)
          {   my $type = $tree && $tree->currentType or last;
              my $do   = delete $do{$type}  or last; # already seen?
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
          {   my $type = $tree->currentType or last;
              if(my $do = delete $do{$type})
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

sub makeBlockHandler
{   my ($self, $path, $label, $min, $max, $process, $kind, $multi) = @_;

    # flatten the HASH: when a block appears only once, there will
    # not be an additional nesting in the output tree.
    if($max ne 'unbounded' && $max==1)
    {
       return ($label => $process) if $min==1;

        my $code =
        sub { my $tree = shift or return ();
              my $starter = $tree->currentChild or return ();
              my @pairs   = try { $process->($tree) };
              if($@->wasFatal(class => 'misfit'))
              {   my $ending = $tree->currentChild;
                  $@->reportAll if !$ending || $ending!=$starter;
                  return ();
              }
              elsif($@) {$@->reportAll}
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
                      trace "misfit $label ($min..$max) ".$@->wasFatal->message;
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
                  trace "misfit $label ($min..) ".$@->wasFatal->message;
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

sub makeElementHandler
{   my ($self, $path, $label, $min, $max, $required, $optional) = @_;
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
                $tree->nextChild;
                @pairs or return ();
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

sub makeRequired
{   my ($self, $path, $label, $do) = @_;

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

sub makeElementHref
{   my ($self, $path, $ns, $childname, $do) = @_;

    sub { my $tree  = shift;
          return ($childname => $tree->node)
              if defined $tree
              && $tree->nodeType eq $childname
              && $tree->node->hasAttribute('href');

          $do->($tree);
        };
}

sub makeElement
{   my ($self, $path, $ns, $childname, $do) = @_;

    sub { my $tree  = shift;
          my $value = defined $tree && $tree->nodeType eq $childname
             ? $do->($tree) : $do->(undef);
          defined $value ? ($childname => $value) : ();
        };
}

sub makeElementDefault
{   my ($self, $path, $ns, $childname, $do, $default) = @_;

    my $mode = $self->{default_values};
    $mode eq 'IGNORE'
       and return sub
        { my $tree = shift or return ();
          return () if $tree->nodeType ne $childname
                    || $tree->node->textContent eq '';
          $do->($tree);
        };

    my $def = $do->($default);

    $mode eq 'EXTEND'
       and return sub
        { my $tree = shift;
          return ($childname => $def)
              if !defined $tree 
              || $tree->nodeType ne $childname
              || $tree->node->textContent eq '';

          $do->($tree);
        };

     $mode eq 'MINIMAL'
        and return sub
        { my $tree = shift or return ();
          return () if $tree->nodeType ne $childname
                    || $tree->node->textContent eq '';
          my $v = $do->($tree);
          undef $v if defined $v && $v eq $def;
          ($childname => $v);
        };

    error __x"illegal default_values mode `{mode}'", mode => $mode;
}

sub makeElementFixed
{   my ($self, $path, $ns, $childname, $do, $fixed) = @_;
    my ($tag, $fix) = $do->($fixed);

    sub { my $tree = shift;
          my ($label, $value)
            = $tree && $tree->nodeType eq $childname ? $do->($tree) : ();

          defined $value
              or return ($tag => $fix);

          $value eq $fix
              or error __x"element `{name}' must have fixed value `{fixed}', got `{value}' at {path}"
                     , name => $childname, fixed => $fix, value => $value
                     , path => $path;

          ($label => $value);
        };
}

sub makeElementNillable
{   my ($self, $path, $ns, $childname, $do) = @_;

    # some people cannot read the specs.
    my $inas = $self->{interpret_nillable_as_optional};

    sub { my $tree = shift;
          my $value;
          if(defined $tree && $tree->nodeType eq $childname)
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

sub makeElementAbstract
{   my ($self, $path, $ns, $childname, $do) = @_;
    sub { my $tree = shift or return ();
          $tree->nodeType eq $childname or return ();

          error __x"abstract element `{name}' used at {path}"
            , name => $childname, path => $path;
        };
}

#
# complexType and complexType/ComplexContent
#

sub makeComplexElement
{   my ($self, $path, $tag, $elems, $attrs, $attrs_any) = @_;
my @e = @$elems;
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
                      , name => $tree->currentType, path => $path
                      , _class => 'misfit';

          ($tag => \%complex);
        };
}

#
# complexType/simpleContent
#

sub makeTaggedElement
{   my ($self, $path, $tag, $st, $attrs, $attrs_any) = @_;
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

sub makeMixedElement
{   my ($self, $path, $tag, $elems, $attrs, $attrs_any) = @_;
    my @attrs = (odd_elements(@$attrs), @$attrs_any);
    my $mixed = $self->{mixed_elements}
         or panic "how to handle mixed?";

      ref $mixed eq 'CODE'
    ? sub { my $tree = shift or return;
            my $node = $tree->node or return;
            my @v = $mixed->($node);
            @v ? ($tag => $v[0]) : ();
          }
    : $mixed eq 'XML_NODE'
    ? sub { $_[0] ? ($tag => $_[0]->node) : () }
    : $mixed eq 'ATTRIBUTES'
    ? sub { my $tree   = shift or return;
            my $node   = $tree->node;
            my @pairs  = map {$_->($node)} @attrs;
            ($tag => {_ => $node, @pairs});
          } 
    : $mixed eq 'TEXTUAL'
    ? sub { my $tree   = shift or return;
            my $node   = $tree->node;
            my @pairs  = map {$_->($node)} @attrs;
            ($tag => {_ => $node->textContent, @pairs});
          } 
    : $mixed eq 'XML_STRING'
    ? sub { my $tree   = shift or return;
            my $node   = $tree->node or return;
            ($tag => $node->toString);
          }
    : $mixed eq 'STRUCTURAL'
    ? panic "mixed structural handled as normal element"
    : error __x"unknown mixed_elements value `{value}'", value => $mixed;
}

#
# simpleType
#

sub makeSimpleElement
{   my ($self, $path, $tag, $st) = @_;
    sub { my $value = $st->(@_);
          defined $value ? ($tag => $value) : ();
        };
}

sub makeBuiltin
{   my ($self, $path, $node, $type, $def, $check_values) = @_;
    my $check = $check_values ? $def->{check} : undef;
    my $parse = $def->{parse};
    my $err   = $path eq $type
      ? N__"illegal value `{value}' for type {type}"
      : N__"illegal value `{value}' for type {type} at {path}";

    $check
    ? ( defined $parse
      ? sub { my $value = ref $_[0] ? $_[0]->textContent : $_[0];
              defined $value or return undef;
              return $parse->($value, $_[1]||$_[0])
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
      ? sub { my $value = ref $_[0] ? $_[0]->textContent : $_[0];
              defined $value or return undef;
              $parse->($value, $_[1]||$_[0]);
            }
      : sub { ref $_[0] ? shift->textContent : $_[0] }
      );
}

# simpleType

sub makeList
{   my ($self, $path, $st) = @_;
    sub { my $tree = shift;
          defined $tree or return undef;
          my $node
             = UNIVERSAL::isa($tree, 'XML::LibXML::Node') ? $tree
             : ref $tree ? $tree->node : undef;
          my $v = ref $tree ? $tree->textContent : $tree;
          my @v = grep {defined} map {$st->($_, $node)} split(" ",$v);
          @v ? \@v : undef;
        };
}

sub makeFacetsList
{   my ($self, $path, $st, $info, $early, $late) = @_;
    sub { defined $_[0] or return undef;
          my $v = $st->(@_);
          my @v;
          if(ref $v eq 'ARRAY') { @v = @$v } # no early limits for extension
          else
          {   for(@$early) { defined $v or return (); $v = $_->($v) }
              @v = defined $v ? split(" ",$v) : ();
          }
          my @r;
      EL: for my $e (@v)
          {   for(@$late) { defined $e or next EL; $e = $_->($e) }
              push @r, $e if defined $e;
          }
          @r ? \@r : ();
        };
}

sub makeFacets
{   my ($self, $path, $st, $info, @do) = @_;
    sub { defined $_[0] or return undef;
          my $v = $st->(@_);
          for(@do) { defined $v or return (); $v = $_->($v) }
          $v;
        };
}

sub makeUnion
{   my ($self, $path, @types) = @_;
    sub { my $tree = shift or return undef;
          for(@types) { my $v = try { $_->($tree) }; $@ or return $v }
          my $text = $tree->textContent;

          substr $text, 20, -1, '...' if length($text) > 73;
          error __x"no match for `{text}' in union at {path}"
             , text => $text, path => $path;
        };
}

# Attributes

sub makeAttributeRequired
{   my ($self, $path, $ns, $tag, $do) = @_;
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          defined $node
             or error __x"attribute `{name}' is required at {path}"
                    , name => $tag, path => $path;

          defined $node or return ();
          my $value = $do->($node);
          defined $value ? ($tag => $value) : ();
        };
}

sub makeAttributeProhibited
{   my ($self, $path, $ns, $tag, $do) = @_;
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          defined $node or return ();
          error __x"attribute `{name}' is prohibited at {path}"
              , name => $tag, path => $path;
          ();
        };
}

sub makeAttribute
{   my ($self, $path, $ns, $tag, $do) = @_;
    sub { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
          defined $node or return ();;
          my $val = $do->($node);
          defined $val ? ($tag => $val) : ();
        };
}

sub makeAttributeDefault
{   my ($self, $path, $ns, $tag, $do, $default) = @_;

    my $mode = $self->{default_values};
    $mode eq 'IGNORE'
        and return sub
          { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
            defined $node ? ($tag => $do->($node)) : () };

    my $def = $do->($default);

    $mode eq 'EXTEND'
        and return sub
          { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
            ($tag => ($node ? $do->($node) : $def))
          };

    $mode eq 'MINIMAL'
        and return sub
          { my $node = $_[0]->getAttributeNodeNS($ns, $tag);
            my $v = $node ? $do->($node) : $def;
            !defined $v || $v eq $def ? () : ($tag => $v);
          };

    error __x"illegal default_values mode `{mode}'", mode => $mode;
}

sub makeAttributeFixed
{   my ($self, $path, $ns, $tag, $do, $fixed) = @_;
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

sub makeSubstgroup
{   my ($self, $path, $base, %do) = @_;
    keys %do or return bless sub { () }, 'BLOCK';

    bless
    sub { my $tree = shift;
          my $type = ($tree ? $tree->currentType : undef)
              or error __x"no data for substitution group {type} at {path}"
                    , type => $base, path => $path;

          my $do   = $do{$type}
              or return;

          my @subst = $do->[1]($tree->descend);
          $tree->nextChild;
          @subst ? ($do->[0] => $subst[1]) : ();   # rewrite
        }, 'BLOCK';
}

# anyAttribute

sub makeAnyAttribute
{   my ($self, $path, $handler, $yes, $no, $process) = @_;
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
    my $run = $handler eq 'TAKE_ALL' ? $all
    : ref $handler ne 'CODE'
    ? error(__x"any_attribute handler `{got}' not understood", got => $handler)
    : sub { my @attrs = $all->(@_);
            my @result;
            while(@attrs)
            {   my ($type, $data) = (shift @attrs, shift @attrs);
                my ($label, $out) = $handler->($type, $data, $path, $self);
                push @result, $label, $out if defined $label;
            }
            @result;
          };

     bless $run, 'ANY';
}

# anyElement

sub makeAnyElement
{   my ($self, $path, $handler, $yes, $no, $process, $min, $max) = @_;
    $handler ||= 'SKIP_ALL';

    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    # Takes all, before filtering
    my $any = $max eq 'unbounded' || $max > 1
    ? sub
      {
          my $tree  = shift or return ();
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
      }
    : sub
      {   my $tree  = shift or return ();
          my $child = $tree->currentChild
              or return ();

          my $ns = $child->namespaceURI || '';

          (!keys %yes || $yes{$ns}) && !(keys %no && $no{$ns})
              or return ();

          $tree->nextChild;
          (type_of_node($child), $child);
      };
 
    bless $any, 'ANY';

    # Create filter if requested
    my $run
     = $handler eq 'TAKE_ALL' ? $any
     : $handler eq 'SKIP_ALL' ? sub { $any->(@_); () }
     : ref $handler ne 'CODE'
     ? error(__x"any_element handler `{got}' not understood", got => $handler)
     : sub { my @elems = $any->(@_);
             my @result;
             while(@elems)
             {   my ($type, $data) = (shift @elems, shift @elems);
                 my ($label, $out) = $handler->($type, $data, $path, $self);
                 push @result, $label, $out if defined $label;
             }
             @result;
           };

     bless $run, 'ANY';
}

# any kind of hook

sub makeHook($$$$$$)
{   my ($self, $path, $r, $tag, $before, $replace, $after) = @_;
    return $r unless $before || $replace || $after;

    return sub { ($_[0]->node->localName => 'SKIPPED') }
        if $replace && grep {$_ eq 'SKIP'} @$replace;

    my @replace = $replace ? map {$self->_decodeReplace($path,$_)} @$replace:();
    my @before  = $before  ? map {$self->_decodeBefore($path,$_) } @$before :();
    my @after   = $after   ? map {$self->_decodeAfter($path,$_)  } @$after  :();

    sub
     { my $tree = shift or return ();
       my $xml  = $tree->node;
       foreach (@before)
       {   $xml = $_->($xml, $path);
           defined $xml or return ();
       }
       my @h = @replace
             ? map {$_->($xml,$self,$path,$tag)} @replace
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

sub _decodeBefore($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub {print "$_[1]\n"; $_[0] }
    : error __x"labeled before hook `{call}' undefined for READER",call=>$call;
}

sub _decodeReplace($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

    error __x"labeled replace hook `{call}' undefined for READER", call=>$call;
}

sub _decodeAfter($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub {print "$_[2]\n"; $_[1] }
    : $call eq 'XML_NODE'  ?
      sub { my $h = $_[1];
            $h = { _ => $h } if ref $h ne 'HASH';
            $h->{_XML_NODE} = $_[0];
            $h;
          }
    : $call eq 'ELEMENT_ORDER' ?
      sub { my ($xml, $h) = @_;
            $h = { _ => $h } if ref $h ne 'HASH';
            my @order = map {type_of_node $_}
                grep { $_->isa('XML::LibXML::Element') }
                    $xml->childNodes;
            $h->{_ELEMENT_ORDER} = \@order;
            $h;
          }
    : $call eq 'ATTRIBUTE_ORDER' ?
      sub { my ($xml, $h) = @_;
            $h = { _ => $h } if ref $h ne 'HASH';
            my @order = map {$_->nodeName} $xml->attributes;
            $h->{_ATTRIBUTE_ORDER} = \@order;
            $h;
          }
    : error __x"labeled after hook `{call}' undefined for READER", call=> $call;
}

=chapter DETAILS

=section Processing Wildcards

If you want to collect information from the XML structure, which is
permitted by C<any> and C<anyAttribute> specifications in the schema,
you have to implement that yourself.  The problem is C<XML::Compile>
has less knowledge than you about the possible data.

=subsection option any_attribute

By default, the C<anyAttribute> specification is ignored.  When C<TAKE_ALL>
is given, all attributes which are fulfilling the name-space requirement
added to the returned data-structure.  As key, the absolute element name
will be used, with as value the related unparsed XML element.

In the current implementation, if an explicit attribute is also
covered by the name-spaces permitted by the anyAttribute definition,
then it will also appear in that list (and hence the handler will
be called as well).

Use M<XML::Compile::Schema::compile(any_attribute)> to write your
own handler, to influence the behavior.  The handler will be called for
each attribute, and you must return list of pairs of derived information.
When the returned is empty, the attribute data is lost.  The value may
be a complex structure.

=example anyAttribute in a READER
Say your schema looks like this:

 <schema targetNamespace="http://mine"
    xmlns:me="http://mine" ...>
   <element name="el">
     <complexType>
       <attribute name="a" type="xs:int" />
       <anyAttribute namespace="##targetNamespace"
          processContents="lax">
     </complexType>
   </element>
   <simpleType name="non-empty">
     <restriction base="NCName" />
   </simpleType>
 </schema>

Then, in an application, you write:

 my $r = $schema->compile
  ( READER => pack_type('http://mine', 'el')
  , anyAttribute => 'ALL'
  );
 # or lazy: READER => '{http://mine}el'

 my $h = $r->( <<'__XML' );
   <el xmlns:me="http://mine">
     <a>42</a>
     <b type="me:non-empty">
        everything
     </b>
   </el>
 __XML

 use Data::Dumper 'Dumper';
 print Dumper $h;
 __XML__

The output is something like

 $VAR1 =
  { a => 42
  , '{http://mine}a' => ... # XML::LibXML::Node with <a>42</a>
  , '{http://mine}b' => ... # XML::LibXML::Node with <b>everything</b>
  };

You can improve the reader with a callback.  When you know that the
extra attribute is always of type C<non-empty>, then you can do

 my $read = $schema->compile
  ( READER => '{http://mine}el'
  , anyAttribute => \&filter
  );

 my $anyAttRead = $schema->compile
  ( READER => '{http://mine}non-empty'
  );

 sub filter($$$$)
 {   my ($fqn, $xml, $path, $translator) = @_;
     return () if $fqn ne '{http://mine}b';
     (b => $anyAttRead->($xml));
 }

 my $h = $r->( see above );
 print Dumper $h;

Which will result in

 $VAR1 =
  { a => 42
  , b => 'everything'
  };

The filter will be called twice, but return nothing in the first
case.  You can implement any kind of complex processing in the filter.

=subsection option any_element

By default, the C<any> definition in a schema will ignore all elements
from the container which are not used.  Also in this case C<TAKE_ALL>
is required to produce C<any> results.  C<SKIP_ALL> will ignore all
results, although this are being processed for validation needs.

The C<minOccurs> and C<maxOccurs> of C<any> are ignored: the amount of
elements is always unbounded.  Therefore, you will get an array of
elements back per type. 

=section Mixed elements

[available since 0.86]
ComplexType and ComplexContent components can be declared with the
C<<mixed="true">> attribute.  This implies that text is not limited
to the content of containers, but may also be used inbetween elements.
Usually, you will only find ignorable white-space between elements.

In this example, the C<a> container is marked to be mixed:
  <a id="5"> before <b>2</b> after </a>

Often the "mixed" option is bending one of both ways: either the element
is needed as text, or the element should be parsed and the text ignored.
The reader has various options to avoid the need of processing raw
XML::LibXML nodes.

With M<XML::Compile::Schema::compile(mixed_elements)> set to
=over 4

=item ATTRIBUTES  (the default)
a HASH is returned, the attributes are processed.  The node is found
as M<XML::LibXML::Element> with the key '_'.  Above example will
produce
  $r = { id => 5, _ => $xmlnode };

=item TEXTUAL
Like the previous, but now the textual representation of the content is
returned with key '_'.  Above example will produce
  $r = { id => 5, _ => ' before 2 after '};

=item STRUCTURAL
will remove all mixed-in text, and treat the element as normal element.
The example will be transformed into
  $r = { id => 5, b => 2 };

=item XML_NODE
return the M<XML::LibXML::Node> itself.  The example:
  $r = $xmlnode;

=item XML_STRING
return the mixed node as XML string, just as in the source.  Be warned
that it is rather expensive: the string was parsed and then stringified
again, which is costly for large nodes.  Result:
  $r = '<a id="5"> before <b>2</b> after </a>';

=item CODE reference
the reference is called with the M<XML::LibXML::Node> as first argument.
When a value is returned (even undef), then the right tag with the value
will be included in the translators result.  When an empty list is
returned by the code reference, then nothing is returned (which may
result in an error if the element is required according to the schema)
=back

When some of your mixed elements need different behavior from other
elements, then you have to go play with the normal hooks in specific
cases.

=section Schema hooks

=subsection hooks executed before the XML is being processed
The C<before> hooks receives an M<XML::LibXML::Node> object and
the path string.  It must return a new (or same) XML node which
will be used from then on.  You probably can best modify a node
clone, not the original as provided by the user.  When C<undef>
is returned, the whole node will disappear.

This hook offers a predefined C<PRINT_PATH>.

=example to trace the paths
 $schema->addHook(path => qr/./, before => 'PRINT_PATH');

=subsection hooks executed as replacement

Your C<replace> hook should return a list of key-value pairs. To
produce it, it will get the M<XML::LibXML::Element>, the translator settings
as HASH, the path, and the localname.

This hook has a predefined C<SKIP>, which will not process the
found element, but simply return the string "SKIPPED" as value.
This way, a whole tree of unneeded translations can be avoided.

Sometimes, the Schema spec is such a mess, that XML::Compile cannot
automatically translate it.  I have seen cases where confusion
over name-spaces is created: a choice between three elements with
the same name but different types.  Well, in such case you may use
M<XML::LibXML::Simple> to translate a part of your tree.  Simply

 use XML::LibXML::Simple  qw/XMLin/;
 $schema->addHook
   ( type    => ...bad-type-definition...
   , replace =>
       sub { my ($xml, $args, $path, $type) = @_;
             ($type => XMLin($xml, ...));
           }
   );

=subsection hooks for post-processing, after the data is collected

The data is collect, and passed as second argument after the XML node.
The third argument is the path.  Be careful that the collected data
might be a SCALAR (for simpleType).  Return a HASH or a SCALAR.  C<undef>
may work, unless it is the value of a required element you throw awy.

This hook also offers a predefined C<PRINT_PATH>.  Besides, it
has C<XML_NODE>, C<ELEMENT_ORDER>, and C<ATTRIBUTE_ORDER>, which will
result in additional fields in the HASH, respectively containing the
CODE which was processed, the element names, and the attribute names.
The keys start with an underscore C<_>.

=section Typemaps

In a typemap, a relation between an XML element type and a Perl class (or
object) is made.  Each translator back-end will implement this a little
differently.  This section is about how the reader handles typemaps.

=subsection Typemap to Class

Usually, an XML type will be mapped on a Perl class.  The Perl class
implements the C<fromXML> method as constructor.

 $schema->typemap($sometype => 'My::Perl::Class');

 package My::Perl::Class;
 ...
 sub fromXML
 {   my ($class, $data, $xmltype) = @_;
     my $self = $class->new($data);
     ...
     $self;
 }

Your method returns the data which will be included in the result tree
of the reader.  You may return an object, the unmodified C<$data>, or
C<undef>.  When C<undef> is returned, this may fail the schema parser
when the data element is required.

In the simpelest implementation, the class stores its data exactly as
the XML structure:

 package My::Perl::Class;
 sub fromXML
 {   my ($class, $data, $xmltype) = @_;
     bless $data, $class;
 }

 # The same, even shorter:
 sub fromXML { bless $_[1], $_[0] }

=subsection Typemap to Object

An other option is to implement an object factory: one object which creates
other objects.  In this case, the C<$xmltype> parameter can come of use,
to have one object spawning many different other objects.

 my $object = My::Perl::Class->new(...);
 $schema->typemap($sometype => $object);

 package My::Perl::Class;
 sub fromXML
 {   my ($object, $xmltype, $data) = @_;
     return Some::Other::Class->new($data);
 }

This object factory may be a very simple solution when you map XML onto
objects which are not under your control; where there is not way to
add the C<fromXML> method.

=subsection Typemap to CODE

The light version of an object factory works with CODE references.

 $schema->typemap($t1 => \&myhandler);
 sub myhandler
 {   my ($backend, $data, $type) = @_;
     return My::Perl::Class->new($data)
         if $backend eq 'READER';
     $data;
 }

 # shorter
 $schema->typemap($t1 => sub {My::Perl::Class->new($_[1])} );

=subsection Typemap implementation

Internally, the typemap is simply translated into an "after" hook for the
specific type.  After the data was processed via the usual mechanism,
the hook will call method C<fromXML> on the class or object you specified
with the data which was read.  You may still use "before" and "replace"
hooks, if you need them.

Syntactic sugar:

  $schema->typemap($t1 => 'My::Package');
  $schema->typemap($t2 => $object);

is comparible to

  $schema->typemap($t1 => sub {My::Package->fromXML(@_)});
  $schema->typemap($t2 => sub {$object->fromXML(@_)} );

with some extra checks.
=cut

1;
