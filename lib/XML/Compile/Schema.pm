
use warnings;
use strict;

package XML::Compile::Schema;
use vars '$VERSION';
$VERSION = '0.01';
use base 'XML::Compile';

use Carp;
use List::Util   qw/first/;
use XML::LibXML;

use XML::Compile::Schema::Specs;
use XML::Compile::Schema::BuiltInStructs qw/builtin_structs/;
use XML::Compile::Schema::Translate      qw/compile_tree/;


sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);
    $self;
}


sub types(@)
{   my ($self, %args) = @_;
    my $indexformat = $args{namespace} || 'EXPANDED';

    my $types = $self->{XCS_types}
            ||= $self->_discover_types(\%args);

    if($indexformat eq 'EXPANDED')
    {  return wantarray ? keys %$types : $types;
    }
    elsif($indexformat eq 'LOCAL')
    {  return map {$_->{name}} values %$types if wantarray;
       my %local = map { ($_->{name} => $_) } values %$types;
       return \%local;
    }
    elsif($indexformat eq 'PREFIXED')
    {   my %pref
         = map { ( ($_->{prefix} ? "$_->{prefix}:$_->{name}" : $_->{name})
                    => $_) } values %$types;
       return wantarray ? keys %pref : \%pref;
    }

    croak "namespace: EXPANDED, PREFIXED, or LOCAL";
}

sub _find_attr($$)
{   my ($node, $tag) = @_;
    first {$_->localname eq $tag} $node->attributes;
}

sub _discover_types($$)
{   my ($self, $args) = @_;

    my $top = $self->top;
    $top = $top->documentElement
       if $top->isa('XML::LibXML::Document');

    my (%types, $tns);

    $self->walkTree
    ( $top,
      sub { my $schema = shift;
            return 1 unless $schema->isa('XML::LibXML::Element')
                         && $schema->localname eq 'schema';

            my $ns   = $schema->namespaceURI;
            return 1
                unless XML::Compile::Schema::Specs->predefinedSchema($ns);

            my $tns_attr = _find_attr($schema, 'targetNamespace');
            defined $tns_attr
                or croak "missing targetNamespace in schema";

            $tns = $tns_attr->value;

            foreach my $node ($schema->childNodes)
            {   next unless $node->isa('XML::LibXML::Element');
                next unless $node->namespaceURI eq $ns;
                next if $node->localname eq 'notation';

                my $name_attr = _find_attr($node, 'name');
                next unless defined $name_attr;

                my $name_val  = $name_attr->value;
                my ($prefix, $local)
                 = index($name_val, ':') >= 0
                 ? split(/\:/,$name_val,2)
                 : (undef, $name_val);

                my $uri
                 = defined $prefix ? $node->lookupNamespaceURI($prefix) : $tns;
                my $label = "$uri#$local";

                $types{$label}
                 = { full => $label, type => $node->localname
                   , ns => $uri, name => $local, prefix => $prefix
                   , node => $node
                   };
              }

              return 0;   # do not decend in schema
          }
    );

    \%types;
}


sub typesPerNamespace()
{   my $types = shift->types(namespace => 'EXPANDED');
    my %ns;
    foreach (values %$types)
    {   $ns{$_->{ns}}{$_->{name}} = $_;
    }

    \%ns;
}


sub printTypes()
{   my $types = shift->typesPerNamespace or return;
    foreach my $ns (sort keys %$types)
    {   print "Namespace: $ns\n";
        foreach my $name (sort keys %{$types->{$ns}})
        {   my $type = $types->{$ns}{$name};
            printf "  %14s %s\n", $type->{type}, $name;
        }
    }
}


sub compile($$@)
{   my ($self, $direction, $type, %args) = @_;

    exists $args{check_values}
       or $args{check_values} = 1;

    exists $args{check_occurs}
       or $args{check_occurs} = 0;

    $args{sloppy_integers}   ||= 0;
    unless($args{sloppy_integers})
    {   eval "require Math::BigInt";
        die "ERROR: require Math::BigInt or sloppy_integers:\n$@"
            if $@;

        eval "require Math::BigFloat";
        die "ERROR: require Math::BigFloat or sloppy_integers:\n$@"
            if $@;
    }

    exists $args{include_namespaces}
       or $args{include_namespaces} = !$args{ignore_namespaces};

    $args{output_namespaces} ||= {};

    do { $_->{used} = 0 for values %{$args{output_namespaces}} }
       if $args{namespace_reset};

    my $top   = $self->type($type)
       or croak "ERROR: type $type is not defined";

    $args{path} ||= $top->{full};

    compile_tree
     ( $top->{full}, %args
     , run   => builtin_structs($direction) 
     , types => scalar($self->types)
     , err   => $self->invalidsErrorHandler($args{invalid})
     );
}


sub template($@)
{   my ($self, $direction) = (shift, shift);

    my %args =
     ( check_values       => 0
     , check_occurs       => 0
     , invalid            => 'IGNORE'
     , ignore_facets      => 1
     , include_namespaces => 1
     , sloppy_integers    => 1
     , auto_value         => sub { warn @_; $_[0] }
     , @_
     );

   die "ERROR not implemented";
}


sub type($)
{   my ($self, $label) = @_;

       $self->types(namespace => 'EXPANDED')->{$label}
    || $self->types(namespace => 'LOCAL'   )->{$label};
}


sub invalidsErrorHandler($)
{   my $key = $_[1] || 'DIE';

      ref $key eq 'CODE'? $key
    : $key eq 'IGNORE'  ? sub { undef }
    : $key eq 'USE'     ? sub { $_[1] }
    : $key eq 'WARN'
    ? sub {warn "$_[2] ("
              . (defined $_[1]? $_[1] : 'undef')
              . ") for $_[0]\n"; $_[1]}
    : $key eq 'DIE'
    ? sub {die  "$_[2] (".(defined $_[1] ? $_[1] : 'undef').") for $_[0]\n"}
    : die "ERROR: error handler expects CODE, 'IGNORE',"
        . "'USE','WARN', or 'DIE', not $key";
}

1;
