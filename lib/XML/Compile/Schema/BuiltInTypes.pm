# Copyrights 2006-2011 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.00.
use warnings;
use strict;

package XML::Compile::Schema::BuiltInTypes;
use vars '$VERSION';
$VERSION = '1.22';

use base 'Exporter';

our @EXPORT = qw/%builtin_types/;

our %builtin_types;

use Log::Report     'xml-compile', syntax => 'SHORT';
use POSIX           qw/strftime/;
use Math::BigInt;
use Math::BigFloat;
use MIME::Base64;

use XML::Compile::Util qw/pack_type unpack_type/;


# The XML reader calls
#     check(parse(value))  or check_read(parse(value))

# The XML writer calls
#     check(format(value)) or check_write(format(value))

# Parse has a second argument, only for QNAME: the node
# Format has a second argument for QNAME as well.

sub identity  { $_[0] }

# already validated, unless that is disabled.
sub str2int   { $_[0] + 0 }

# sprintf returns '0' if non-int, with warning. We need a validation error
sub int2str   { $_[0] =~ m/^\s*[0-9]+\s*$/ ? sprintf("%ld", $_[0]) : $_[0] }

sub str       { "$_[0]" }
sub _replace  { $_[0] =~ s/[\t\r\n]/ /g; $_[0]}
sub _collapse { local $_ = $_[0]; s/[\t\r\n]+/ /g; s/^ +//; s/ +$//; $_}


# format not useful, because xsi:type not supported
$builtin_types{anySimpleType} =
 { example => 'anySimple'
 , parse   => sub {shift}
 , extends => 'anyType'
 };

$builtin_types{anyType} =
 { example => 'anything'
 , parse   => sub {shift}
 , extends => undef         # the root type
 };

$builtin_types{anyAtomicType} =
 { example => 'anyAtomic'
 , parse   => sub {shift}
 , extends => 'anySimpleType'
 };


$builtin_types{error}   = {example => '[some error structure]'};


$builtin_types{boolean} =
 { parse   => sub { $_[0] =~ m/^\s*false|0\s*/i ? 0 : 1 }
 , format  => sub { $_[0] eq 'false' || $_[0] eq 'true' ? $_[0]
                  : $_[0] ? 1 : 0 }
 , check   => sub { $_[0] =~ m/^\s*(?:false|true|0|1)\s*$/i }
 , example => 'true'
 , extends => 'anyAtomicType'
 };


$builtin_types{pattern} =
 { example => '*.exe'
 };


sub bigint
{   $_[0] =~ s/\s+//g;
    my $v = Math::BigInt->new($_[0]);
    error __x"Value `{val}' is not a (big) integer", val => $v if $v->is_nan;
    $v;
}

$builtin_types{integer} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*[-+]?\s*\d[\s\d]*$/ }
 , example => 42
 , extends => 'decimal'
 };


$builtin_types{negativeInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*\-\s*\d[\s\d]*$/ }
 , example => '-1'
 , extends => 'nonPositiveInteger'
 };


$builtin_types{nonNegativeInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*(?:\+\s*)?\d[\s\d]*$/ }
 , example => '17'
 , extends => 'integer'
 };


$builtin_types{positiveInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*(?:\+\s*)?\d[\s\d]*$/ && $_[0] =~ m/[1-9]/ }
 , example => '+3'
 , extends => 'nonNegativeInteger'
 };


$builtin_types{nonPositiveInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*(?:\-\s*)?\d[\s\d]*$/
                 || $_[0] =~ m/^\s*(?:\+\s*)0[0\s]*$/ }
 , example => '-42'
 , extends => 'integer'
 };


$builtin_types{long} =
 { parse   => \&bigint
 , check   =>
     sub { $_[0] =~ m/^\s*[-+]?\s*\d[\s\d]*$/ && ($_[0] =~ tr/0-9//) < 20 }
 , example => '-100'
 , extends => 'integer'
 };


$builtin_types{unsignedLong} =
 { parse   => \&bigint
 , check   => sub {$_[0] =~ m/^\s*\+?\s*\d[\s\d]*$/ && ($_[0] =~ tr/0-9//) < 21}
 , example => '100'
 , extends => 'nonNegativeInteger'
 };


$builtin_types{unsignedInt} =
 { parse   => \&bigint
 , check   => sub {$_[0] =~ m/^\s*\+?\s*\d[\s\d]*$/ && ($_[0] =~ tr/0-9//) <=10}
 , example => '42'
 , extends => 'unsignedLong'
 };

# Used when 'sloppy_integers' was set: the size of the values
# is illegally limited to the size of Perl's 32-bit signed integers.

$builtin_types{non_pos_int} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*[+-]?\s*\d[\d\s]*$/ && $_[0] <= 0}
 , example => '-12'
 };

$builtin_types{positive_int} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*(?:\+\s*)?\d[\d\s]*$/ }
 , example => '+42'
 };

$builtin_types{negative_int} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*\-\s*\d[\d\s]*$/ }
 , example => '-12'
 };

$builtin_types{unsigned_int} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*(?:\+\s*)?\d[\d\s]*$/ && $_[0] >= 0}
 , example => '42'
 };


$builtin_types{int} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*[+-]?\d+\s*$/}
 , example => '42'
 , extends => 'long'
 };


$builtin_types{short} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   =>
    sub { $_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= -32768 && $_[0] <= 32767 }
 , example => '-7'
 , extends => 'int'
 };


$builtin_types{unsignedShort} =
 { parse  => \&str2int
 , format => \&int2str
 , check  =>
    sub { $_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= 0 && $_[0] <= 65535 }
 , example => '7'
 , extends => 'unsignedInt'
 };


$builtin_types{byte} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= -128 && $_[0] <=127}
 , example => '-2'
 , extends => 'short'
 };


$builtin_types{unsignedByte} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= 0 && $_[0] <= 255}
 , example => '2'
 , extends => 'unsignedShort'
 };


$builtin_types{decimal} =
 { parse   => sub {$_[0] =~ s/\s+//g; Math::BigFloat->new($_[0]) }
 , check   => sub {$_[0] =~ m/^(\+|\-)?([0-9]+(\.[0-9]*)?|\.[0-9]+)$/}
 , example => '3.1415'
 , extends => 'anyAtomicType'
 };


sub str2num
{   my $s = shift;
    $s =~ s/\s//g;

      $s =~ m/[^0-9]/ ? Math::BigFloat->new($s eq 'NaN' ? $s : lc $s) # INF->inf
    : length $s < 9   ? $s+0
    :                   Math::BigInt->new($s);
}

sub num2str
{   my $f = shift;
      !ref $f         ? $f
    : !(UNIVERSAL::isa($f,'Math::BigInt') || UNIVERSAL::isa($f,'Math::BigFloat'))
    ? eval {use warnings FATAL => 'all'; $f + 0.0}
    : $f->is_nan      ? 'NaN'
    :                   uc $f->bstr;  # [+-]inf -> [+-]INF,  e->E doesn't matter
}

sub numcheck($)
{   $_[0] =~
      m# [+-]? (?: [0-9]+(?:\.[0-9]*)?|\.[0-9]+) (?:[Ee][+-]?[0-9]+)?
       | [+-]? INF
       | NaN #x
}

$builtin_types{precissionDecimal} =
$builtin_types{float}  =
$builtin_types{double} =
 { parse   => \&str2num
 , format  => \&num2str
 , check   => \&numcheck
 , example => '3.1415'
 , extends => 'anyAtomicType'
 };

$builtin_types{sloppy_float} =
 { check => sub {
      my $v = eval {use warnings FATAL => 'all'; $_[0] + 0.0};
      $@ ? undef : 1;
    }
 , example => '3.1415'
 , extends => 'anyAtomicType'
 };


$builtin_types{base64Binary} =
 { parse   => sub { eval { decode_base64 $_[0] } }
 , format  => sub { eval { encode_base64 $_[0] } }
 , check   => sub { !$@ }
 , example => 'VGVzdA=='
 , extends => 'anyAtomicType'
 };


# (Use of) an XS implementation would be nice
$builtin_types{hexBinary} =
 { parse   => sub { $_[0] =~ s/\s+//g; pack 'H*', $_[0]}
 , format  => sub { unpack 'H*', $_[0]}
 , check   =>
     sub { $_[0] !~ m/[^0-9a-fA-F\s]/ && (($_[0] =~ tr/0-9a-fA-F//) %2)==0}
 , example => 'F00F'
 , extends => 'anyAtomicType'
 };


my $yearFrag     = qr/ \-? (?: [1-9]\d{3,} | 0\d\d\d ) /x;
my $monthFrag    = qr/ 0[1-9] | 1[0-2] /x;
my $dayFrag      = qr/ 0[1-9] | [12]\d | 3[01] /x;
my $hourFrag     = qr/ [01]\d | 2[0-3] /x;
my $minuteFrag   = qr/ [0-5]\d /x;
my $secondFrag   = qr/ [0-5]\d (?: \.\d+)? /x;
my $endOfDayFrag = qr/24\:00\:00 (?: \.\d+)? /x;
my $timezoneFrag = qr/Z | [+-] (?: 0\d | 1[0-4] ) \: $minuteFrag/x;
my $timeFrag     = qr/ (?: $hourFrag \: $minuteFrag \: $secondFrag )
                     | $endOfDayFrag
                     /x;

my $date = qr/^ $yearFrag \- $monthFrag \- $dayFrag $timezoneFrag? $/x;

$builtin_types{date} =
 { parse   => \&_collapse
 , format  => sub { $_[0] =~ /\D/ ? $_[0] : strftime("%Y-%m-%d", gmtime $_[0])}
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $date }
 , example => '2006-10-06'
 , extends => 'anyAtomicType'
 };


my $time = qr /^ $timeFrag $timezoneFrag? $/x;

$builtin_types{time} =
 { parse   => \&_collapse
 , format  => sub { return $_[0] if $_[0] =~ /[^0-9.]/;
      my $subsec = $_[0] =~ /(\.\d+)/ ? $1 : '';
      strftime "%T$subsec", gmtime $_[0] }
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $time }
 , example => '11:12:13'
 , extends => 'anyAtomicType'
 };


my $dateTime
  = qr/^ $yearFrag \- $monthFrag \- $dayFrag T $timeFrag $timezoneFrag? $/x;
my $dateTimeStamp
  = qr/^ $yearFrag \- $monthFrag \- $dayFrag T $timeFrag $timezoneFrag $/x;

sub _dt_format
{   return $_[0] if $_[0] =~ /[^0-9.]/;  # already formated
    my $subsec = $_[0] =~ /(\.\d+)/ ? $1 : '';
    strftime "%Y-%m-%dT%H:%M:%S${subsec}Z", gmtime $_[0];
}

$builtin_types{dateTime} =
 { parse   => \&_collapse
 , format  => \&_dt_format
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $dateTime }
 , example => '2006-10-06T00:23:02Z'
 , extends => 'anyAtomicType'
 };


$builtin_types{dateTimeStamp} =
 { parse   => \&_collapse
 , format  => \&_dt_format
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $dateTimeStamp }
 , example => '2006-10-06T00:23:02Z'
 , extends => 'dateTime'
 };


my $gDay = qr/^ \- \- \- $dayFrag $timezoneFrag? $/x;
$builtin_types{gDay} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gDay }
 , example => '---12+09:00'
 , extends => 'anyAtomicType'
 };


my $gMonth = qr/^ \- \- $monthFrag $timezoneFrag? $/x;
$builtin_types{gMonth} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gMonth }
 , example => '--09+07:00'
 , extends => 'anyAtomicType'
 };


my $gMonthDay = qr/^ \- \- $monthFrag \- $dayFrag $timezoneFrag? /x;
$builtin_types{gMonthDay} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gMonthDay }
 , example => '--09-12+07:00'
 , extends => 'anyAtomicType'
 };


my $gYear = qr/^ $yearFrag $timezoneFrag? $/x;
$builtin_types{gYear} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gYear }
 , example => '2006+07:00'
 , extends => 'anyAtomicType'
 };


my $gYearMonth = qr/^ $yearFrag \- $monthFrag $timezoneFrag? $/x;
$builtin_types{gYearMonth} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gYearMonth }
 , example => '2006-11+07:00'
 , extends => 'anyAtomicType'
 };


$builtin_types{duration} =
 { parse   => \&_collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g;
      $val =~ m/^\-?P(?:\d+Y)?(?:\d+M)?(?:\d+D)?
          (?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$/x }

 , example => 'P9M2DT3H5M'
 };


$builtin_types{dayTimeDuration} =
 { parse  => \&_collapse
 , check  => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$/ }
 , example => 'P2DT3H5M10S'
 , extends => 'duration'
 };


$builtin_types{yearMonthDuration} =
 { parse  => \&_collapse
 , check  => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+Y)?(?:\d+M)?$/ }
 , example => 'P40Y5M'
 , extends => 'duration'
 };


$builtin_types{string} =
 { example => 'example'
 , extends => 'anyAtomicType'
 };


$builtin_types{normalizedString} =
 { parse   => \&_replace
 , example => 'example'
 , extends => 'string'
 };


$builtin_types{language} =
 { parse   => \&_collapse
 , check   => sub { my $v = $_[0]; $v =~ s/\s+//g; $v =~
       m/^[a-zA-Z]{1,8}(?:\-[a-zA-Z0-9]{1,8})*$/ }
 , example => 'nl-NL'
 , extends => 'token'
 };


sub _valid_ncname($)
{  (my $name = $_[0]) =~ s/\s//;
   $name =~ m/^[a-zA-Z_](?:[\w.-]*)$/;
}

# better checks needed
#  NCName matches pattern [\i-[:]][\c-[:]]*
sub _ncname($) {sub { $_[0] !~ m/\:/ }}

my $ids = 0;
$builtin_types{ID} =
 { parse   => \&_collapse
 , check   => \&_ncname
 , example => 'id_'.$ids++
 , extends => 'NCName'
 };

$builtin_types{IDREF} =
 { parse   => \&_collapse
 , check   => \&_ncname
 , example => 'id-ref'
 , extends => 'NCName'
 };


$builtin_types{NCName} =
 { parse   => \&_collapse
 , check   => \&_ncname
 , example => 'label'
 , extends => 'Name'
 };

$builtin_types{ENTITY} =
 { parse   => \&_collapse
 , check   => \&_ncname
 , example => 'entity'
 , extends => 'NCName'
 };

$builtin_types{IDREFS} =
$builtin_types{ENTITIES} =
 { parse   => sub { [ split ' ', shift ] }
 , format  => sub { my $v = shift; ref $v eq 'ARRAY' ? join(' ',@$v) : $v }
 , check   => sub { $_[0] !~ m/\:/ }
 , example => 'labels'
 , is_list => 1
 , extends => 'anySimpleType'
 };


$builtin_types{Name} =
 { parse   => \&_collapse
 , example => 'name'
 , extends => 'token'
 };


$builtin_types{token} =
 { parse   => \&_collapse
 , example => 'token'
 , extends => 'normalizedString'
 };

# check required!  \c
$builtin_types{NMTOKEN} =
 { parse   => sub { $_[0] =~ s/\s+//g; $_[0] }
 , example => 'nmtoken'
 , extends => 'token'
 };

$builtin_types{NMTOKENS} =
 { parse   => sub { [ split ' ', shift ] }
 , format  => sub { my $v = shift; ref $v eq 'ARRAY' ? join(' ',@$v) : $v }
 , example => 'nmtokens'
 , is_list => 1
 , extends => 'anySimpleType'
 };


# relative uri's are also correct, so even empty strings...  it
# cannot be checked without context.
#    use Regexp::Common   qw/URI/;
#    check   => sub { $_[0] =~ $RE{URI} }

$builtin_types{anyURI} =
  { parse   => \&_collapse
  , example => 'http://example.com'
  , extends => 'anyAtomicType'
  };


$builtin_types{QName} =
 { parse   =>
     sub { my ($qname, $node) = @_;
           $qname =~ s/\s//g;
           my $prefix = $qname =~ s/^([^:]*)\:// ? $1 : '';

           $node  = $node->node if $node->isa('XML::Compile::Iterator');
           my $ns = $node->lookupNamespaceURI($prefix) || '';
           pack_type $ns, $qname;
         }
 , format  =>
    sub { my ($type, $trans) = @_;
          my ($ns, $local) = unpack_type $type;
          length $ns or return $local;

          my $def = $trans->{$ns};
          # let's hope that the namespace will get used somewhere else as
          # well, to make it into the xmlns.
          defined $def && exists $def->{used}
              or error __x"QName formatting only works if the namespace is used for an element, not found {ns} for {local}", ns => $ns, local => $local;

          length $def->{prefix} ? "$def->{prefix}:$local" : $local;
        }
 , example => 'myns:local'
 , extends => 'anyAtomicType'
 };


$builtin_types{NOTATION} =
 {
   extends => 'anyAtomicType'
 };


$builtin_types{binary} = { example => 'binary string' };


$builtin_types{timeDuration} = $builtin_types{duration};


$builtin_types{uriReference} = $builtin_types{anyURI};

# These constants where removed from the spec in 2001. Probably
# no-one is using these (anymore)
# century       = period   => 'P100Y'
# recurringDate = duration => 'P24H', period => 'P1Y'
# recurringDay  = duration => 'P24H', period => 'P1M'
# timeInstant   = duration => 'P0Y',  period => 'P0Y'
# timePeriod    = duration => 'P0Y'
# year          = period => 'P1Y'
# recurringDuration = ??

# only in 2000/10 schemas
$builtin_types{CDATA} =
 { parse   => \&_replace
 , example => 'CDATA'
 };

1;
