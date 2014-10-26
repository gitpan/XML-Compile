# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.
use warnings;
use strict;

package XML::Compile::SOAP::Operation;
use vars '$VERSION';
$VERSION = '0.54';

use Log::Report 'xml-report', syntax => 'SHORT';
use List::Util  'first';

use XML::Compile::Util   qw/pack_type/;
use Data::Dumper;  # needs to go away

my $soap1 = 'http://schemas.xmlsoap.org/wsdl/soap/';
my $http1 = 'http://schemas.xmlsoap.org/soap/http';


sub new(@)
{   my $class = shift;
    (bless {@_}, $class)->init;
}

sub init()
{   my $self = shift;

    # autodetect namespaces used
    my $soapns  = $self->{soap_ns}
      = exists $self->port->{ pack_type $soap1, 'address' } ? $soap1
      : error __x"soap namespace {namespace} not (yet) supported"
            , namespace => $soap1;

    $self->schemas->importDefinitions($soapns);

    # This should be detected while parsing the WSDL because the order of
    # input and output is significant (and lost), but WSDL 1.1 simplifies
    # our life by saying that only 2 out-of 4 predefined types can actually
    # be used at present.
    my @order    = @{$self->portOperation->{_ELEMENT_ORDER}};
    my ($first_in, $first_out);
    for(my $i = 0; $i<@order; $i++)
    {   $first_in  = $i if !defined $first_in  && $order[$i] eq 'input';
        $first_out = $i if !defined $first_out && $order[$i] eq 'output';
    }

    $self->{kind}
      = !defined $first_in     ? 'notification-operation'
      : !defined $first_out    ? 'one-way'
      : $first_in < $first_out ? 'request-response'
      :                          'solicit-response';

    $self->{protocol}  ||= 'HTTP';
    $self->{soapStyle} ||= 'document';
    $self;
}


sub service()  {shift->{service}}
sub port()     {shift->{port}}
sub binding()  {shift->{binding}}
sub portType() {shift->{portType}}
sub schemas()  {shift->{schemas}}

sub portOperation() {shift->{portOperation}}
sub bindOperation() {shift->{bindOperation}}


sub soapNamespace() {shift->{soap_ns}}


sub endPointAddresses()
{   my $self = shift;
    return @{$self->{addrs}} if $self->{addrs};

    my $soapns   = $self->soapNamespace;
    my $addrtype = pack_type $soapns, 'address';

    my $addrxml  = $self->port->{$addrtype}
        or error __x"soap end-point address not found in service port";

    my $addr_r   = $self->schemas->compile(READER => $addrtype);

    my @addrs    = map {$addr_r->($_)->{location}} @$addrxml;
    $self->{addrs} = \@addrs;
    @addrs;
}


sub canTransport($$)
{   my ($self, $proto, $style) = @_;
    my $trans = $self->{trans};

    unless($trans)
    {   # collect the transport information
        my $soapns   = $self->soapNamespace;
        my $bindtype = pack_type $soapns, 'binding';

        my $bindxml  = $self->binding->{$bindtype}
            or error __x"soap transport binding not found in binding";

        my $bind_r   = $self->schemas->compile(READER => $bindtype);
  
        my %bindings = map {$bind_r->($_)} @$bindxml;
        $_->{style} ||= 'document' for values %bindings;
        $self->{trans} = $trans = \%bindings;
    }

    my @proto = grep {$_->{transport} eq $proto} values %$trans;
    @proto or return ();

    my ($action, $op_style) = $self->action;
    return $op_style eq $style if defined $op_style; # explicit style

    first {$_->{style} eq $style} @proto;            # the default style
}


sub action()
{   my $self   = shift;
    my $action = $self->{action};

    unless($action)
    {   # collect the action information
        my $soapns = $self->soapNamespace;
        my $optype = pack_type $soapns, 'operation';

        my @action;
        my $opxml = $self->bindOperation->{$optype};
        if($opxml)
        {   my $op_r   = $self->schemas->compile(READER => $optype);

            my $binding
             = @$opxml > 1
             ? first {$_->{style} eq $self->soapStyle} @$opxml
             : $opxml->[0];

            my $opdata = $op_r->($binding);
            @action    = @$opdata{ qw/soapAction style/ };
        }
        $action = $self->{action} = \@action;
    }

    @$action;
}


sub kind() {shift->{kind}}


sub prepare(@)
{   my ($self, %args) = @_;
    my $role     = $args{role} || 'CLIENT';
    my $port     = $self->portOperation;
    my $bind     = $self->bindOperation;
warn Dumper $port;

    my @po_fault = @{$port->{fault}  || []};
    my $bi_in    = $bind->{input};
    my $bi_out   = $bind->{output};
    my $bi_fault = $bind->{fault};

    my (@readers, @writers);
    if($role eq 'CLIENT')
    {   @readers = $self->_message_reader(\%args, $port->{output}, $bi_out);
        @writers = $self->_message_writer(\%args, $port->{input}, $bi_in);

        push @readers, map {$self->_message_reader(\%args, $_, $bi_fault)}
           @po_fault;
    }
    elsif($role eq 'SERVER')
    {   @readers = $self->_message_reader(\%args, $port->{input}, $bi_out);
        @writers = $self->_message_writer(\%args, $port->{output}, $bi_in);
        push @writers, map {$self->_message_reader(\%args, $_, $bi_fault)}
           @po_fault;
    }
    else
    {   error __x"WSDL role must be CLIENT or SERVER, not '{role}'"
            , role => $role; 
    }

    my $soapns = $self->soapNamespace;
    my $addrs  = $self->endPointAddresses;

    my $proto  = $args{protocol}  || $self->{protocol}  || 'HTTP';
    $proto     = $http1 if $proto eq 'HTTP';

    my $style  = $args{soapStyle} || $self->{soapStyle} || 'document';

    $self->canTransport($proto, $style)
        or error __x"transport {protocol} as {style} not defined in WSDL"
               , protocol => $proto, style => $style;

    $proto eq $http1
        or error __x"SORRY: only transport of HTTP implemented, not {protocol}"
               , protocol => $proto;

    $style eq 'document'
        or error __x"SORRY: only transport style 'document' implemented";

    # http requires soapAction
    my ($action, undef) = $self->soapAction;

    panic "work in progress: implementation not finished";
}

my $bind_body_reader;
sub _message_reader($$$)
{   my ($self, $args, $protop, $bind) = @_;

    my $type = $protop->{message}
        or error __x"no message type in portOperation input";

    my $binding = $bind->{"{$soap1}body"}
        or error __x"no input binding operation body";

    $bind_body_reader ||= $self->schemas->compile(READER => "{$soap1}body");
    my @bind_data = map { $bind_body_reader->($_)} @$binding;
warn Dumper $type, \@bind_data;
    ();
}

sub _message_writer($$$)
{   my ($self, $args, $protop, $bind) = @_;
    ();
}

1;

