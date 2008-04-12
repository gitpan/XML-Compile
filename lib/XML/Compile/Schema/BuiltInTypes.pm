# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.04.
use warnings;
use strict;

package XML::Compile::Schema::BuiltInTypes;
use vars '$VERSION';
$VERSION = '0.77';
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
sub str2int   { use warnings FATAL => 'all'; $_[0] + 0 }
sub int2str   { use warnings FATAL => 'all'; sprintf "%ld", $_[0] }
sub str       { "$_[0]" }
sub _collapse { $_[0] =~ s/\s+//g; $_[0]}
sub _preserve { for($_[0]) {s/\s+/ /g; s/^ //; s/ $//}; $_[0]}
sub _replace  { $_[0] =~ s/[\t\r\n]/ /gs; $_[0]}

# a real check() produces a nice error message with name of the
# variable, however checking floats is extremely expensive.  Therefore,
# we use the result of the conversion which does not show the variable
# name.

sub str2num
{   my $v = eval {use warnings FATAL => 'all'; $_[0] + 0.0};
    error __x"Value `{val}' is not a float", val => $_[0] if $@;
    $v;
}

sub num2str
{   my $f = shift;
    if(ref $f && ($f->isa('Math::BigInt') || $f->isa('Math::BigFloat')))
    {   error __"float is NaN" if $f->is_nan;
        return $f->bstr;
    }
    my $v = eval {use warnings FATAL => 'all'; $f + 0.0};
    $@ && error __x"Value `{val}' is not a float", val => $f;
    $f;
}

sub bigint
{   $_[0] =~ s/\s+//g;
    my $v = Math::BigInt->new($_[0]);
    error __x"Value `{val}' is not a (big) integer", val => $v if $v->is_nan;
    $v;
}

sub bigfloat
{   $_[0] =~ s/\s+//g;
    my $v = Math::BigFloat->new($_[0]);
    error __x"Value `{val}' is not a (big) float", val => $v if $v->is_nan;
    $v;
}


$builtin_types{anySimpleType} =
$builtin_types{anyType}       =
 { example => 'anything'
 };


$builtin_types{boolean} =
 { parse   => sub { $_[0] =~ m/^\s*false|0\s*/i ? 0 : 1 }
 , format  => sub { $_[0] eq 'false' || $_[0] eq 'true' ? $_[0]
                  : $_[0] ? 1 : 0 }
 , check   => sub { $_[0] =~ m/^\s*(?:false|true|0|1)\s*$/i }
 , example => 'true'
 };


$builtin_types{integer} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*[-+]?\s*\d[\s\d]*$/ }
 , example => 42
 };


$builtin_types{negativeInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*\-\s*\d[\s\d]*$/ }
 , example => '-1'
 };


$builtin_types{nonNegativeInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*(?:\+\s*)?\d[\s\d]*$/ }
 , example => 0
 };


$builtin_types{positiveInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*(?:\+\s*)?\d[\s\d]*$/ && m/[1-9]/ }
 , example => '+3'
 };


$builtin_types{nonPositiveInteger} =
 { parse   => \&bigint
 , check   => sub { $_[0] =~ m/^\s*(?:\-\s*)?\d[\s\d]*$/
                 || $_[0] =~ m/^\s*(?:\+\s*)0[0\s]*$/ }
 , example => '-0'
 };


$builtin_types{long} =
 { parse   => \&bigint
 , check   =>
     sub { $_[0] =~ m/^\s*[-+]?\s*\d[\s\d]*$/ && ($_[0] =~ tr/0-9//) < 20 }
 , example => '-100'
 };


$builtin_types{unsignedLong} =
 { parse   => \&bigint
 , check   => sub {$_[0] =~ m/^\s*\+?\s*\d[\s\d]*$/ && ($_[0] =~ tr/0-9//) < 21}
 , example => '100'
 };


$builtin_types{unsignedInt} =
 { parse   => \&bigint
 , check   => sub {$_[0] =~ m/^\s*\+?\s*\d[\s\d]*$/ && ($_[0] =~ tr/0-9//) <10}
 , example => '42'
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
 };


$builtin_types{short} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   =>
    sub { $_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= -32768 && $_[0] <= 32767 }
 , example => '-7'
 };


$builtin_types{unsignedShort} =
 { parse  => \&str2int
 , format => \&int2str
 , check  =>
    sub { $_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= 0 && $_[0] <= 65535 }
 , example => '7'
 };


$builtin_types{byte} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= -128 && $_[0] <=127}
 , example => '-2'
 };


$builtin_types{unsignedByte} =
 { parse   => \&str2int
 , format  => \&int2str
 , check   => sub {$_[0] =~ m/^\s*[+-]?\d+\s*$/ && $_[0] >= 0 && $_[0] <=255}
 , example => '2'
 };


$builtin_types{precissionDecimal} = $builtin_types{int};


$builtin_types{decimal} =
 { parse   => \&bigfloat
 # checked when reading
 , example => '3.1415'
 };


$builtin_types{float} =
$builtin_types{double} =
 { parse   => \&str2num
 , format  => \&num2str
 # check by str2num
 , example => '3.1415'
 };


$builtin_types{base64Binary} =
 { parse   => sub { eval { decode_base64 $_[0] } }
 , format  => sub { eval { encode_base64 $_[0] } }
 , check   => sub { !$@ }
 , example => 'VGVzdA=='
 };


# (Use of) an XS implementation would be nice
$builtin_types{hexBinary} =
 { parse   =>
     sub { $_[0] =~ s/\s+//g; $_[0] =~ s/([0-9a-fA-F]{2})/chr hex $1/ge; $_[0]}
 , format  =>
     sub { join '',map {sprintf "%02X", ord $_} unpack "C*", $_[0]}
 , check   =>
     sub { $_[0] !~ m/[^0-9a-fA-F\s]/ && (($_[0] =~ tr/0-9a-fA-F//) %2)==0}
 , example => 'F00F'
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
 };


my $time = qr /^ $timeFrag $timezoneFrag? $/x;

$builtin_types{time} =
 { parse   => \&_collapse
 , format  => sub { $_[0] =~ /\D/ ? $_[0] : strftime("%T", gmtime $_[0])}
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $time }
 , example => '11:12:13'
 };


my $dateTime = qr/^ $yearFrag \- $monthFrag \- $dayFrag
                    T $timeFrag $timezoneFrag? $/x;

$builtin_types{dateTime} =
 { parse   => \&_collapse
 , format  => sub { $_[0] =~ /\D/ ? $_[0]
     : strftime("%Y-%m-%dT%H:%S:%MZ", gmtime($_[0])) }
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $dateTime }
 , example => '2006-10-06T00:23:02'
 };


my $gDay = qr/^ \- \- \- $dayFrag $timezoneFrag? $/x;
$builtin_types{gDay} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gDay }
 , example => '---12+09:00'
 };


my $gMonth = qr/^ \- \- $monthFrag $timezoneFrag? $/x;
$builtin_types{gMonth} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gMonth }
 , example => '--09+07:00'
 };


my $gMonthDay = qr/^ \- \- $monthFrag \- $dayFrag $timezoneFrag? /x;
$builtin_types{gMonthDay} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gMonthDay }
 , example => '--09-12+07:00'
 };


my $gYear = qr/^ $yearFrag \- $monthFrag $timezoneFrag? $/x;
$builtin_types{gYear} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gYear }
 , example => '2006+07:00'
 };


my $gYearMonth = qr/^ $yearFrag \- $monthFrag $timezoneFrag? $/x;
$builtin_types{gYearMonth} =
 { parse   => \&_collapse
 , check   => sub { (my $val = $_[0]) =~ s/\s+//g; $val =~ $gYearMonth }
 , example => '2006-11+07:00'
 };


$builtin_types{duration} =
 { parse   => \&_collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+Y)?(?:\d+M)?(?:\d+D)?
        (?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?)S)?$/x }
 , example => 'P9M2DT3H5M'
 };


$builtin_types{dayTimeDuration} =
 { parse  => \&_collapse
 , check  => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?)S)?$/ }
 , example => 'P2DT3H5M10S'
 };


$builtin_types{yearMonthDuration} =
 { parse  => \&_collapse
 , check  => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+Y)?(?:\d+M)?$/ }
 , example => 'P40Y5M'
 };


$builtin_types{string} =
 { example => 'example'
 };


$builtin_types{normalizedString} =
 { parse   => \&_preserve
 , example => 'example'
 };


$builtin_types{language} =
 { parse   => \&_collapse
 , check   => sub { my $v = $_[0]; $v =~ s/\s+//g; $v =~
       m/^[a-zA-Z]{1,8}(?:\-[a-zA-Z0-9]{1,8})*$/ }
 , example => 'nl-NL'
 };


sub _valid_ncname($)
{  (my $name = $_[0]) =~ s/\s//;
   $name =~ m/^[a-zA-Z_](?:[\w.-]*)$/;
}

# better checks needed
$builtin_types{ID} =
$builtin_types{IDREF} =
$builtin_types{NCName} =
$builtin_types{ENTITY} =
 { parse   => \&_collapse
 , check   => sub { $_[0] !~ m/\:/ }
 , example => 'label'
 };

$builtin_types{IDREFS} =
$builtin_types{ENTITIES} =
 { parse   => sub { [ split ' ', shift ] }
 , format  => sub { my $v = shift; ref $v eq 'ARRAY' ? join(' ',@$v) : $v }
 , check   => sub { $_[0] !~ m/\:/ }
 , example => 'labels'
 };


$builtin_types{Name} =
 { parse   => \&_collapse
 , example => 'name'
 };


# check required!  \c
$builtin_types{token} =
$builtin_types{NMTOKEN} =
 { parse   => \&_collapse
 , example => 'token'
 };

$builtin_types{NMTOKENS} =
 { parse   => sub { [ split ' ', shift ] }
 , format  => sub { my $v = shift; ref $v eq 'ARRAY' ? join(' ',@$v) : $v }
 , example => 'tokens'
 };


# relative uri's are also correct, so even empty strings...  it
# cannot be checked without context.
#    use Regexp::Common   qw/URI/;
#    check   => sub { $_[0] =~ $RE{URI} }

$builtin_types{anyURI} =
 { parse   => \&_collapse
 , example => 'http://example.com'
 };


sub _valid_qname($)
{   my @ncnames = split /\:/, $_[0];
    return 0 if @ncnames > 2;
    _valid_ncname($_) || return 0 for @ncnames;
    1;
}

$builtin_types{QName} =
 { parse   =>
     sub { my ($qname, $node) = @_;
           my $prefix = $qname =~ s/^([^:]*)\:// ? $1 : '';

           length $prefix
               or error __x"QNAME requires prefix at `{qname}'", qname=>$qname;

           $node = $node->node if $node->isa('XML::Compile::Iterator');
           my $ns = $node->lookupNamespaceURI($prefix)
               or error __x"cannot find prefix `{prefix}' for QNAME `{qname}'"
                     , prefix => $prefix, qname => $qname;
           pack_type $ns, $qname;
         }
 , format  =>
    sub { my ($type, $trans) = @_;
          my ($ns, $local) = unpack_type $type;
          $ns or return $local;

          my $def = $trans->{$ns};
          if(!$def || !$def->{used})
          {   error __x"QNAME formatting only works if the namespace is used elsewhere, not {ns}", ns => $ns;
          }
          "$def->{prefix}:$local";
        }
 , check   => \&_valid_qname
 , example => 'myns:name'
 };


$builtin_types{NOTATION} = {};


$builtin_types{binary} = { example => 'binary string' };


$builtin_types{timeDuration} = $builtin_types{duration};


$builtin_types{uriReference} = $builtin_types{anyURI};


# only in 2000/10 schemas
$builtin_types{CDATA} =
 { parse   => \&_replace
 , example => 'CDATA'
 };

1;
