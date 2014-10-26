# Copyrights 2006-2009 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.06.
use warnings;
use strict;

package TestTools;
use vars '$VERSION';
$VERSION = '1.09';

use base 'Exporter';

use XML::LibXML;
use XML::Compile::Util ':constants';
use XML::Compile::Tester;

use Test::More;
use Test::Deep   qw/cmp_deeply/;
use Log::Report;
use Data::Dumper qw/Dumper/;

our @EXPORT = qw/
 $TestNS
 $SchemaNS
 $SchemaNSi
 $dump_pkg
 test_rw
 error_r
 error_w
 /;

our $TestNS    = 'http://test-types';
our $SchemaNS  = SCHEMA2001;
our $SchemaNSi = SCHEMA2001i;
our $dump_pkg  = 't::dump';

sub test_rw($$$$;$$)
{   my ($schema, $test, $xml, $hash, $expect, $h2) = @_;

    my $type = $test =~ m/\{/ ? $test : "{$TestNS}$test";

    # reader

    my $r = reader_create $schema, $test, $type;
    defined $r or return;

    my $h = $r->($xml);

#warn "READ OUTPUT: ",Dumper $h;
    unless(defined $h)   # avoid crash of is_deeply
    {   if(defined $expect && length($expect))
        {   ok(0, "failure: nothing read from XML");
        }
        else
        {   ok(1, "empty result");
        }
        return;
    }

#warn "COMPARE READ: ", Dumper($h, $hash);
    cmp_deeply($h, $hash, "from xml");

    # Writer

    my $writer = writer_create $schema, $test, $type;
    defined $writer or return;

    my $msg  = defined $h2 ? $h2 : $h;
    my $tree = writer_test $writer, $msg;

    compare_xml($tree, $expect || $xml);
}

sub error_r($$$)
{   my ($schema, $test, $xml) = @_;
    my $type = $test =~ m/\{/ ? $test : "{$TestNS}$test";
    reader_error($schema, $type, $xml);
}

sub error_w($$$)
{   my ($schema, $test, $data) = @_;
    my $type = $test =~ m/\{/ ? $test : "{$TestNS}$test";
    writer_error($schema, $type, $data);
}

1;
