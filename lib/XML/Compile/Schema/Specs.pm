
use warnings;
use strict;

package XML::Compile::Schema::Specs;
use vars '$VERSION';
$VERSION = '0.08';

use XML::Compile::Schema::BuiltInTypes   qw/%builtin_types/;
use Carp;


### Who will extend this?
# everything which is not caught by a special will need to pass through
# the official meta-scheme: the scheme of the scheme.  These lists are
# used to restrict the namespace to the specified, hiding all helper
# types.
my %builtin_public_1999 =
 ();

my %builtin_public_2000 = %builtin_public_1999;

my @builtin_public_2001 = qw/
 anySimpleType
 anyType
 anyURI
 boolean
 base64binary
 byte
 date
 dateTime
 dayTimeDuration
 decimal
 double
 duration
 ENTITY
 ENTITIES
 float
 gDay
 gMonth
 gMonthDay
 gYear
 gYearMonth
 hexBinary
 ID
 IDREF
 IDREFS
 int
 integer
 language
 long
 Name
 NCName
 NMTOKEN
 NMTOKENS
 negativeInteger
 nonNegativeInteger
 nonPositiveInteger
 normalizedString
 positiveInteger
 precissionDecimal
 NOTATION
 QName
 short
 string
 time
 token
 unsignedByte
 unsignedInt
 unsignedLong
 unsignedShort
 yearMonthDuration
 /;

my %builtin_public_2001 = map { ($_ => $_) } @builtin_public_2001;

my %sloppy_int_version =
 ( decimal            => 'double'
 , integer            => 'int'
 , long               => 'int'
 , nonNegativeInteger => 'unsigned_int'
 , nonPositiveInteger => 'non_pos_int'
 , positiveInteger    => 'positive_int'
 , negativeInteger    => 'negative_int'
 , unsignedLong       => 'unsigned_int'
 , unsignedInt        => 'unsigned_int'
 );

my %schema_1999 =
 ( uri_xsd => 'http://www.w3.org/1999/XMLSchema'
 , uri_xsi => 'http://www.w3.org/1999/XMLSchema-instance'

 , builtin_public => \%builtin_public_1999
 );

my %schema_2000 =
 ( uri_xsd => 'http://www.w3.org/2000/10/XMLSchema'
 , uri_xsi => 'http://www.w3.org/2000/10/XMLSchema-instance'

 , builtin_public => \%builtin_public_2000
 );

my %schema_2001 =
 ( uri_xsd  => 'http://www.w3.org/2001/XMLSchema'
 , uri_xsi  => 'http://www.w3.org/2001/XMLSchema-instance'

 , builtin_public => \%builtin_public_2001
 );

my %schemas = map { ($_->{uri_xsd} => $_) }
 \%schema_1999, \%schema_2000, \%schema_2001;


sub predefinedSchemas() { keys %schemas }


sub predefinedSchema($) { defined $_[1] ? $schemas{$_[1]} : () }


sub builtInType($;$@)
{   my ($class, $ns) = (shift, shift);
    my $name = @_ % 1 ? shift : undef;
    unless(defined $name)
    {   if($ns =~ m/^\s*\{(.*)\}(.*)/ ) { ($ns, $name) = ($1, $2) }
        else { croak "ERROR: incomplete type $ns" }
    }

    my $schema = $schemas{$ns}
        or return ();

    my %args = @_;

    $name    = $sloppy_int_version{$name}
        if $args{sloppy_integers} && exists $sloppy_int_version{$name};

    # only official names are exported this way
    my $public = $schema->{builtin_public}{$name};
    defined $public ? $builtin_types{$public} : ();
}

1;
