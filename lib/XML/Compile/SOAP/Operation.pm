# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.00.
use warnings;
use strict;

package XML::Compile::SOAP::Operation;
use vars '$VERSION';
$VERSION = '0.18';

use Carp;
use List::Util  'first';

my $soap1 = 'http://schemas.xmlsoap.org/wsdl/soap/';
my $http1 = 'http://schemas.xmlsoap.org/soap/http';


sub new(@)
{   my $class = shift;
    (bless {@_}, $class)->init;
}

sub init()
{   my $self = shift;

    # autodetect namespaces used
    my $soapns = $self->{soap_ns}
      = exists $self->port->{ "{$soap1}address" } ? $soap1
      : croak "ERROR: soap namespace not supported";

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
    my $addrtype = "{$soapns}address";

    my $addrxml  = $self->port->{$addrtype}
        or croak "ERROR: soap end-point address not found in service port.\n";

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
        my $bindtype = "{$soapns}binding";

        my $bindxml  = $self->binding->{$bindtype}
            or croak "ERROR: soap transport binding not found in binding.\n";

        my $bind_r   = $self->schemas->compile(READER => $bindtype);
  
        my @bindings = map {$bind_r->($_)} @$bindxml;
        $_->{style} ||= 'document' for @bindings;
        $self->{trans} = $trans = \@bindings;
    }

    my @proto = grep {$_->{transport} eq $proto} @$trans;
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
        my $optype = "{$soapns}operation";

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

# parsing of input and output wrong: both lists.  Schema parser gets
# confused by <choice><group><group>.  Needs a hook
    my @po_in    = @{$port->{input}  || []};
    my @po_out   = @{$port->{output} || []};
    my @po_fault = @{$port->{fault}  || []};
    my $bi_in    = $bind->{input};
    my $bi_out   = $bind->{output};
    my $bi_fault = $bind->{fault};

    my (@readers, @writers);
    if($role eq 'CLIENT')
    {   @readers = map {$self->_message_reader(\%args, $_, $bi_out)}
           @po_out;

        @writers = map {$self->_message_writer(\%args, $_, $bi_in)}
           @po_in;

        push @readers, map {$self->_message_reader(\%args, $_, $bi_fault)}
           @po_fault;
    }
    elsif($role eq 'SERVER')
    {   @readers = map {$self->_message_reader(\%args, $_, $bi_in)}
           @po_in;

        @writers = map {$self->_message_writer(\%args, $_, $bi_out)}
           @po_out;

        push @writers, map {$self->_message_reader(\%args, $_, $bi_fault)}
           @po_fault;
    }
    else
    {   croak "ERROR: WSDL role must be CLIENT or SERVER, not '$role'"; 
    }

    my $soapns  = $self->soapNamespace;
    my $addrs   = $self->endPointAddresses;

    my $proto   = $args{protocol}  || $self->{protocol}  || 'HTTP';
    $proto = $http1 if $proto eq 'HTTP';

    my $style   = $args{soapStyle} || $self->{soapStyle} || 'document';

    $self->canTransport($proto, $style)
        or croak "ERROR: transport $proto as $style not defined in WSDL";

    $proto eq $http1
        or die "SORRY: only transport of HTTP ($proto) implemented\n";

    $style eq 'document'
        or die "SORRY: only transport style 'document' implemented\n";

    # http requires soapAction
    my ($action, undef) = $self->soapAction;

    croak "ERROR: work in progress: implementation not finished";
}

sub _message_reader($$$)
{   my ($self, $args, $message, $bind) = @_;
    ();
}

sub _message_writer($$$)
{   my ($self, $args, $message, $bind) = @_;
    ();
}

1;

