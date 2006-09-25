
use warnings;
use strict;

package XML::Compile::Schema::NameSpaces;
use vars '$VERSION';
$VERSION = '0.09';

use Carp;


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
    push @{$self->{tns}{$tns}}, $schema;
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


sub findElement($;$)
{   my ($self, $ns, $name) = @_;
    my $label  = $ns;
    if(defined $name) { $label = "{$ns}$name" }
    elsif($label =~ m/^\s*\{(.*)\}(.*)/) { ($ns, $name) = ($1, $2) }
    else { return undef  } 

    foreach my $schema ($self->schemas($ns))
    {   my $def = $schema->element($label);
        return $def if defined $def;
    }

    undef;
}


sub findType($;$)
{   my ($self, $ns, $name) = @_;
    my $label  = $ns;
    if(defined $name) { $label = "{$ns}$name" }
    elsif($label =~ m/^\s*\{(.*)\}(.*)/) { ($ns, $name) = ($1, $2) }
    else { return undef  } 

    foreach my $schema ($self->schemas($ns))
    {   my $def = $schema->type($label);
        return $def if defined $def;
    }

    undef;
}



sub findSgMembers($;$)
{   my ($self, $ns, $name) = @_;
    my $label  = $ns;
    if(defined $name) { $label = "{$ns}$name" }
    elsif($label =~ m/^\s*\{(.*)\}(.*)/) { ($ns, $name) = ($1, $2) }
    else { return undef  } 

    map {$_->substitutionGroupMembers($label)}
        $self->allSchemas;
}


sub findID($;$)
{   my ($self, $ns, $name) = @_;
    my $label  = $ns;
    if(defined $name) { $label = "$ns#$name" }
    elsif($label =~ m/\#/) { ($ns, $name) = split /\#/,$label,2 }
    else { return undef  } 

    foreach my $schema ($self->schemas($ns))
    {   my $def = $schema->id($label);
        return $def if defined $def;
    }

    undef;
}

1;
