# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.04.

use warnings;
use strict;

package XML::Compile::Schema;
use vars '$VERSION';
$VERSION = '0.75';
use base 'XML::Compile';

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util     qw/first/;
use XML::LibXML    ();
use File::Spec     ();
use File::Basename qw/basename/;
use Digest::MD5    qw/md5_hex/;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::Translate      ();
use XML::Compile::Schema::Instance;
use XML::Compile::Schema::NameSpaces;


sub init($)
{   my ($self, $args) = @_;
    $self->{namespaces} = XML::Compile::Schema::NameSpaces->new;
    $self->SUPER::init($args);

    $self->importDefinitions($args->{top});

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


sub addSchemas($@)
{   my ($self, $node, %opts) = @_;
    defined $node or return ();

    my @nsopts;
    push @nsopts, source   => delete $opts{source}   if $opts{source};
    push @nsopts, filename => delete $opts{filename} if $opts{filename};

    ref $node && $node->isa('XML::LibXML::Node')
        or error __x"required is a XML::LibXML::Node";

    $node = $node->documentElement
        if $node->isa('XML::LibXML::Document');

    my $nss = $self->namespaces;
    my @schemas;

    $self->walkTree
    ( $node,
      sub { my $this = shift;
            return 1 unless $this->isa('XML::LibXML::Element')
                         && $this->localname eq 'schema';

            my $schema = XML::Compile::Schema::Instance->new($this, @nsopts)
                or next;

            $nss->add($schema);
            push @schemas, $schema;
            return 0;
          }
    );
    @schemas;
}


# The cache will certainly avoid penalties by the average module user,
# which does not understand the sharing schema definitions between objects
# especially in SOAP implementations.
my (%cacheByFilestamp, %cacheByChecksum);

sub importDefinitions($@)
{   my ($self, $thing, @options) = @_;
    my @data = ref $thing eq 'ARRAY' ? @$thing : $thing;

    my @schemas;
    foreach my $data (@data)
    {   defined $data or next;
        my ($xml, %details) = $self->dataToXML($data);
        if(defined $xml)
        {   my @added = $self->addSchemas($xml, %details, @options);
            if(my $checksum = $details{checksum})
            {    $cacheByChecksum{$checksum} = \@added;
            }
            elsif(my $filestamp = $details{filestamp})
            {   $cacheByFilestamp{$filestamp} = \@added;
            }
            push @schemas, @added;
        }
        elsif(my $filestamp = $details{filestamp})
        {   my $cached = $cacheByFilestamp{$filestamp};
            $self->namespaces->add(@$cached);
        }
        elsif(my $checksum = $details{checksum})
        {   my $cached = $cacheByChecksum{$checksum};
            $self->namespaces->add(@$cached);
        }
    }
    @schemas;
}

sub _parseScalar($)
{   my ($thing, $data) = @_;
    my $checksum = md5_hex $$data;

    if($cacheByChecksum{$checksum})
    {   trace "importDefinitions reusing string data with checksum $checksum";
        return (undef, checksum => $checksum);
    }

    trace "importDefintions for scalar with checksum $checksum";
    ( $thing->SUPER::_parseScalar($data)
    , checksum => $checksum
    );
}

sub _parseFile($)
{   my ($thing, $fn) = @_;
    my ($mtime, $size) = (stat $fn)[9,7];
    my $filestamp = basename($fn) . '-'. $mtime . '-' . $size;

    if($cacheByFilestamp{$filestamp})
    {   trace "importDefinitions reusing schemas from file $filestamp";
        return (undef, filestamp => $filestamp);
    }

    trace "importDefinitions for filestamp $filestamp";
    ( $thing->SUPER::_parseFile($fn)
    , filestamp => $filestamp
    );
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
    defined $type or return ();

    if(exists $args{validation})
    {   $args{check_values}  =   $args{validation};
        $args{check_occurs}  =   $args{validation};
        $args{ignore_facets} = ! $args{validation};
    }
    else
    {   exists $args{check_values}   or $args{check_values} = 1;
        exists $args{check_occurs}   or $args{check_occurs} = 1;
    }

    exists $args{include_namespaces} or $args{include_namespaces} = 1;
    $args{sloppy_integers}   ||= 0;
    unless($args{sloppy_integers})
    {   eval "require Math::BigInt";
        fault "require Math::BigInt or sloppy_integers:\n$@"
            if $@;

        eval "require Math::BigFloat";
        fault "require Math::BigFloat or sloppy_integers:\n$@"
            if $@;
    }

    my $outns = $args{output_namespaces} ||= {};
    if(ref $outns eq 'ARRAY')
    {   my @ns = @$outns;
        $outns = $args{output_namespaces} = {};
        while(@ns)
        {   my ($prefix, $uri) = (shift @ns, shift @ns);
            $outns->{$uri} = { uri => $uri, prefix => $prefix };
        }
    }

    my $saw_default = 0;
    foreach (values %$outns)
    {   $_->{used} = 0 if $args{namespace_reset};
        $saw_default ||= $_->{prefix} eq '';
    }

    $outns->{''} = {uri => '', prefix => '', used => 0}
        if !$saw_default && !$args{use_default_prefix};

    my $nss   = $self->namespaces;

    my ($h1, $h2) = (delete $args{hook}, delete $args{hooks});
    my @hooks = $self->hooks;
    push @hooks, ref $h1 eq 'ARRAY' ? @$h1 : $h1 if $h1;
    push @hooks, ref $h2 eq 'ARRAY' ? @$h2 : $h2 if $h2;

    my $impl
     = $action eq 'READER' ? 'XmlReader'
     : $action eq 'WRITER' ? 'XmlWriter'
     : error __x"create only READER, WRITER, not '{action}'"
           , action => $action;

    my $bricks = "XML::Compile::Schema::$impl";
    eval "require $bricks";
    fault $@ if $@;

    XML::Compile::Schema::Translate->compileTree
     ( $type, %args
     , bricks => $bricks
     , nss    => $self->namespaces
     , hooks  => \@hooks
     , action => $action
     );
}


sub template($@)
{   my ($self, $action, $type, %args) = @_;

    my $show = exists $args{show} ? $args{show} : 'ALL';
    $show = 'struct,type,occur,facets' if $show eq 'ALL';
    $show = '' if $show eq 'NONE';
    my @comment = map { ("show_$_" => 1) } split m/\,/, $show;

    my $nss = $self->namespaces;

    my $indent                  = $args{indent} || "  ";
    $args{check_occurs}         = 1;
    $args{include_namespaces} ||= 1;

    my $bricks = 'XML::Compile::Schema::Template';
    eval "require $bricks";
    fault $@ if $@;

    my $compiled = XML::Compile::Schema::Translate->compileTree
     ( $type
     , bricks => $bricks
     , nss    => $self->namespaces
     , hooks  => []
     , action => 'READER'
     , %args
     );

    my $ast = $compiled->();
# use Data::Dumper; $Data::Dumper::Indent = 1; warn Dumper $ast;

    if($action eq 'XML')
    {   my $doc  = XML::LibXML::Document->new('1.1', 'UTF-8');
        my $node = $bricks->toXML($doc,$ast, @comment, indent => $indent);
        return $node->toString(1);
    }

    if($action eq 'PERL')
    {   return $bricks->toPerl($ast, @comment, indent => $indent);
    }

    error __x"template output is either in XML or PERL layout, not '{action}'"
        , action => $action;
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
