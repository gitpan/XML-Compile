# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.05.

package XML::Compile::Schema;
use vars '$VERSION';
$VERSION = '0.94';

use base 'XML::Compile';

use warnings;
use strict;

use Log::Report 'xml-compile', syntax => 'SHORT';
use List::Util     qw/first/;
use XML::LibXML    ();
use File::Spec     ();
use File::Basename qw/basename/;
use Digest::MD5    qw/md5_hex/;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::Instance;
use XML::Compile::Schema::NameSpaces;

use XML::Compile::Translate      ();


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
 
    $self->{key_rewrite} = [];
    if(my $kr = $args->{key_rewrite})
    {   $self->addKeyRewrite(ref $kr eq 'ARRAY' ? @$kr : $kr);
    }

    $self->{typemap}     = $args->{typemap} || {};
    $self->{unused_tags} = $args->{ignore_unused_tags};

    $self;
}

#--------------------------------------


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


sub addTypemaps(@)
{   my $map = shift->{typemap};
    while(@_ > 1)
    {   my $k = shift;
        $map->{$k} = shift;
    }
    $map;
}
*addTypemap = \&addTypemaps;


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
                         && $this->localName eq 'schema';

            my $schema = XML::Compile::Schema::Instance->new($this, @nsopts)
                or next;

            $nss->add($schema);
            push @schemas, $schema;
            return 0;
          }
    );
    @schemas;
}


sub addKeyRewrite(@)
{   my $self = shift;
    unshift @{$self->{key_rewrite}}, @_;
    @{$self->{key_rewrite}};
}

#--------------------------------------


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

    my $iut = exists $args{ignore_unused_tags} ? $args{ignore_unused_tags}
      : $self->{unused_tags};
    $args{ignore_unused_tags}
      = !defined $iut ? undef : ref $iut eq 'Regexp' ? $iut : qr/^/;

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

    my $prefs = $args{prefixes} = $self->_namespaceTable
       ( ($args{prefixes} || $args{output_namespaces})
       , $args{namespace_reset}
       , !($args{use_default_namespace} || $args{use_default_prefix})
         # use_default_prefix renamed in 0.90
       );

    my $nss   = $self->namespaces;

    my ($h1, $h2) = (delete $args{hook}, delete $args{hooks});
    my @hooks = $self->hooks;
    push @hooks, ref $h1 eq 'ARRAY' ? @$h1 : $h1 if $h1;
    push @hooks, ref $h2 eq 'ARRAY' ? @$h2 : $h2 if $h2;

    my %map = ( %{$self->{typemap}}, %{$args{typemap} || {}} );
    trace "schema compile $action for $type";

    my @rewrite = @{$self->{key_rewrite}};
    my $kw = delete $args{key_rewrite} || [];
    unshift @rewrite, ref $kw eq 'ARRAY' ? @$kw : $kw;

    $args{mixed_elements} ||= 'ATTRIBUTES';
    $args{default_values} ||= $action eq 'READER' ? 'EXTEND' : 'IGNORE';

    # Option rename in 0.88
    $args{any_element}    ||= delete $args{anyElement};
    $args{any_attribute}  ||= delete $args{anyAttribute};

    my $transl = XML::Compile::Translate->new
     ( $action
     , nss     => $self->namespaces
     );

    $transl->compile
     ( $type, %args
     , hooks   => \@hooks
     , typemap => \%map
     , rewrite => \@rewrite
     );
}

# also used in ::Cache init()
sub _namespaceTable($;$$)
{   my ($self, $table, $reset_count, $block_default) = @_;
    $table = { reverse @$table }
        if ref $table eq 'ARRAY';

    $table->{$_} = { uri => $_, prefix => $table->{$_} }
        for grep {ref $table->{$_} ne 'HASH'} keys %$table;

    do { $_->{used} = 0 for values %$table }
        if $reset_count;

    $table->{''} = {uri => '', prefix => '', used => 0}
        if $block_default && !grep {$_->{prefix} eq ''} values %$table;

    $table;
}


sub template($@)
{   my ($self, $action, $type, %args) = @_;

    my $show
      = exists $args{show_comments} ? $args{show_comments}
      : exists $args{show} ? $args{show} # pre-0.79 option name 
      : 'ALL';

    $show = 'struct,type,occur,facets' if $show eq 'ALL';
    $show = '' if $show eq 'NONE';
    my @comment = map { ("show_$_" => 1) } split m/\,/, $show;

    my $nss = $self->namespaces;

    my $indent                  = $args{indent} || "  ";
    $args{check_occurs}         = 1;
    $args{include_namespaces} ||= 1;
    $args{mixed_elements}     ||= 'ATTRIBUTES';
    $args{default_values}     ||= 'EXTEND';

    # it could be used to add extra comment lines
    error __x"typemaps not implemented for XML template examples"
        if $action eq 'XML' && defined $args{typemap} && keys %{$args{typemap}};

    my @rewrite = @{$self->{key_rewrite}};
    my $kw = delete $args{key_rewrite} || [];
    unshift @rewrite, ref $kw eq 'ARRAY' ? @$kw : $kw;

    my $transl = XML::Compile::Translate->new
     ( 'TEMPLATE'
     , nss     => $self->namespaces
     );

    my $compiled = $transl->compile
     ( $type
     , rewrite => \@rewrite
     , %args
     );

    my $ast = $compiled->();
#use Data::Dumper; $Data::Dumper::Indent = 1; warn Dumper $ast;

    if($action eq 'XML')
    {   my $doc  = XML::LibXML::Document->new('1.1', 'UTF-8');
        my $node = $transl->toXML($doc,$ast, @comment, indent => $indent);
        return $node->toString(1);
    }

    return $transl->toPerl($ast, @comment, indent => $indent)
        if $action eq 'PERL';

    error __x"template output is either in XML or PERL layout, not '{action}'"
        , action => $action;
}

#------------------------------------------


sub namespaces() { shift->{namespaces} }


# The cache will certainly avoid penalties by the average module user,
# which does not understand the sharing schema definitions between objects
# especially in SOAP implementations.
my (%schemaByFilestamp, %schemaByChecksum);

sub importDefinitions($@)
{   my ($self, $thing, %options) = @_;
    my @data = ref $thing eq 'ARRAY' ? @$thing : $thing;

    my @schemas;
    foreach my $data (@data)
    {   defined $data or next;
        my ($xml, %details) = $self->dataToXML($data);
        %details = %{delete $options{details}} if $options{details};

        if(defined $xml)
        {   my @added = $self->addSchemas($xml, %details, %options);
            if(my $checksum = $details{checksum})
            {   $schemaByChecksum{$checksum} = \@added;
            }
            elsif(my $filestamp = $details{filestamp})
            {   $schemaByFilestamp{$filestamp} = \@added;
            }
            push @schemas, @added;
        }
        elsif(my $filestamp = $details{filestamp})
        {   my $cached = $schemaByFilestamp{$filestamp};
            $self->namespaces->add(@$cached);
        }
        elsif(my $checksum = $details{checksum})
        {   my $cached = $schemaByChecksum{$checksum};
            $self->namespaces->add(@$cached);
        }
    }
    @schemas;
}

sub _parseScalar($)
{   my ($thing, $data) = @_;
    my $checksum = md5_hex $$data;

    if($schemaByChecksum{$checksum})
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

    if($schemaByFilestamp{$filestamp})
    {   trace "importDefinitions reusing schemas from file $filestamp";
        return (undef, filestamp => $filestamp);
    }

    trace "importDefinitions for filestamp $filestamp";
    ( $thing->SUPER::_parseFile($fn)
    , filestamp => $filestamp
    );
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


sub printIndex(@)
{   my $self = shift;
    $self->namespaces->printIndex(@_);
}


1;
