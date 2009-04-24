# Copyrights 2006-2009 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.06.

use warnings;
use strict;

package XML::Compile::Schema::NameSpaces;
use vars '$VERSION';
$VERSION = '1.04';


use Log::Report 'xml-compile', syntax => 'SHORT';

use XML::Compile::Util qw/pack_type unpack_type pack_id unpack_id/;


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
    foreach my $schema (@_)
    {   unshift @{$self->{tns}{$schema->targetNamespace}}, $schema;
        $schema->mergeSubstGroupsInto($self->{sgs});
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


sub findSgMembers($;$)
{   my $self = shift;
    my $type = @_==2 ? pack_type(@_) : shift;
    @{ $self->{sgs}{$type} || [] };
}


sub findID($;$)
{   my $self = shift;
    my ($label, $ns, $id)
      = @_==1 ? ($_[0], unpack_id $_[0]) : (pack_id($_[0], $_[1]), @_);
    defined $ns or return undef;

    foreach my $schema ($self->schemas($ns))
    {   my $def = $schema->id($label);
        return $def if defined $def;
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
