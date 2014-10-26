# Copyrights 2006-2011 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.00.

use warnings;
use strict;

package XML::Compile::Schema::NameSpaces;
use vars '$VERSION';
$VERSION = '1.22';


use Log::Report 'xml-compile', syntax => 'SHORT';

use XML::Compile::Util
  qw/pack_type unpack_type pack_id unpack_id SCHEMA2001/;

use XML::Compile::Schema::BuiltInTypes qw/%builtin_types/;


sub new($@)
{   my $class = shift;
    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->{tns} = {};
    $self->{sgs} = {};
    $self->{use} = [];
    $self;
}


sub list() { keys %{shift->{tns}} }


sub namespace($)
{   my $nss  = $_[0]->{tns}{$_[1]};
    $nss ? @$nss : ();
}


sub add(@)
{   my $self = shift;
    foreach my $instance (@_)
    {   unshift @{$self->{tns}{$_}}, $instance
	    for $instance->tnses;

        while(my($base,$ext) = each %{$instance->sgs})
        {   $self->{sgs}{$base}{$_} ||= $instance for @$ext;
        }
    }
    @_;
}


sub use($)
{   my $self = shift;
    push @{$self->{use}}, @_;
    @{$self->{use}};
}


sub schemas($) { $_[0]->namespace($_[1]) }


sub allSchemas()
{   my $self = shift;
    map {$self->schemas($_)} $self->list;
}


sub find($$;$)
{   my ($self, $kind) = (shift, shift);
    my ($ns, $name) = (@_%2==1) ? (unpack_type shift) : (shift, shift);
    my %opts = @_;

    defined $ns or return undef;
    my $label = pack_type $ns, $name; # re-pack unpacked for consistency

    foreach my $schema ($self->schemas($ns))
    {   my $def = $schema->find($kind, $label);
        return $def if defined $def;
    }

    my $used = exists $opts{include_used} ? $opts{include_used} : 1;
    $used or return undef;

    foreach my $use ( @{$self->{use}} )
    {   my $def = $use->namespaces->find($kind, $label, include_used => 0);
        return $def if defined $def;
    }

    undef;
}


sub doesExtend($$)
{   my ($self, $ext, $base) = @_;
    return 1 if $ext eq $base;

    my ($node, $super);
    if(my $st = $self->find(simpleType => $ext))
    {   # pure simple type
        $node = $st->{node};
        if(my($res) = $node->getChildrenByLocalName('restriction'))
        {   $super = $res->getAttribute('base');
        }
        # list an union currently ignored
    }
    elsif(my $ct = $self->find(complexType => $ext))
    {   $node = $ct->{node};
        # getChildrenByLocalName returns list, we know size one
        if(my($sc) = $node->getChildrenByLocalName('simpleContent'))
        {   # tagged
            if(my($ex) = $sc->getChildrenByLocalName('extension'))
            {   $super = $ex->getAttribute('base');
            }
            elsif(my($res) = $sc->getChildrenByLocalName('restriction'))
            {   $super = $res->getAttribute('base');
            }
        }
        elsif(my($cc) = $node->getChildrenByLocalName('complexContent'))
        {   # real complex
            if(my($ex) = $cc->getChildrenByLocalName('extension'))
            {   $super = $ex->getAttribute('base');
            }
            elsif(my($res) = $cc->getChildrenByLocalName('restriction'))
            {   $super = $res->getAttribute('base');
            }
        }
    }
    else
    {   # build-in
        my ($ns, $local) = unpack_type $ext;
        $ns eq SCHEMA2001 && $builtin_types{$local}
            or error __x"cannot find {type} as simpleType or complexType"
                 , type => $ext;
        my ($bns, $blocal) = unpack_type $base;
        $ns eq $bns
            or return 0;

        while(my $e = $builtin_types{$local}{extends})
        {   return 1 if $e eq $blocal;
            $local = $e;
        }
    }

    $super
        or return 0;

    my ($prefix, $local) = $super =~ m/:/ ? split(/:/,$super,2) : ('',$super);
    my $supertype = pack_type $node->lookupNamespaceURI($prefix), $local;

    $base eq $supertype ? 1 : $self->doesExtend($supertype, $base);
}


sub findSgMembers($$)
{   my ($self, $class, $base) = @_;
    my $s = $self->{sgs}{$base}
        or return;

    my @sgs;
    while(my($ext, $instance) = each %$s)
    {   push @sgs, $instance->find($class => $ext)
          , $self->findSgMembers($class, $ext);
    }
    @sgs;
}


sub findID($;$)
{   my $self = shift;
    my ($label, $ns, $id)
      = @_==1 ? ($_[0], unpack_id $_[0]) : (pack_id($_[0], $_[1]), @_);
    defined $ns or return undef;

    my $xpc = XML::LibXML::XPathContext->new;
    $xpc->registerNs(a => $ns);

    my @nodes;
    foreach my $fragment ($self->schemas($ns))
    {   @nodes = $xpc->findnodes("/*/a:*#$id", $fragment->schema)
	    or next;

	return $nodes[0]
	    if @nodes==1;

        error "multiple elements with the same id {id} in {source}"
	  , id => $label
	  , source => ($fragment->filename || $fragment->source);
    }

    undef;
}


sub printIndex(@)
{   my $self = shift;
    my $fh   = @_ % 2 ? shift : select;
    my %opts = @_;

    my $nss  = delete $opts{namespace} || [$self->list];
    foreach my $nsuri (ref $nss eq 'ARRAY' ? @$nss : $nss)
    {   $_->printIndex($fh, %opts) for $self->namespace($nsuri);
    }

    my $show_used = exists $opts{include_used} ? $opts{include_used} : 1;
    foreach my $use ($self->use)
    {   $use->printIndex(%opts, include_used => 0);
    }

    $self;
}

1;
