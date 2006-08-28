#!/usr/bin/perl
# test complex type simpleContent extensions

use warnings;
use strict;

use lib 'lib','t';
use TestTools;

use XML::Compile::Schema;

use Test::More tests => 19;

my $schema   = XML::Compile::Schema->new( <<__SCHEMA__ );
<schema targetNamespace="$TestNS"
        xmlns="$SchemaNS"
        xmlns:me="$TestNS">

<simpleType name="t1">
  <restriction base="int" />
</simpleType>

<complexType name="t2">
  <simpleContent>
    <extension base="me:t1">
      <attribute name="a2_a" type="int" />
    </extension>
  </simpleContent>
</complexType>

<element name="test1" type="me:t2" />

<element name="test2">
  <complexType>
    <simpleContent>
      <extension base="int">
        <attribute name="a3_a" type="int" />
      </extension>
    </simpleContent>
  </complexType>
</element>

</schema>
__SCHEMA__

ok(defined $schema);

my %t1 = (_ => 11, a2_a=>16);
run_test($schema, "test1" => <<__XML__, \%t1);
<test1 a2_a="16">11</test1>
__XML__

my %t2 = (_ => 12, a3_a => 17);
run_test($schema, "test2" => <<__XML__, \%t2);
<test2 a3_a="17">12</test2>
__XML__


