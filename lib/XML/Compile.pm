# Copyrights 2006-2007 by Mark Overmeer.
# For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 0.99.

use warnings;
use strict;

package XML::Compile;
use vars '$VERSION';
$VERSION = '0.17';

use XML::LibXML;
use Carp;

my %namespace_defs =
 ( 'http://www.w3.org/1999/XMLSchema'      => '1999-XMLSchema.xsd'
 , 'http://www.w3.org/1999/part2.xsd'      => '1999-XMLSchema-part2.xsd'
 , 'http://www.w3.org/2000/10/XMLSchema'   => '2000-XMLSchema.xsd'
 , 'http://www.w3.org/2001/XMLSchema'      => '2001-XMLSchema.xsd'
 , 'http://www.w3.org/XML/1998/namespace'  => '1998-namespace.xsd'
 , 'http://schemas.xmlsoap.org/wsdl/'      => 'wsdl.xsd'
 , 'http://schemas.xmlsoap.org/wsdl/soap/' => 'wsdl-soap.xsd'
 , 'http://schemas.xmlsoap.org/wsdl/http/' => 'wsdl-http.xsd'
 , 'http://schemas.xmlsoap.org/wsdl/mime/' => 'wsdl-mime.xsd'
 , 'http://schemas.xmlsoap.org/soap/encoding/' => 'soap-encoding.xsd'
 , 'http://schemas.xmlsoap.org/soap/envelope/' => 'soap-envelope.xsd'

 # bug-fixes/mis-features/work-arounds
 , 'http://schemas.xmlsoap.org/wsdl/#patch'=> 'wsdl-patch.xsd'
 );


sub new($@)
{   my ($class, $top) = (shift, shift);

    croak "ERROR: you should instantiate a sub-class, $class is base only"
        if $class eq __PACKAGE__;

    (bless {}, $class)->init( {top => $top, @_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->addSchemaDirs($ENV{SCHEMA_DIRECTORIES});
    $self->addSchemaDirs($args->{schema_dirs});
    $self;
}


sub addSchemaDirs(@)
{   my $self = shift;
    foreach (@_)
    {   my $dir  = shift;
        my @dirs = grep {defined} ref $dir eq 'ARRAY' ? @$dir : $dir;
        push @{$self->{schema_dirs}},
           $^O eq 'MSWin32' ? @dirs : map { split /\:/ } @dirs;
    }
    $self;
}


sub knownNamespace($) { $namespace_defs{$_[1]} }


sub findSchemaFile($)
{   my ($self, $fn) = @_;

    return (-r $fn ? $fn : undef)
        if File::Spec->file_name_is_absolute($fn);

    foreach my $dir (@{$self->{schema_dirs}})
    {   my $full = File::Spec->catfile($dir, $fn);
        next unless -e $full;
        return -r $full ? $full : undef;
    }

    undef;
}


sub dataToXML($)
{   my ($self, $thing) = @_;

    return $thing
       if ref $thing && UNIVERSAL::isa($thing, 'XML::LibXML::Node');

    return $self->parse($thing)
       if ref $thing eq 'SCALAR'; # XML string as ref

    return $self->parse(\$thing)
       if $thing =~ m/^\s*\</;    # XML starts with '<', rare for files

    if(my $known = $self->knownNamespace($thing))
    {   my $fn = $self->findSchemaFile($known)
            or croak "ERROR: cannot find pre-installed name-space files.\n";

        return $self->parseFile($fn);
    }

    return $self->parseFile($thing)
         if -f $thing;

    my $data = "$thing";
    $data = substr($data, 0, 39) . '...' if length($data) > 40;
    croak "ERROR: don't known how to interpret XML data\n   $data\n";
}


sub parse($)
{   my ($thing, $data) = @_;
    my $xml = XML::LibXML->new->parse_string($$data);
    defined $xml ? $xml->documentElement : undef;
}


sub parseFile($)
{   my ($thing, $fn) = @_;
    my $xml = XML::LibXML->new->parse_file($fn);
    defined $xml ? $xml->documentElement : undef;
}


sub walkTree($$)
{   my ($self, $node, $code) = @_;
    if($code->($node))
    {   $self->walkTree($_, $code)
            for $node->getChildNodes;
    }
}

1;
