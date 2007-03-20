# Copyrights 2006-2007 by Mark Overmeer.
# For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 0.99.

use warnings;
use strict;

package XML::Compile::Schema;
use vars '$VERSION';
$VERSION = '0.17';
use base 'XML::Compile';

use Carp;
use List::Util   qw/first/;
use XML::LibXML  ();
use File::Spec   ();

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::Translate      ();
use XML::Compile::Schema::Instance;
use XML::Compile::Schema::NameSpaces;


sub init($)
{   my ($self, $args) = @_;
    $self->{namespaces} = XML::Compile::Schema::NameSpaces->new;
    $self->SUPER::init($args);

    $self->addSchemas($args->{top});

    $self->{hooks} = [];
    if(my $h1 = $args->{hook})
    {   $self->addHook(ref $h1 eq 'ARRAY' ? @$h1 : $h1);
    }
    if(my $h2 = $args->{hooks})
    {   $self->addHooks(ref $h2 eq 'ARRAY' ? @$h2 : $h2);
    }
 
    $self;
}


sub namespaces() { shift->{namespaces} }


sub addSchemas($)
{   my ($self, $top) = @_;
    defined $top or return;

    my $node = $self->dataToXML($top);
    $node    = $node->documentElement
       if $node->isa('XML::LibXML::Document');

    my $nss = $self->namespaces;

    $self->walkTree
    ( $node,
      sub { my $this = shift;
            return 1 unless $this->isa('XML::LibXML::Element')
                         && $this->localname eq 'schema';

            my $schema = XML::Compile::Schema::Instance->new($this)
                or next;

#warn $schema->targetNamespace;
#$schema->printIndex(\*STDERR);
            $nss->add($schema);
            return 0;
          }
    );
}


sub importData($)
{   my ($self, $thing) = @_;
    my $tree = $self->dataToXML($thing) or return;
    $self->addSchemas($tree);
}


sub addHook(@)
{   my $self = shift;
    push @{$self->{hooks}}, @_>=1 ? {@_} : defined $_[0] ? shift : ();
    $self;
}


sub addHooks(@)
{   my $self = shift;
    push @{$self->{hooks}}, grep {defined} @_;
    $self;
}


sub hooks() { @{shift->{hooks}} }


sub compile($$@)
{   my ($self, $action, $type, %args) = @_;

    exists $args{check_values}
       or $args{check_values} = 1;

    exists $args{check_occurs}
       or $args{check_occurs} = 1;

    $args{sloppy_integers}   ||= 0;
    unless($args{sloppy_integers})
    {   eval "require Math::BigInt";
        die "ERROR: require Math::BigInt or sloppy_integers:\n$@"
            if $@;

        eval "require Math::BigFloat";
        die "ERROR: require Math::BigFloat or sloppy_integers:\n$@"
            if $@;
    }

    $args{include_namespaces} ||= 1;
    $args{output_namespaces}  ||= {};

    do { $_->{used} = 0 for values %{$args{output_namespaces}} }
       if $args{namespace_reset};

    my $nss   = $self->namespaces;
    my $top   = $nss->findType($type) || $nss->findElement($type)
       or croak "ERROR: type $type is not defined";

    my ($h1, $h2) = (delete $args{hook}, delete $args{hooks});
    my @hooks = $self->hooks;
    push @hooks, ref $h1 eq 'ARRAY' ? @$h1 : $h1 if $h1;
    push @hooks, ref $h2 eq 'ARRAY' ? @$h2 : $h2 if $h2;

    $args{path} ||= $top->{full};

    my $bricks = 'XML::Compile::Schema::' .
     ( $action eq 'READER' ? 'XmlReader'
     : $action eq 'WRITER' ? 'XmlWriter'
     : croak "ERROR: create only READER, WRITER, not '$action'."
     );

    eval "require $bricks";
    die $@ if $@;

    XML::Compile::Schema::Translate->compileTree
     ( $top->{full}, %args
     , bricks => $bricks
     , err    => $self->invalidsErrorHandler($args{invalid})
     , nss    => $self->namespaces
     , hooks  => \@hooks
     );
}


sub template($@)
{   my ($self, $action, $type, %args) = @_;

    my $show = exists $args{show} ? $args{show} : 'ALL';
    $show = 'struct,type,occur,facets' if $show eq 'ALL';
    $show = '' if $show eq 'NONE';
    my @comment = map { ("show_$_" => 1) } split m/\,/, $show;

    my $nss = $self->namespaces;
    my $top = $nss->findType($type) || $nss->findElement($type)
       or croak "ERROR: type $type is not defined";

    my $indent                  = $args{indent} || "  ";
    $args{check_occurs}         = 1;
    $args{include_namespaces} ||= 1;

    my $bricks = 'XML::Compile::Schema::Template';
    eval "require $bricks";
    die $@ if $@;

    my $compiled = XML::Compile::Schema::Translate->compileTree
     ( $top->{full}
     , bricks => $bricks
     , nss    => $self->namespaces
     , err    => $self->invalidsErrorHandler('IGNORE')
     , hooks  => []
     , %args
     );

    my $ast = $compiled->();
# use Data::Dumper;
# $Data::Dumper::Indent = 1;
# warn Dumper $ast;

    if($action eq 'XML')
    {   my $doc  = XML::LibXML::Document->new('1.1', 'UTF-8');
        my $node = $bricks->toXML($doc,$ast, @comment, indent => $indent);
        return $node->toString(1);
    }

    if($action eq 'PERL')
    {   return $bricks->toPerl($ast, @comment, indent => $indent);
    }

    die "ERROR: template output is either in XML or PERL layout, not '$action'\n";
}


sub invalidsErrorHandler($)
{   my $key = $_[1] || 'DIE';

      ref $key eq 'CODE'? $key
    : $key eq 'IGNORE'  ? sub { undef }
    : $key eq 'USE'     ? sub { $_[1] }
    : $key eq 'WARN'
    ? sub {warn "$_[2] ("
              . (defined $_[1]? $_[1] : 'undef')
              . ") for $_[0]\n"; $_[1]}
    : $key eq 'DIE'
    ? sub {die  "$_[2] (".(defined $_[1] ? $_[1] : 'undef').") for $_[0]\n"}
    : die "ERROR: error handler expects CODE, 'IGNORE',"
        . "'USE','WARN', or 'DIE', not $key";
}


sub types()
{   my $nss = shift->namespaces;
    sort map {$_->types}
          map {$nss->schemas($_)}
             $nss->list;
}


sub elements()
{   my $nss = shift->namespaces;
    sort map {$_->elements}
          map {$nss->schemas($_)}
             $nss->list;
}


1;
