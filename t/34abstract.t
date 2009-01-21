#!/usr/bin/perl
# test abstract elements

use warnings;
use strict;

use lib 'lib','t';
use TestTools;

use XML::Compile::Schema;
use XML::Compile::Tester;

use Test::More tests => 11;

my $schema   = XML::Compile::Schema->new( <<__SCHEMA__ );
<schema targetNamespace="$TestNS"
        xmlns="$SchemaNS"
        xmlns:me="$TestNS">

<element name="test1" type="int" abstract="true" />

<element name="test2">
  <complexType>
    <sequence>
      <element ref="me:test1" />
    </sequence>
  </complexType>
</element>

</schema>
__SCHEMA__

ok(defined $schema);

my $error = writer_error($schema, test2 => {test1 => 42});
is($error, "attempt to instantiate abstract element `test1' at {http://test-types}test2/test1");

$error = reader_error($schema, test2 => <<__XML);
<test2><test1>43</test1></test2>
__XML
is($error, "abstract element `test1' used at {http://test-types}test2/test1");

# abstract elements are skipped from the docs
is($schema->template(PERL => "{$TestNS}test2"), <<__TEMPL);
{ # empty sequence
}
__TEMPL
