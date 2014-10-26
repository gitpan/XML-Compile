# Copyrights 2006-2011 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.00.
 
package XML::Compile::Translate::Writer;
use vars '$VERSION';
$VERSION = '1.22';

use base 'XML::Compile::Translate';

use strict;
use warnings;
no warnings 'once';

use Log::Report   qw/xml-compile/;
use List::Util    qw/first/;
use Scalar::Util  qw/blessed/;
use XML::Compile::Util qw/pack_type unpack_type type_of_node SCHEMA2001i
  odd_elements even_elements/;


# Each action implementation returns a code reference, which will be
# used to do the run-time work.  The principle of closures is used to
# keep the important information.  Be sure that you understand closures
# before you attempt to change anything.
#
# The returned writer subroutines will always be called
#       $writer->($doc, $value) 

sub actsAs($) { $_[1] eq 'WRITER' }

sub makeTagQualified
{ # my ($self, $path, $node, $local, $ns) = @_;
  # my $prefix = $self->_registerNSprefix('', $ns, 1);
  # length($prefix) ? "$prefix:$local" : $local;
    my $prefix = $_[0]->_registerNSprefix('', $_[4], 1);
    length($prefix) ? "$prefix:$_[3]" : $_[3];
}

sub makeTagUnqualified
{ # my ($self, $path, $node, $local, $ns) = @_;
  # $local;
    $_[3];
}

sub _typemapClass($$)
{   my ($self, $type, $class) = @_;

    no strict 'refs';
    keys %{$class.'::'}
        or error __x"class {pkg} for typemap {type} is not loaded"
             , pkg => $class, type => $type;

    $class->can('toXML')
        or error __x"class {pkg} does not implement toXML(), required for typemap {type}"
             , pkg => $class, type => $type;

    sub {
        my ($doc, $values, $path) = @_;
        UNIVERSAL::isa($values, $class) ? $values->toXML($type, $doc) : $values;
    };
}

sub _typemapObject($$)
{   my ($self, $type, $object) = @_;

    $object->can('toXML')
        or error __x"object of class {pkg} does not implement toXML(), required for typemap {type}"
             , pkg => ref($object), type => $type;

    sub {
        my ($doc, $values, $path) = @_;
        blessed($values) ? $object->toXML($values, $type, $doc) : $values;
    };
}

sub typemapToHooks($$)
{   my ($self, $hooks, $typemap) = @_;
    while(my($type, $action) = each %$typemap)
    {   defined $action or next;
        my $hook;
        if(!ref $action)
        {   $hook = $self->_typemapClass($type, $action);
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
        {   $hook = $self->_typemapObject($type, $action);
            trace "created reader hook for type $type to object";

        }

        push @$hooks, { type => $type, before => $hook };
    }
    $hooks;
}

sub makeElementWrapper
{   my ($self, $path, $processor) = @_;
    sub {
        my ($doc, $data) = @_;
        UNIVERSAL::isa($doc, 'XML::LibXML::Document')
            or error __x"first argument of call to writer must be an XML::LibXML::Document";

        my $top = $processor->(@_);
        $doc->indexElements;
        $top;
    };
}
*makeAttributeWrapper = \&makeElementWrapper;

sub makeWrapperNs
{   my ($self, $path, $processor, $index, $filter) = @_;
    my @entries;
    $filter = sub {$_[2]} if ref $filter ne 'CODE'; # only the used

    foreach my $entry (sort {$a->{prefix} cmp $b->{prefix}} values %$index)
    {   # ANY components are frustrating this
        $filter->($entry->{uri}, $entry->{prefix}, $entry->{used}) or next;
        push @entries, [ $entry->{uri}, $entry->{prefix} ];
        $entry->{used} = 0;
    }

    @entries or return $processor;

    sub {
        my $node = $processor->(@_) or return ();
        UNIVERSAL::isa($node, 'XML::LibXML::Element')
            or return $node;
        $node->setNamespace(@$_, 0) for @entries;
        $node;
    };
}

sub makeSequence($@)
{   my ($self, $path, @pairs) = @_;

    if(@pairs==2)
    {   my ($take, $do) = @pairs;
        return $do
            if ref $do eq 'BLOCK' || ref $do eq 'ANY';

        return bless sub {
            my ($doc, $values) = @_;
            defined $values or return;
            $do->($doc, delete $values->{$take});
        }, 'BLOCK';
    }
 
    bless sub {
        my ($doc, $values) = @_;
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

sub makeChoice($@)
{   my ($self, $path, %do) = @_;
    my @specials;
    foreach my $el (keys %do)
    {   push @specials, delete $do{$el}
            if ref $do{$el} eq 'BLOCK' || ref $do{$el} eq 'ANY';
    }
 
    if(!@specials && keys %do==1)
    {   my ($take, $do) = %do;
        return bless sub {
            my ($doc, $values) = @_;
            defined $values && defined $values->{$take}
              ? $do->($doc, delete $values->{$take}) : ();
        }, 'BLOCK';
    }

    bless sub {
        my ($doc, $values) = @_;
        defined $values or return ();
        foreach my $take (keys %do)
        {   return $do{$take}->($doc, delete $values->{$take})
                if defined $values->{$take};
        }

        my $starter = keys %$values;
        foreach (@specials)
        {   my @d = try { $_->($doc, $values) };
            if($@->wasFatal(class => 'misfit'))
            {   # misfit error is ok, if nothing consumed
                my $err = $@;
                trace "misfit $path ".$err->wasFatal->message;
                $err->reportAll if $starter != keys %$values;
                next;
            }
            elsif(defined $@) {$@->reportAll}

            return @d;
        }

        # blurk... any element with minOccurs=0 or default?
        foreach (values %do)
        {   my @d = try { $_->($doc, undef) };
            return @d if !$@ && @d;
        }
        foreach (@specials)
        {   my @d = try { $_->($doc, undef) };
            if($@->wasFatal(class => 'misfit'))
            {   $@->reportAll if $starter != keys %$values;
                next;
            }
            elsif(defined $@) {$@->reportAll}
            return @d;
        }

        ();
    }, 'BLOCK';
}

sub makeAll($@)
{   my ($self, $path, @pairs) = @_;

    if(@pairs==2 && !ref $pairs[1])
    {   my ($take, $do) = @pairs;
        return bless sub {
            my ($doc, $values) = @_;
           $do->($doc, delete $values->{$take});
        }, 'BLOCK';
    }

    return bless sub {
        my ($doc, $values) = @_;

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

# see comment BlockHandler: undef means zero but success
sub makeElementHandler
{   my ($self, $path, $label, $min,$max, $required, $optional) = @_;
    $max eq "0" and return sub {};

    if($min==0 && $max eq 'unbounded')
    {   return
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();
              @values ? map {$optional->($doc,$_)} @values : (undef);
            };
    }

    if($max eq 'unbounded')
    {   return
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();
              my @d = ( (map { $required->($doc, shift @values) } 1..$min)
                      , (map { $optional->($doc, $_) } @values) );
              @d ? @d : (undef);
            };
    }

    return sub { my @d = $optional->(@_); @d ? @d : undef }
        if $min==0 && $max==1;

    return $required
        if $min==1 && $max==1;

    sub {
        my ($doc, $values) = @_;
        my @values
          = ref $values eq 'ARRAY' ? @$values : defined $values ? $values : ();

        @values <= $max
            or error "too many elements for `{tag}', max {max} found {nr} at {path}"
                 , tag => $label, max => $max, nr => (scalar @values)
                 , path => $path;

        my @d = map { $required->($doc, shift @values) } 1..$min;
        push @d, $optional->($doc, shift @values)
            while @values && @d < $max;

        @d ? @d : (undef);
    };
}

# To reflect the difference between a block which did not "succeed hence
# produced nothing", and "did succeed by producing nothing" (minOccurs=0)
# the later is represented by an undef value.
sub makeBlockHandler
{   my ($self, $path, $label, $min, $max, $process, $kind, $multi) = @_;

    if($min==0 && $max eq 'unbounded')
    {   my $code = sub {
            my $doc    = shift;
            my $values = delete shift->{$multi};
              ref $values eq 'ARRAY' ? (map {$process->($doc, {%$_})} @$values)
            : defined $values        ? $process->($doc, $values)
            :                          (undef);
        };
        return ($multi, bless($code, 'BLOCK'));
    }

    if($max eq 'unbounded')
    {   my $code = sub {
            my $doc    = shift;
            my $values = delete shift->{$multi};
            my @values = ref $values eq 'ARRAY' ? @$values
                       : defined $values ? $values : ();

            @values >= $min
                or error __x"too few blocks for `{tag}' specified, got {found} need {min} at {path}"
                     , tag => $multi, found => scalar @values
                     , min => $min, path => $path, _class => 'misfit';

            map {$process->($doc, {%$_}) } @values;
        };
        return ($multi, bless($code, 'BLOCK'));
    }

    if($min==0 && $max==1)
    {   my $code = sub {
            my ($doc, $values) = @_;
            my @values = ref $values eq 'ARRAY' ? @$values
                       : defined $values ? $values : ();
            @values <= 1
                or error __x"only one block value for `{tag}', not {count} at {path}"
                     , tag => $multi, count => scalar @values
                     , path => $path, _class => 'misfit';

#           @values ? $process->($doc, $values[0]) : undef;
            @values or return undef;

            my $starter = keys %$values;
            my @d = try { $process->($doc, $values[0]) };
            $@->wasFatal(class => 'misfit') && $starter==keys %$values
                or $@->reportAll;
            @d;
        };
        return ($label, bless($code, 'BLOCK'));
    }

    if($min==1 && $max==1)
    {   my $code = sub {
            my @d = $process->(@_);
            @d or error __x"no match for required block `{tag}' at {path}"
              , tag => $multi, path => $path, _class => 'misfit';
            @d;
        };
        return ($label, bless($code, 'BLOCK'));
    }

    my $opt  = $max - $min;
    my $code = sub {
        my $doc    = shift;
        my $values = delete shift->{$multi};
        my @values = ref $values eq 'ARRAY' ? @$values
                   : defined $values ? $values : ();

        @values >= $min && @values <= $max
            or error __x"found {found} blocks for `{tag}', must be between {min} and {max} inclusive at {path}"
                 , tag => $multi, min => $min, max => $max, path => $path
                 , found => scalar @values, _class => 'misfit';

        map { $process->($doc, {%$_}) } @values;
    };

    ($multi, bless($code, 'BLOCK'));
}

sub makeRequired
{   my ($self, $path, $label, $do) = @_;
    my $req = sub {
        my @nodes = $do->(@_);
        return @nodes if @nodes;

        error __x"required data for block (starts with `{tag}') missing at {path}"
          , tag => $label, path => $path, _class => 'misfit'
            if ref $do eq 'BLOCK';

        error __x"required value for element `{tag}' missing at {path}"
          , tag => $label, path => $path, _class => 'misfit';
    };
    bless $req, 'BLOCK' if ref $do eq 'BLOCK';
    $req;
}

sub makeElement
{   my ($self, $path, $ns, $childname, $do) = @_;
    sub { defined $_[1] ? $do->(@_) : () };
}

sub makeElementFixed
{   my ($self, $path, $ns, $childname, $do, $fixed) = @_;
    $fixed = $fixed->value if ref $fixed;

    sub {
        my ($doc, $value) = @_;
        my $ret = defined $value ? $do->($doc, $value) : return;
        return $ret
            if defined $ret && $ret->textContent eq $fixed;

        defined $ret
            or error __x"required element `{name}' with fixed value `{fixed}' missing at {path}"
                 , name => $childname, fixed => $fixed, path => $path,
                 , _class => 'misfit';

        error __x"element `{name}' has value fixed to `{fixed}', got `{value}' at {path}"
           , name => $childname, fixed => $fixed
           , value => $ret->textContent, path => $path, _class => 'misfit';
    };
}

sub makeElementNillable
{   my ($self, $path, $ns, $childname, $do, $value, $tag) = @_;
    my $inas    = $self->{interpret_nillable_as_optional};

    $self->_registerNSprefix(xsi => SCHEMA2001i, 0);
    my $nilattr = $self->makeTagQualified($path, undef, 'nil', SCHEMA2001i);

    sub
    {   my ($doc, $value) = @_;
        defined $value  or return;
        $value eq 'NIL' or return $do->($doc, $value);

        return $doc->createTextNode('')
            if $inas;

        my $node = $doc->createElement($tag);

        $node->setAttribute($nilattr => 'true');
        $node;
    };
}

sub makeElementDefault
{   my ($self, $path, $ns, $childname, $do, $default) = @_;
    my $mode = $self->{default_values};

    $mode eq 'IGNORE'
        and return sub { defined $_[1] ? $do->(@_) : () };

    $mode eq 'EXTEND'
        and return sub { $do->($_[0], (defined $_[1] ? $_[1] : $default)) };

    $mode eq 'MINIMAL'
        and return sub { defined $_[1] && $_[1] ne $default ? $do->(@_) : () };

    error __x"illegal default_values mode `{mode}'", mode => $mode;
}

sub makeElementAbstract
{   my ($self, $path, $ns, $childname, $do, $default) = @_;
    sub { defined $_[1] or return ();
          error __x"attempt to instantiate abstract element `{name}' at {where}"
            , name => $childname, where => $path;
        };
}

#
# complexType/ComplexContent
#

sub makeComplexElement
{   my ($self, $path, $tag, $elems, $attrs, $any_attr) = @_;
    my @elems = odd_elements @$elems;
    my @attrs = @$attrs;
    my $tags  = join ', ', even_elements(@$elems), even_elements(@attrs);
    my @anya  = @$any_attr;
    my $iut   = $self->{ignore_unused_tags};

    return
    sub
    {   my ($doc, $data) = @_;
        return $doc->importNode($data)
            if UNIVERSAL::isa($data, 'XML::LibXML::Element');

        unless(UNIVERSAL::isa($data, 'HASH'))
        {   defined $data
                or error __x"complex `{tag}' requires data at {path}"
                      , tag => $tag, path => $path, _class => 'misfit';

            error __x"complex `{tag}' requires a HASH of input data, not `{found}' at {path}"
               , tag => $tag, found => (ref $data || $data), path => $path;
        }

        my $copy   = { %$data };  # do not destroy callers hash
        my @childs = map {$_->($doc, $copy)} @elems;
        for(my $i=0; $i<@attrs; $i+=2)
        {   push @childs, $attrs[$i+1]->($doc, delete $copy->{$attrs[$i]});
        }

        push @childs, $_->($doc, $copy)
            for @anya;

        if(%$copy)
        {   my @not_used
              = defined $iut ? grep({$_ !~ $iut} keys %$copy) : keys %$copy;

            if(@not_used)
            {   trace "available tags are: $tags";
                mistake __xn "tag `{tags}' not used at {path}"
                  , "unused tags {tags} at {path}"
                  , scalar @not_used, tags => [sort @not_used], path => $path;
            }
        }

        my $node  = $doc->createElement($tag);

        foreach my $child (@childs)
        {   defined $child or next;
            if(ref $child)
            {   next if UNIVERSAL::isa($child, 'XML::LibXML::Text')
                     && $child->data eq '' ;
            }
            else
            {   length $child or next;
                $child = XML::LibXML::Text->new($child);
            }
            $node->addChild($child);
        }

        $node;
    };
}

#
# complexType/simpleContent
#

sub makeTaggedElement
{   my ($self, $path, $tag, $st, $attrs, $attrs_any) = @_;
    my @attrs = @$attrs;
    my @anya  = @$attrs_any;

    return sub {
        my ($doc, $data) = @_;
        return $doc->importNode($data)
            if UNIVERSAL::isa($data, 'XML::LibXML::Element');

        my $copy    = UNIVERSAL::isa($data,'HASH') ? {%$data} : {_ => $data};
        my $content = delete $copy->{_};

        my ($node, @childs);
        if(UNIVERSAL::isa($content, 'XML::LibXML::Node'))
        {   $node = $doc->importNode($content);
        }
        elsif(defined $content)
        {   push @childs, $st->($doc, $content);
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

sub makeMixedElement
{   my ($self, $path, $tag, $elems, $attrs, $attrs_any) = @_;
    my @attrs = @$attrs;
    my @anya  = @$attrs_any;

    my $mixed = $self->{mixed_elements};
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
          defined $data or return;

          return $doc->importNode($data)
              if UNIVERSAL::isa($data, 'XML::LibXML::Element');

          my $copy = UNIVERSAL::isa($data, 'HASH') ? {%$data} : {_ => $data};
          my $content = delete $copy->{_};
          defined $content or return;

          UNIVERSAL::isa($content, 'XML::LibXML::Node')
              or $content = $doc->createTextNode($content);
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

sub makeSimpleElement
{   my ($self, $path, $tag, $st) = @_;

    sub {
        my ($doc, $data) = @_;
        return $doc->importNode($data)
            if UNIVERSAL::isa($data, 'XML::LibXML::Element');
        $data = $data->{_}
            if ref $data eq 'HASH';

        my $value = $st->($doc, $data);
        defined $value
            or return ();

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

sub makeBuiltin
{   my ($self, $path, $node, $type, $def, $check_values) = @_;
    my $check  = $check_values ? $def->{check} : undef;
    my $err    = $path eq $type
      ? N__"illegal value `{value}' for type {type}"
      : N__"illegal value `{value}' for type {type} at {path}";

    my $format = $def->{format};
    my $trans  = $self->{prefixes};

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

sub makeList
{   my ($self, $path, $st) = @_;
    sub { my ($doc, $v) = @_;
        defined $v or return undef;
        join ' ', grep defined, map {$st->($doc, $_)}
            ref $v eq 'ARRAY' ? @$v : $v;
    };
}

sub makeFacetsList
{   my ($self, $path, $st, $info, $early, $late) = @_;
    my @e = grep defined, @$early;
    my @l = grep defined, @$late;
    sub { my ($doc, $v) = @_;
        defined $v or return undef;
        $_->($v) for @l;
        my $list = join ' ', map {$st->($doc, $_)} ref $v eq 'ARRAY' ? @$v : $v;
        defined $list && length $list or return;
        do { $list = $_->($list) } for @e;
        $list;
    }
}

sub makeFacets
{   my ($self, $path, $st, $info, @do) = @_;
    @do or return $st;
    sub { defined $_[1] or return undef;
          my $v = $st->(@_);
          for(reverse @do)
          { defined $v or return (); $v = $_->($v) }
          $v;
        };
}

sub makeUnion
{   my ($self, $path, @types) = @_;
    sub { my ($doc, $value) = @_;
          defined $value or return undef;
          for(@types) {my $v = try { $_->($doc, $value) }; $@ or return $v }

          substr $value, 10, -1, '...' if length($value) > 13;
          error __x"no match for `{text}' in union at {path}"
             , text => $value, path => $path;
        };
}

sub makeSubstgroup
{   my ($self, $path, $type, %done) = @_;

    keys %done or return bless sub { () }, 'BLOCK';
    my %do = map { @$_ } values %done;

    bless
    sub { my ($doc, $values) = @_;
#warn "SUBST($type) AVAILABLE ARE ", join ', ', keys %do;
          foreach my $take (keys %do)
          {   my $subst = delete $values->{$take};
              defined $subst or next;

              return $do{$take}->($doc, $subst);
          }
          ();
        }, 'BLOCK';
}

# Attributes

sub makeAttributeRequired
{   my ($self, $path, $ns, $tag, $label, $do) = @_;

    sub { my $value = $do->(@_);
          return $_[0]->createAttributeNS($ns, $tag, $value)
              if defined $value;

          error __x"attribute `{tag}' is required at {path}"
             , tag => $tag, path => $path;
        };
}

sub makeAttributeProhibited
{   my ($self, $path, $ns, $tag, $label, $do) = @_;

    sub { my $value = $do->(@_);
          defined $value or return ();

          error __x"attribute `{tag}' is prohibited at {path}"
             , tag => $tag, path => $path;
        };
}

sub makeAttribute
{   my ($self, $path, $ns, $tag, $label, $do) = @_;
    sub { my $value = $do->(@_);
          defined $value ? $_[0]->createAttribute($tag, $value) : ();
        };
}

sub makeAttributeDefault
{   my ($self, $path, $ns, $tag, $label, $do, $default_node) = @_;

    my $mode = $self->{default_values};
    $mode eq 'IGNORE'
       and return sub
         { my $value = $do->(@_);
           defined $value ? $_[0]->createAttribute($tag, $value) : ();
         };

    my $default = $default_node->value;
    $mode eq 'EXTEND'
        and return sub
          { my $value = $do->(@_);
            defined $value or $value = $default;
            $_[0]->createAttribute($tag, $value);
          };

    $mode eq 'MINIMAL'
        and return sub
          { my $value = $do->(@_);
            return () if defined $value && $value eq $default;
            $_[0]->createAttribute($tag, $value);
          };

    error __x"illegal default_values mode `{mode}'", mode => $mode;
}

sub makeAttributeFixed
{   my ($self, $path, $ns, $tag, $label, $do, $fixed) = @_;
    $fixed   = $fixed->value if ref $fixed;

    sub { my ($doc, $value) = @_;
          defined $value or return ();

          $value eq $fixed
              or error __x"value of attribute `{tag}' is fixed to `{fixed}', not `{got}' at {path}"
                   , tag => $tag, got => $value, fixed => $fixed, path => $path;

          $doc->createAttribute($tag, $fixed);
        };
}

# any

sub _splitAnyList($$$)
{   my ($self, $path, $type, $v) = @_;
    my @nodes = ref $v eq 'ARRAY' ? @$v : defined $v ? $v : return ([], []);
    my (@attrs, @elems);

    foreach my $node (@nodes)
    {   UNIVERSAL::isa($node, 'XML::LibXML::Node')
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

sub makeAnyAttribute
{   my ($self, $path, $handler, $yes, $no, $process) = @_;
    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    bless
    sub { my ($doc, $values) = @_;

          my @res;
          foreach my $type (keys %$values)
          {   my ($ns, $local) = unpack_type $type;
              length $ns or substr($type, 0, 1) eq '{' or next;
              my @elems;

              $yes{$ns} or next if keys %yes;
              $no{$ns} and next if keys %no;

              my ($attrs, $elems)
                = $self->_splitAnyList($path, $type, delete $values->{$type});

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

sub makeAnyElement
{   my ($self, $path, $handler, $yes, $no, $process, $min, $max) = @_;
    my %yes = map { ($_ => 1) } @{$yes || []};
    my %no  = map { ($_ => 1) } @{$no  || []};

    $handler ||= 'SKIP_ALL';
    bless
    sub { my ($doc, $values) = @_;
          my @res;

          foreach my $type (keys %$values)
          {   my ($ns, $local) = unpack_type $type;

              # name-spaceless Perl, then not for any(Attribute)
              length $ns or substr($type, 0, 1) eq '{' or next;

              $yes{$ns} or next if keys %yes;
              $no{$ns} and next if keys %no;

              my ($attrs, $elems)
                 = $self->_splitAnyList($path, $type, delete $values->{$type});

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

          @res ? @res : undef;   # empty, then "0 but true"
        }, 'ANY';
}

# xsi:type handling

sub makeXsiTypeSwitch($$$$)
{   my ($self, $where, $elem, $default_type, $types) = @_;
    my $xsi = $self->_registerNSprefix(xsi => SCHEMA2001i, 1) . ':type';
    my %types;
    foreach my $type (sort keys %$types)
    {   my ($ns, $local) = unpack_type $type;
        my $tag = $self->makeTagQualified($where, undef, $local, $ns);
        $types{$type} = [ $tag, $types->{$type} ];
    }

    sub {
        my ($doc, $values) = @_;
        ref $values eq 'HASH' && $values->{XSI_TYPE}
            or return $types{$default_type}[1]->(@_);

        my %v    = %$values;
        my $type = delete $v{XSI_TYPE};
        my $def  = $types{$type}
            or error __x"specified xsi:type list for `{default}' does not contain `{got}'"
                 , default => $default_type, got => $type;

        my ($t, $code) = @$def;
        my $node = $code->($doc, \%v)
            or return;
        $node->setAttribute($xsi, $t);
        $node;
    };
}

sub makeHook($$$$$$)
{   my ($self, $path, $r, $tag, $before, $replace, $after) = @_;
    return $r unless $before || $replace || $after;

    error __x"writer only supports one production (replace) hook"
        if $replace && @$replace > 1;

    return sub {()} if $replace && grep {$_ eq 'SKIP'} @$replace;

    my @replace = $replace ? map {$self->_decodeReplace($path,$_)} @$replace:();
    my @before  = $before  ? map {$self->_decodeBefore($path,$_) } @$before :();
    my @after   = $after   ? map {$self->_decodeAfter($path,$_)  } @$after  :();

    sub
    {  my ($doc, $val) = @_;
       defined $val or return;
       foreach (@before)
       {   $val = $_->($doc, $val, $path);
           defined $val or return ();
       }

       my $xml = @replace
               ? $replace[0]->($doc, $val, $path, $tag, $r)
               : $r->($doc, $val);
       defined $xml or return ();

       foreach (@after)
       {   $xml = $_->($doc, $xml, $path, $val);
           defined $xml or return ();
       }

       $xml;
     }
}

sub _decodeBefore($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

    # $code->($doc, $values, $path)
      $call eq 'PRINT_PATH' ? sub { print "$_[2]\n"; $_[1] }
    : error __x"labeled before hook `{name}' undefined for WRITER", name=>$call;
}

sub _decodeReplace($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

    # SKIP already handled
    # $replace->($doc, $val, $path, $tag, $replaced)
    error __x"labeled replace hook `{name}' undefined for WRITER", name=>$call;
}

sub _decodeAfter($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub { print "$_[2]\n"; $_[1] }
    : error __x"labeled after hook `{name}' undefined for WRITER", name=>$call;
}

sub makeBlocked($$$)
{   my ($self, $where, $class, $type) = @_;

    # errors are produced in class=misfit to allow other choices to succeed.
      $class eq 'anyType'
    ? { st => sub { error __x"use of `{type}' blocked at {where}"
              , type => $type, where => $where, _class => 'misfit';
          }}
    : $class eq 'simpleType'
    ? { st => sub { error __x"use of {class} `{type}' blocked at {where}"
              , class => $class, type => $type, where => $where
              , _class => 'misfit';
          }}
    : $class eq 'complexType'
    ? { elems => [] }
    : $class eq 'ref'
    ? { st => sub { error __x"use of referenced `{type}' blocked at {where}"
              , type => $type, where => $where, _class => 'misfit';
          }}
    : panic "blocking of $class for $type not implemented";
}


1;

