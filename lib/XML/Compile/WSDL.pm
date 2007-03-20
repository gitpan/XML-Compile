# Copyrights 2006-2007 by Mark Overmeer.
# For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 0.99.
use warnings;
use strict;

package XML::Compile::WSDL;
use vars '$VERSION';
$VERSION = '0.17';
use base 'XML::Compile';

use Carp;
use List::Util     qw/first/;

use XML::Compile::Schema          ();
use XML::Compile::SOAP::Operation ();

my $wsdl1 = 'http://schemas.xmlsoap.org/wsdl/';


sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);

    $self->{schemas} = XML::Compile::Schema->new(undef, %$args);
    $self->{index}   = {};
    $self->{wsdl_ns} = $args->{wsdl_namespace};

    $self->addWSDL($args->{top});
    $self;
}


sub schemas() { shift->{schemas} }


sub wsdlNamespace(;$)
{   my $self = shift;
    @_ ? ($self->{wsdl_ns} = shift) : $self->{wsdl_ns};
}


sub addWSDL($)
{   my ($self, $data) = @_;
    defined $data or return;
    my $node = $self->dataToXML($data);

    $node    = $node->documentElement
        if $node->isa('XML::LibXML::Document');

    croak "ERROR: root element for WSDL is not 'definitions'"
        if $node->localName ne 'definitions';

    my $wsdlns  = $node->namespaceURI;
    my $corens  = $self->wsdlNamespace || $self->wsdlNamespace($wsdlns);
    croak "ERROR: wsdl in namespace $wsdlns, where already using $corens"
        if $corens ne $wsdlns;

    my $schemas = $self->schemas;
    $schemas->importData($wsdlns);      # to understand WSDL
    $schemas->importData("$wsdlns#patch");

    croak "ERROR: don't known how to handle $wsdlns WSDL files"
        if $wsdlns ne $wsdl1;

    my %hook_kind = (type => "{$wsdlns}tOperation", after => 'ELEMENT_ORDER');

    my $reader  = $schemas->compile     # to parse the WSDL
     ( READER => "{$wsdlns}definitions"
     , anyElement   => 'TAKE_ALL'
     , anyAttribute => 'TAKE_ALL'
     , hook         => \%hook_kind
     );

    my $spec = $reader->($node);
    my $tns  = $spec->{targetNamespace}
        or croak "ERROR: WSDL sets no targetNamespace";

    # there can be multiple <types>, which each a list of <schema>'s
    foreach my $type ( @{$spec->{types} || []} )
    {   foreach my $k (keys %$type)
        {   next unless $k =~ m/^\{[^}]*\}schema$/;
            $schemas->addSchemas(@{$type->{$k}});
        }
    }

    # WSDL 1.1 par 2.1.1 says: WSDL defs all in own name-space
    my $index = $self->{index};
    foreach my $def ( qw/service message binding portType/ )
    {   foreach my $toplevel ( @{$spec->{$def} || []} )
        {   $index->{$def}{"{$tns}$toplevel->{name}"} = $toplevel;
        }
    }

   foreach my $service ( @{$spec->{service} || []} )
   {   foreach my $port ( @{$service->{port} || []} )
       {   $index->{port}{"{$tns}$port->{name}"} = $port;
       }
   }

   $self;
}


sub addSchemas($) { shift->schemas->addSchemas(@_) }


sub namesFor($)
{   my ($self, $class) = @_;
    keys %{shift->index($class) || {}};
}


sub operation(@)
{   my $self = shift;
    my $name = @_ % 2 ? shift : undef;
    my %args = @_;

    my $service   = $self->find(service => delete $args{service});

    my $port;
    my @ports     = @{$service->{port} || []};
    my @portnames = map {$_->{name}} @ports;
    if(my $portname = delete $args{port})
    {   $port = first {$_->{name} eq $portname} @ports;
        croak "ERROR: cannot find port '$portname', pick from"
            . join("\n    ", '', @portnames)
           unless $port;
    }
    elsif(@ports==1)
    {   $port = shift @ports;
    }
    else
    {   croak "ERROR: specify port explicitly, pick from"
            . join("\n    ", '', @portnames);
    }

    my $bindname  = $port->{binding}
        or croak "ERROR: no binding defined in port $port->{name}";

    my $binding   = $self->find(binding => $bindname);

    my $type      = $binding->{type}
        or croak "ERROR: no type defined with binding '$bindname'";

    my $portType  = $self->find(portType => $type);
    my $types     = $portType->{operation}
        or croak "ERROR: no operations defined for portType '$type'";
    my @port_ops  = map {$_->{name}} @$types;

    $name       ||= delete $args{operation};
    my $port_op;
    if(defined $name)
    {   $port_op = first {$_->{name} eq $name} @$types;
        croak "ERROR: no operation '$name' for portType '$type', pick from"
            . join("\n    ", '', @port_ops)
            unless $port_op;
    }
    elsif(@port_ops==1)
    {   $port_op = shift @port_ops;
    }
    else
    {   croak "ERROR: multiple operations in portType '$type', select from"
            . join("\n    ", '', @port_ops)
    }

    my @bindops = @{$binding->{operation} || []};
    my $bind_op = first {$_->{name} eq $name} @bindops;

    my $operation = XML::Compile::SOAP::Operation->new
     ( service        => $service
     , port           => $port
     , binding        => $binding
     , portType       => $portType
     , schemas        => $self->schemas
     , portOperation  => $port_op
     , bindOperation  => $bind_op
     );

    $operation;
}


sub prepare(@)
{   my $self = shift;
    unshift @_, 'operation' if @_ % 2;
    my $op   = $self->operation(@_) or return ();
    $op->prepare(@_);
}


sub index(;$$)
{   my $index = shift->{index};
    @_ or return $index;

    my $class = $index->{ (shift) }
       or return ();

    @_ ? $class->{ (shift) } : $class;
}


sub find($;$)
{   my ($self, $class, $name) = @_;
    my $group = $self->index($class)
        or croak "ERROR: no definitions for ${class}s found\n";

    if(defined $name)
    {   return $group->{$name} if exists $group->{$name};
        croak "ERROR: no definition for '$name' as $class.  Defined "
            . (keys %$group==1 ? 'is' : 'are')
            . join("\n    ", '', sort keys %$group) . "\n";
    }

    return values %$group
        if wantarray;

    return (values %$group)[0]
        if keys %$group==1;

    croak "ERROR: explicit selection required: pick one $class from"
        . join("\n    ", '', sort keys %$group) . "\n";
}

1;
