#!/usr/bin/perl

use warnings;
use strict;

use lib 'lib','t';
use TestTools;

use XML::Compile::Schema;
use XML::Compile::Tester;
use Math::BigFloat;

use Test::More tests => 127;

my $schema   = XML::Compile::Schema->new( <<__SCHEMA__ );
<schema xmlns="$SchemaNS"
   targetNamespace="$TestNS">

<element name="test1" type="int" />
<element name="test2" type="boolean" />
<element name="test3" type="float" />
<element name="test4" type="NMTOKENS" />
<element name="test5" type="positiveInteger" />
<element name="test6" type="base64Binary" />

</schema>
__SCHEMA__

ok(defined $schema);
set_compile_defaults
    elements_qualified => 'NONE';

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
test_rw($schema, test3 => '<test3>INF</test3>',  Math::BigFloat->binf); 
test_rw($schema, test3 => '<test3>-INF</test3>', Math::BigFloat->binf('-')); 
test_rw($schema, test3 => '<test3>NaN</test3>',  Math::BigFloat->bnan); 

my $error = error_r($schema, test3 => '<test3></test3>');
is($error, "illegal value `' for type {http://www.w3.org/2001/XMLSchema}float");

$error = error_w($schema, test3 => 'aap');
is($error, "illegal value `aap' for type {http://www.w3.org/2001/XMLSchema}float");

$error = error_w($schema, test3 => '');
is($error, "illegal value `' for type {http://www.w3.org/2001/XMLSchema}float");

###

test_rw($schema, test4 => '<test4>A bc D</test4>', [ qw/A bc D/ ]);

###
### Integers
###

test_rw($schema, test5 => '<test5>432000</test5>', Math::BigInt->new(432000)); 

###
### Base64Binary
###

test_rw($schema, test6 => '<test6>SGVsbG8sIFdvcmxkIQ==</test6>', 'Hello, World!'); 

