# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.05.

use warnings;
use strict;

package XML::Compile;
use vars '$VERSION';
$VERSION = '0.99';


use Log::Report 'xml-compile', syntax => 'SHORT';
use XML::LibXML;
use XML::Compile::Util qw/:constants type_of_node/;

use File::Spec     qw();

__PACKAGE__->knownNamespace
 ( &XMLNS       => '1998-namespace.xsd'
 , &SCHEMA1999  => '1999-XMLSchema.xsd'
 , &SCHEMA2000  => '2000-XMLSchema.xsd'
 , &SCHEMA2001  => '2001-XMLSchema.xsd'
 , &SCHEMA2001i => '2001-XMLSchema-instance.xsd'
 , 'http://www.w3.org/1999/part2.xsd'
                => '1999-XMLSchema-part2.xsd'
 );

__PACKAGE__->addSchemaDirs($ENV{SCHEMA_DIRECTORIES});
__PACKAGE__->addSchemaDirs(__FILE__);


sub new($@)
{   my $class = shift;
    my $top   = @_ % 2 ? shift : undef;

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
        my $sep  = $^O eq 'MSWin32' ? qr/\;/ : qr/\:/;
        foreach (map { split $sep } @dirs)
        {   my $el = $_;
            $el = File::Spec->catfile($el, 'xsd') if $el =~ s/\.pm$//i;
            push @schema_dirs, $el;
        }
    }
    defined wantarray ? @schema_dirs : ();
}

#----------------------


my $parser = XML::LibXML->new;
$parser->line_numbers(1);
$parser->no_network(1);

sub dataToXML($)
{   my ($self, $thing) = @_;
    defined $thing
        or return;

    my ($xml, %details);
    if(ref $thing && UNIVERSAL::isa($thing, 'XML::LibXML::Node'))
    {   ($xml, %details) = $self->_parsedNode($thing);
    }
    elsif(ref $thing eq 'SCALAR')   # XML string as ref
    {   ($xml, %details) = $self->_parseScalar($thing);
    }
    elsif(ref $thing eq 'GLOB')     # from file-handle
    {   ($xml, %details) = $self->_parseFileHandle($thing);
    }
    elsif($thing =~ m/^\s*\</)      # XML starts with '<', rare for files
    {   ($xml, %details) = $self->_parseScalar(\$thing);
    }
    elsif(my $known = $self->knownNamespace($thing))
    {   my $fn  = $self->findSchemaFile($known)
            or error __x"cannot find pre-installed name-space file named {path} for {name}"
                 , path => $known, name => $thing;

        ($xml, %details) = $self->_parseFile($fn);
        $details{source} = "known namespace $thing";
    }
    elsif(my $fn = $self->findSchemaFile($thing))
    {   ($xml, %details) = $self->_parseFile($fn);
        $details{source} = "filename in schema-dir $thing";
    }
    elsif(-f $thing)
    {   ($xml, %details) = $self->_parseFile($thing);
    }
    else
    {   my $data = "$thing";
        $data = substr($data, 0, 39) . '...' if length($data) > 40;
        error __x"don't known how to interpret XML data\n   {data}"
           , data => $data;
    }

    wantarray ? ($xml, %details) : $xml;
}

sub _parsedNode($)
{   my ($thing, $node) = @_;
    my $top = $node;

    if($node->isa('XML::LibXML::Document'))
    {   $top       = $node->documentElement;
        my $eltype = type_of_node($top || '(none)');
        trace "using preparsed XML document with element <$eltype>";
    }
    elsif($node->isa('XML::LibXML::Element'))
    {   trace 'using preparsed XML node <'.type_of_node($node).'>';
    }
    else
    {   my $text = $node->toString;
        $text =~ s/\s+/ /gs;
        substr($text, 70, -1, '...')
            if length $text > 75;
        error __x"dataToXML() accepts pre-parsed document or element\n  {got}"
          , got => $text;
    }

    ($top, source => ref $node);
}

sub _parseScalar($)
{   my ($thing, $data) = @_;
    trace "parsing XML from string $data";
    my $xml = $parser->parse_string($$data);

    ( (defined $xml ? $xml->documentElement : undef)
    , source => ref $data
    );
}

sub _parseFile($)
{   my ($thing, $fn) = @_;
    trace "parsing XML from file $fn";
    my $xml = $parser->parse_file($fn);

    ( (defined $xml ? $xml->documentElement : undef)
    , source   => 'file'
    , filename => $fn
    );
}

sub _parseFileHandle($)
{   my ($thing, $fh) = @_;
    trace "parsing XML from open file $fh";
    my $xml = $parser->parse_fh($fh);

    ( (defined $xml ? $xml->documentElement : undef)
    , source => ref $thing
    );
}

#--------------------------


sub walkTree($$)
{   my ($self, $node, $code) = @_;
    if($code->($node))
    {   $self->walkTree($_, $code)
            for $node->getChildNodes;
    }
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

    return (-f $fn ? $fn : undef)
        if File::Spec->file_name_is_absolute($fn);

    foreach my $dir (@schema_dirs)
    {   my $full = File::Spec->catfile($dir, $fn);
        return $full if -f $full;
    }

    undef;
}


1;
