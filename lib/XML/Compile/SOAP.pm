# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.
use warnings;
use strict;

package XML::Compile::SOAP;
use vars '$VERSION';
$VERSION = '0.53';

use Log::Report 'xml-compile', syntax => 'SHORT';
use XML::Compile::Util  qw/pack_type/;


sub new($@)
{   my $class = shift;
    error __x"you can only instantiate sub-classes of {class}"
        if $class eq __PACKAGE__;

    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->{env}     = $args->{envelope_ns} || panic "no envelope namespace";
    $self->{enc}     = $args->{encoding_ns} || panic "no encoding namespace";
    $self->{mime}    = $args->{media_type}  || 'application/soap+xml';
    $self->{schemas} = $args->{schemas}     || XML::Compile::Schema->new;
    $self;
}


sub envelopeNS() {shift->{env}}
sub encodingNS() {shift->{enc}}


sub schemas()    {shift->{schemas}}


sub compile($@)
{   my ($self, $role, $inout, %args) = @_;

    my $action = $self->direction($role, $inout);

    die "ERROR: an input message does not have faults\n"
        if $inout eq 'INPUT'
        && ($args{headerfault} || $args{fault});

      $action eq 'WRITER'
    ? $self->_writer(\%args)
    : $self->_reader(\%args);
}

###
### WRITER internals
###

sub _writer($)
{   my ($self, $args) = @_;

    die "ERROR: option 'role' only for readers"  if $args->{role};
    die "ERROR: option 'roles' only for readers" if $args->{roles};

    my $schema = $self->schemas;
    my $envns  = $self->envelopeNS;

    my %allns;
    my @allns  = @{ $args->{prefix_table} || [] };
    while(@allns)
    {   my ($prefix, $uri) = splice @allns, 0, 2;
        $allns{$uri} = {uri => $uri, prefix => $prefix};
    }

    my $understand = $args->{mustUnderstand};
    my %understand = map { ($_ => 1) }
        ref $understand eq 'ARRAY' ? @$understand
      : defined $understand ? "$understand" : ();

    my $destination = $args->{destination};
    my %destination = ref $destination eq 'ARRAY' ? @$destination : ();

    #
    # produce header parsing
    #

    my (@header, @hlabels);
    my @h = @{$args->{header} || []};
    while(@h)
    {   my ($label, $element) = splice @h, 0, 2;

        my $code = $schema->compile
           ( WRITER => $element
           , output_namespaces  => \%allns
           , include_namespaces => 0
           , elements_qualified => 'TOP'
           );

        push @header, $label => $self->_writer_header_env($code, \%allns
           , delete $understand{$label}, delete $destination{$label});

        push @hlabels, $label;
    }

    keys %understand
        and error __x"mustUnderstand for unknown header {headers}"
                , headers => [keys %understand];

    keys %destination
        and error __x"actor for unknown header {headers}"
                , headers => [keys %destination];

    my $headerhook = $self->_writer_hook($envns, 'Header', @header);

    #
    # Produce body parsing
    #

    my (@body, @blabels);
    my @b = @{$args->{body} || []};
    while(@b)
    {   my ($label, $element) = splice @b, 0, 2;

        my $code = $schema->compile
           ( WRITER => $element
           , output_namespaces  => \%allns
           , include_namespaces => 0
           , elements_qualified => 'TOP'
           );

        push @body, $label => $code;
        push @blabels, $label;
    }

    my $bodyhook   = $self->_writer_hook($envns, 'Body', @body);

    #
    # Handle encodingStyle
    #

    my $encstyle = $self->_writer_encstyle_hook(\%allns);

    my $envelope = $self->schemas->compile
     ( WRITER => pack_type($envns, 'Envelope')
     , hooks  => [ $encstyle, $headerhook, $bodyhook ]
     , output_namespaces    => \%allns
     , elements_qualified   => 1
     , attributes_qualified => 1
     );

    sub { my ($values, $charset) = @_;
          my $doc = XML::LibXML::Document->new('1.0', $charset);
          my %data = %$values;  # do not destroy the calling hash

          $data{Header}{$_} = delete $data{$_} for @hlabels;
          $data{Body}{$_}   = delete $data{$_} for @blabels;
          $envelope->($doc, \%data);
        };
}

sub _writer_hook($$@)
{   my ($self, $ns, $local, @do) = @_;
 
   +{ type    => pack_type($ns, $local)
    , replace =>
         sub { my ($doc, $data, $path, $tag) = @_;
               my %data = %$data;
               my @h = @do;
               my @childs;
               while(@h)
               {   my ($k, $c) = (shift @h, shift @h);
                   if(my $v = delete $data{$k})
                   {    my $g = $c->($doc, $v);
                        push @childs, $g if $g;
                   }
               }
               warn "ERROR: unused values @{[ keys %data ]}\n"
                   if keys %data;

               @childs or return ();
               my $node = $doc->createElement($tag);
               $node->appendChild($_) for @childs;
               $node;
             }
    };
}

sub _writer_encstyle_hook($)
{   my ($self, $allns) = @_;
    my $envns   = $self->envelopeNS;
    my $style_w = $self->schemas->compile
     ( WRITER => pack_type($envns, 'encodingStyle')
     , output_namespaces    => $allns
     , include_namespaces   => 0
     , attributes_qualified => 1
     );
    my $style;

    my $before  = sub {
	my ($doc, $values, $path) = @_;
        ref $values eq 'HASH' or return $values;
        $style = $style_w->($doc, delete $values->{encodingStyle});
        $values;
      };

    my $after = sub {
        my ($doc, $node, $path) = @_;
        $node->addChild($style) if defined $style;
        $node;
      };

   { before => $before, after => $after };
}

###
### READER internals
###

sub _reader($)
{   my ($self, $args) = @_;

    die "ERROR: option 'destination' only for writers"
        if $args->{destination};

    die "ERROR: option 'mustUnderstand' only for writers"
        if $args->{understand};

    my $schema = $self->schemas;
    my $envns  = $self->envelopeNS;

    my $roles  = $args->{roles} || $args->{role} || 'ULTIMATE';
    my @roles  = ref $roles eq 'ARRAY' ? @$roles : $roles;

    #
    # produce header parsing
    #

    my @header;
    my @h = @{$args->{header} || []};
    while(@h)
    {   my ($label, $element) = splice @h, 0, 2;
        push @header, [$label, $element, $schema->compile(READER => $element)];
    }

    my $headerhook = $self->_reader_hook($envns, 'Header', @header);

    #
    # Produce body parsing
    #

    my @body;
    my @b = @{$args->{body} || []};
    while(@b)
    {   my ($label, $element) = splice @b, 0, 2;
        push @body, [$label, $element, $schema->compile(READER => $element)];
    }

    my $bodyhook   = $self->_reader_hook($envns, 'Body', @body);

    #
    # Handle encodingStyle
    #

    my $encstyle = $self->_reader_encstyle_hook;

    my $envelope = $self->schemas->compile
     ( READER => pack_type($envns, 'Envelope')
     , hooks  => [ $encstyle, $headerhook, $bodyhook ]
     );

    sub { my $xml   = shift;
          my $data  = $envelope->($xml);
          my @pairs = ( %{delete $data->{Header} || {}}
                      , %{delete $data->{Body}   || {}});
          while(@pairs)
          {  my $k       = shift @pairs;
             $data->{$k} = shift @pairs;
          }
          $data;
        }
}

sub _reader_hook($$@)
{   my ($self, $ns, $local, @do) = @_;
    my %trans = map { ($_->[1] => [ $_->[0], $_->[2] ]) } @do; # we need copies
 
   +{ type    => pack_type($ns, $local)
    , replace =>
        sub
          { my ($xml, $trans, $path, $label) = @_;
            my %h;
            foreach my $child ($xml->childNodes)
            {   next unless $child->isa('XML::LibXML::Element');
                my $type = pack_type $child->namespaceURI, $child->localName;
                if(my $t = $trans{$type})
                {   my $v = $t->[1]->($child);
                    $h{$t->[0]} = $v if defined $v;
                }
                else
                {   $h{$type} = $child;
                }
            }
            ($label => \%h);
          }
    };
}

sub _reader_encstyle_hook()
{   my $self     = shift;
    my $envns    = $self->envelopeNS;
    my $style_r = $self->schemas->compile
      (READER => pack_type($envns, 'encodingStyle'));  # is attribute

    my $encstyle;  # yes, closures!

    my $before = sub
      { my ($xml, $path) = @_;
        if(my $attr = $xml->getAttributeNode('encodingStyle'))
        {   $encstyle = $style_r->($attr, $path);
            $xml->removeAttribute('encodingStyle');
        }
        $xml;
      };

   my $after   = sub
      { defined $encstyle or return $_[1];
        my $h = $_[1];
        ref $h eq 'HASH' or $h = { _ => $h };
        $h->{encodingStyle} = $encstyle;
        $h;
      };

   { before => $before, after => $after };
}


sub direction($$)
{   my ($self, $role, $inout) = @_;

    my $direction
      = $role  eq 'CLIENT' ?  1
      : $role  eq 'SERVER' ? -1
      : die "ERROR: role must be CLIENT or SERVER, not $role\n";

    $direction
     *= $inout eq 'INPUT'  ?  1
      : $inout eq 'OUTPUT' ? -1
      : die "ERROR: message is INPUT or OUTPUT, not $inout\n" ;

    $direction==1 ? 'WRITER' : 'READER';
}


sub roleAbbreviation($) { panic "not implemented" }


1;
