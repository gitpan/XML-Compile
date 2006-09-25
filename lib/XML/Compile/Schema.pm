
use warnings;
use strict;

package XML::Compile::Schema;
use vars '$VERSION';
$VERSION = '0.09';
use base 'XML::Compile';

use Carp;
use List::Util   qw/first/;
use XML::LibXML  ();
use File::Spec   ();

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::Translate      ();
use XML::Compile::Schema::Instance;
use XML::Compile::Schema::NameSpaces;

my %schemaLocation =
 ( 'http://www.w3.org/1999/XMLSchema'     => '1999-XMLSchema.xsd'
 , 'http://www.w3.org/1999/part2.xsd'     => '1999-XMLSchema-part2.xsd'
 , 'http://www.w3.org/2000/10/XMLSchema'  => '2000-XMLSchema.xsd'
 , 'http://www.w3.org/2001/XMLSchema'     => '2001-XMLSchema.xsd'
 , 'http://www.w3.org/XML/1998/namespace' => '1998-namespace.xsd'
 );


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

    my $node = ref $top && $top->isa('XML::LibXML::Node') ? $top
      : $self->parse(\$top);

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


sub importSchema($)
{   my ($self, $thing) = @_;

    my $filename = $schemaLocation{$thing} || $thing;

    my $path = $self->findSchemaFile($filename)
        or croak "ERROR: cannot find $filename for $thing";

    my $tree = $self->parseFile($path)
        or croak "ERROR: cannot parse XML from $path";

    $self->addSchema($tree);
}


sub compile($$@)
{   my ($self, $action, $type, %args) = @_;

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

    my $bricks = 'XML::Compile::Schema::' .
     ( $action eq 'READER' ? 'XmlReader'
     : $action eq 'WRITER' ? 'XmlWriter'
     : croak "ERROR: create only READER or WRITER, not '$action'."
     );

    eval "require $bricks";
    die $@ if $@;

    XML::Compile::Schema::Translate->compileTree
     ( $top->{full}, %args
     , bricks => $bricks
     , err    => $self->invalidsErrorHandler($args{invalid})
     , nss    => $self->namespaces
     );
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
