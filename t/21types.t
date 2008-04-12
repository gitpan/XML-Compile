#!/usr/bin/perl

use warnings;
use strict;

use lib 'lib','t';
use TestTools;

use XML::Compile::Schema;

use Test::More tests => 103;

my $schema   = XML::Compile::Schema->new( <<__SCHEMA__ );
<schema targetNamespace="$TestNS"
        xmlns="$SchemaNS"
        xmlns:me="$TestNS">

<element name="test1" type="int" />
<element name="test2" type="boolean" />
<element name="test3" type="float" />
<element name="test4" type="NMTOKENS" />
</schema>
__SCHEMA__

ok(defined $schema);

###
### int
###

test_rw($schema, test1 => '<test1>0</test1>', 0); 
test_rw($schema, test1 => '<test1>3</test1>', 3); 

###
### Boolean
###

test_rw($schema, test2 => '<test2>0</test2>', 0); 
test_rw($schema, test2 => '<test2>false</test2>', 0
  , '<test2>false</test2>', 'false'); 

test_rw($schema, test2 => '<test2>1</test2>', 1); 
test_rw($schema, test2 => '<test2>true</test2>', 1
  , '<test2>true</test2>', 'true'); 

###
### Float
###

test_rw($schema, test3 => '<test3>0</test3>', 0); 
test_rw($schema, test3 => '<test3>9</test3>', 9); 

my $error = reader_error($schema, test3 => '<test3></test3>');
is($error, "Value `' is not a float");

$error = writer_error($schema, test3 => 'aap');
is($error, "Value `aap' is not a float");

$error = writer_error($schema, test3 => '');
is($error, "Value `' is not a float");

###
###
###

test_rw($schema, test4 => '<test4>A bc D</test4>', [ qw/A bc D/ ]);
