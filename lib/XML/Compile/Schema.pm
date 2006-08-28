
use warnings;
use strict;

package XML::Compile::Schema;
use vars '$VERSION';
$VERSION = '0.05';
use base 'XML::Compile';

use Carp;
use List::Util   qw/first/;
use XML::LibXML;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInStructs qw/builtin_structs/;
use XML::Compile::Schema::Translate      qw/compile_tree/;
use XML::Compile::Schema::Instance;
use XML::Compile::Schema::NameSpaces;


sub init($)
{   my ($self, $args) = @_;
    $self->{namespaces} = XML::Compile::Schema::NameSpaces->new;
    $self->SUPER::init($args);

    if(my $top = $self->top)
    {   $self->addSchemas($top);
    }

    $self;
}


sub namespaces() { shift->{namespaces} }


sub addSchemas($$)
{   my ($self, $top) = @_;

    $top    = $top->documentElement
       if $top->isa('XML::LibXML::Document');

    my $nss = $self->namespaces;

    $self->walkTree
    ( $top,
      sub { my $node = shift;
            return 1 unless $node->isa('XML::LibXML::Element')
                         && $node->localname eq 'schema';

            my $schema = XML::Compile::Schema::Instance->new($node)
                or next;

#warn $schema->targetNamespace;
#$schema->printIndex(\*STDERR);
            $nss->add($schema);
            return 0;
          }
    );
}


sub compile($$@)
{   my ($self, $direction, $type, %args) = @_;

    exists $args{check_values}
       or $args{check_values} = 1;

    exists $args{check_occurs}
       or $args{check_occurs} = 0;

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

    $args{path} ||= $top->{full};

    compile_tree
     ( $top->{full}, %args
     , run => builtin_structs($direction) 
     , err => $self->invalidsErrorHandler($args{invalid})
     , nss => $self->namespaces
     );
}


sub template($@)
{   my ($self, $direction) = (shift, shift);

    my %args =
     ( check_values       => 0
     , check_occurs       => 0
     , invalid            => 'IGNORE'
     , ignore_facets      => 1
     , include_namespaces => 1
     , sloppy_integers    => 1
     , auto_value         => sub { warn @_; $_[0] }
     , @_
     );

   die "ERROR not implemented";
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
             $nss->namespaces;
}


sub elements()
{   my $nss = shift->namespaces;
    sort map {$_->elements}
          map {$nss->schemas($_)}
             $nss->namespaces;
}

1;
