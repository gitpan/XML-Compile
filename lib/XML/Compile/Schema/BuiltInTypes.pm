# Copyrights 2006 by Mark Overmeer. For contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 0.12.
use warnings;
use strict;

package XML::Compile::Schema::BuiltInTypes;
use vars '$VERSION';
$VERSION = '0.12';
use base 'Exporter';

our @EXPORT = qw/%builtin_types/;

our %builtin_types;

use Regexp::Common   qw/URI/;
use MIME::Base64;
use POSIX            qw/strftime/;

# use XML::RegExp;  ### can we use this?


# The XML reader calls
#     check(parse(value))  or check_read(parse(value))
# The XML writer calls
#     check(format(value)) or check_write(format(value))

sub identity { $_[0] };
sub str2int  { use warnings FATAL => 'all'; eval {$_[0] + 0} };
sub int2str  { use warnings FATAL => 'all'; eval {sprintf "%ld", $_[0]} };
sub num2str  { use warnings FATAL => 'all'; eval {sprintf "%lf", $_[0]} };
sub str      { "$_[0]" };
sub collapse { $_[0] =~ s/\s+//g; $_[0]}
sub preserve { for($_[0]) {s/\s+/ /g; s/^ //; s/ $//}; $_[0]}
sub bigint   { $_[0] =~ s/\s+//g;
   my $v = Math::BigInt->new($_[0]); $v->is_nan ? undef : $v }
sub bigfloat { $_[0] =~ s/\s+//g;
   my $v = Math::BigFloat->new($_[0]); $v->is_nan ? undef : $v }


$builtin_types{anySimpleType} =
$builtin_types{anyType}       =
 { example => 'anything'
 };


$builtin_types{boolean} =
 { parse   => \&collapse
 , format  => sub { $_[0] eq 'false' || $_[0] eq 'true' ? $_[0] : !!$_[0] }
 , check   => sub { $_[0] =~ m/^(false|true|0|1)$/ }
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
 , check   => sub { my $x = eval {$_[0] + 0.0}; !$@ }
 , example => '3.1415'
 };


$builtin_types{float} =
$builtin_types{double} =
 { parse   => \&str2num
 , format  => \&num2str
 , check   => sub { my $val = eval {$_[0] + 0.0}; !$@ }
 , example => '3.1415'
 };


$builtin_types{base64binary} =
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


$builtin_types{date} =
 { parse   => \&collapse
 , format  => sub { $_[0] =~ /\D/ ? $_[0] : strftime("%Y-%m-%d", gmtime $_[0])}
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
  /^[12]\d{3}                # year
    \-(?:0?[1-9]|1[0-2])     # month
    \-(?:0?[1-9]|[12][0-9]|3[01]) # day
    (?:[+-]\d\d?\:\d\d)?     # time-zone
    $/x }
 , example => '2006-10-06'
 };


$builtin_types{dateTime} =
 { parse  => \&collapse
 , format => sub { $_[0] =~ /\D/ ? $_[0]
     : strftime("%Y-%m-%dT%H:%S%MZ", gmtime($_[0])) }
 , check  => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
  /^[12]\d{3}                # year
    \-(?:0?[1-9]|1[0-2])     # month
    \-(?:0?[1-9]|[12][0-9]|3[01]) # day
    T
    (?:(?:[01]?[0-9]|2[0-3]) # hours
       \:(?:[0-5]?[0-9])     # minutes
       \:(?:[0-5]?[0-9])     # seconds
    )?
    (?:[+-]\d\d?\:\d\d|Z)?   # time-zone
    $/x ? $_[0] : 0 }
 , example => '2006-10-06T00:23:02'
 };


$builtin_types{gDay} =
 { parse   => \&collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
      m/^\-\-\-\d+(?:[-+]\d+\:[0-5]\d)?$/ ? 1 : 0 }
 , example => '---12+9:00'
 };


$builtin_types{gMonth} =
 { parse   => \&collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
      m/^\-\-\d+(?:[-+]\d+\:[0-5]\d)?$/ ? 1 : 0 }
 , example => '--9+7:00'
 };


$builtin_types{gMonthDay} =
 { parse   => \&collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
      m/^\-\-\d+\-\d+(?:[-+]\d+\:[0-5]\d)?$/ ? 1 : 0 }
 , example => '--9-12+7:00'
 };


$builtin_types{gYear} =
 { parse   => \&collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
      m/^\d+(?:[-+]\d+\:[0-5]\d)?$/ ? 1 : 0 }
 , example => '2006+7:00'
 };


$builtin_types{gYearMonth} =
 { parse   => \&collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
      m/^\d+\-(?:0?[1-9]|1[0-2])(?:[-+]\d+\:[0-5]\d)?$/ ? 1 : 0 }
 , example => '2006-11+7:00'
 };


$builtin_types{duration} =
 { parse   => \&collapse
 , check   => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+Y)?(?:\d+M)?(?:\d+D)?
        (?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?)S)?$/x }
 , example => 'P9M2DT3H5M'
 };


$builtin_types{dayTimeDuration} =
 { parse  => \&collapse
 , check  => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?)S)?$/ }
 , example => 'P2DT3H5M10S'
 };


$builtin_types{yearMonthDuration} =
 { parse  => \&collapse
 , check  => sub { my $val = $_[0]; $val =~ s/\s+//g; $val =~
     m/^\-?P(?:\d+Y)?(?:\d+M)?$/ }
 , example => 'P40Y5M'
 };


$builtin_types{string} =
 { example => 'example'
 };


$builtin_types{normalizedString} =
 { parse   => \&preserve
 , example => 'example'
 };


$builtin_types{language} =
 { parse   => \&collapse
 , check   => sub { my $v = $_[0]; $v =~ s/\s+//g; $v =~
       m/^[a-zA-Z]{1,8}(?:\-[a-zA-Z0-9]{1,8})*$/ }
 , example => 'nl-NL'
 };


sub _valid_ncname($)
{  (my $name = $_[0]) =~ s/\s//;
   $name =~ m/^[a-zA-Z_](?:[\w.-]*)$/;
}

$builtin_types{ID} =
$builtin_types{IDREF} =
$builtin_types{NCName} =
$builtin_types{ENTITY} =
 { parse   => \&collapse
 , check   => sub { $_[0] !~ m/\:/ }
 , example => 'label'
 };

$builtin_types{IDREFS} =
$builtin_types{ENTITIES} =
 { parse   => \&preserve
 , check   => sub { $_[0] !~ m/\:/ }
 , example => 'labels'
 };


$builtin_types{Name} =
 { parse   => \&collapse
 , example => 'name'
 };

$builtin_types{token} =
$builtin_types{NMTOKEN} =
 { parse   => \&collapse
 , example => 'token'
 };


$builtin_types{NMTOKENS} =
 { parse   => \&preserve
 , example => 'tokens'
 };


$builtin_types{anyURI} =
 { parse   => \&collapse
 , check   => sub { $_[0] =~ $RE{URI} }
 , example => 'http://example.com'
 };


sub _valid_qname($)
{   my @ncnames = split /\:/, $_[0];
    return 0 if @ncnames > 2;
    _valid_ncname($_) || return 0 for @ncnames;
    1;
}

$builtin_types{QName} =
 { check   => \&_valid_qname
 , example => 'myns:name'
 };


$builtin_types{NOTATION} = {};

1;
