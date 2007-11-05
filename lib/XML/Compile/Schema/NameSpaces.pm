# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.

use warnings;
use strict;

package XML::Compile::Schema::NameSpaces;
use vars '$VERSION';
$VERSION = '0.57';

use Log::Report 'xml-compile', syntax => 'SHORT';

use XML::Compile::Util qw/pack_type unpack_type pack_id unpack_id/;


sub new($@)
{   my $class = shift;
    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->{tns} = {};
    $self;
}


sub list() { keys %{shift->{tns}} }


sub namespace($)
{   my $self = shift;
    my $nss  = $self->{tns}{(shift)};
    $nss ? @$nss : ();
}


sub add($)
{   my ($self, $schema) = @_;
    my $tns = $schema->targetNamespace;
    unshift @{$self->{tns}{$tns}}, $schema;
    $schema;
}


sub schemas($)
{   my ($self, $ns) = @_;
    $self->namespace($ns);
}


sub allSchemas()
{   my $self = shift;
    map {$self->schemas($_)} $self->list;
}


sub find($$;$)
{   my ($self, $kind) = (shift, shift);
    my ($label, $ns, $name)
      = @_==1 ? ($_[0], unpack_type $_[0]) : (pack_type($_[0], $_[1]), @_);

    defined $ns or return undef;

    foreach my $schema ($self->schemas($ns))
    {   my $def = $schema->find($kind, $label);
        return $def if defined $def;
    }

    undef;
}


sub findSgMembers($;$)
{   my $self = shift;
    my ($label, $ns, $name)
      = @_==1 ? ($_[0], unpack_type $_[0]) : (pack_type($_[0], $_[1]), @_);
    defined $ns or return undef;

    map {$_->substitutionGroupMembers($label)}
        $self->allSchemas;
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

1;
