# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.

use warnings;
use strict;

package XML::Compile;
use vars '$VERSION';
$VERSION = '0.55';

use Log::Report 'xml-compile', syntax => 'SHORT';
use XML::LibXML;

use File::Spec     qw();

__PACKAGE__->knownNamespace
 ( 'http://www.w3.org/XML/1998/namespace' => '1998-namespace.xsd'
 , 'http://www.w3.org/1999/XMLSchema'     => '1999-XMLSchema.xsd'
 , 'http://www.w3.org/1999/part2.xsd'     => '1999-XMLSchema-part2.xsd'
 , 'http://www.w3.org/2000/10/XMLSchema'  => '2000-XMLSchema.xsd'
 , 'http://www.w3.org/2001/XMLSchema'     => '2001-XMLSchema.xsd'
 );

__PACKAGE__->addSchemaDirs($ENV{SCHEMA_DIRECTORIES});
__PACKAGE__->addSchemaDirs(__FILE__);


sub new($@)
{   my ($class, $top) = (shift, shift);

    $class ne __PACKAGE__
       or panic "you should instantiate a sub-class, $class is base only";

    (bless {}, $class)->init( {top => $top, @_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->addSchemaDirs($args->{schema_dirs});
    $self;
}


my @schema_dirs;
sub addSchemaDirs(@)
{   my $thing = shift;
    foreach (@_)
    {   my $dir  = shift;
        my @dirs = grep {defined} ref $dir eq 'ARRAY' ? @$dir : $dir;
        foreach ($^O eq 'MSWin32' ? @dirs : map { split /\:/ } @dirs)
        {   my $el = $_;
            $el = File::Spec->catfile($el, 'xsd') if $el =~ s/\.pm$//i;
            push @schema_dirs, $el;
        }
    }
    defined wantarray ? @schema_dirs : ();
}


my %namespace_file;
sub knownNamespace($;@)
{   my $thing = shift;
    return $namespace_file{ $_[0] } if @_==1;

    while(@_)
    {  my $ns = shift;
       $namespace_file{$ns} = shift;
    }
    undef;
}


sub findSchemaFile($)
{   my ($self, $fn) = @_;

    return (-r $fn ? $fn : undef)
        if File::Spec->file_name_is_absolute($fn);

    foreach my $dir (@schema_dirs)
    {   my $full = File::Spec->catfile($dir, $fn);
        next unless -e $full;
        return -r $full ? $full : undef;
    }

    undef;
}


sub dataToXML($)
{   my ($self, $thing) = @_;
    defined $thing
        or return undef;

    return $thing
        if ref $thing && UNIVERSAL::isa($thing, 'XML::LibXML::Node');

    return $self->_parse($thing)
        if ref $thing eq 'SCALAR'; # XML string as ref

    return $self->_parse(\$thing)
        if $thing =~ m/^\s*\</;    # XML starts with '<', rare for files

    if(my $known = $self->knownNamespace($thing))
    {   my $fn = $self->findSchemaFile($known)
            or error __x"cannot find pre-installed name-space files named {path} for {name}"
                 , path => $known, name => $thing;

        return $self->_parseFile($fn);
    }

    return $self->_parseFile($thing)
        if -f $thing;

    my $data = "$thing";
    $data = substr($data, 0, 39) . '...' if length($data) > 40;
    mistake __x"don't known how to interpret XML data\n   {data}"
          , data => $data;
}

sub _parse($)
{   my ($thing, $data) = @_;
    my $xml = XML::LibXML->new->parse_string($$data);
    defined $xml ? $xml->documentElement : undef;
}

sub _parseFile($)
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
