#!/usr/bin/perl
# Mixed elements

use warnings;
use strict;

use lib 'lib','t';
use TestTools;
use Data::Dumper;

use XML::Compile::Schema;
use XML::Compile::Tester;

use Test::More tests => 39;

my $schema   = XML::Compile::Schema->new( <<__SCHEMA__ );
<schema targetNamespace="$TestNS"
        xmlns="$SchemaNS"
        xmlns:me="$TestNS">

<element name="test1">
  <complexType mixed="true">
    <sequence>
      <element name="count" type="int"/>
    </sequence>
    <attribute name="id" type="string" />
  </complexType>
</element>

</schema>
__SCHEMA__

ok(defined $schema);

my $mixed1 = <<'__XML';
<test1 id="5">
  aaa
  <count>13</count>
  bbb
</test1>
__XML

#### the default = ATTRIBUTES

my $r1 = create_reader($schema, "nameless with attrs" => 'test1');
my $r1a = $r1->($mixed1);

isa_ok($r1a, 'HASH', 'got result');
is($r1a->{id}, '5', 'check attribute');
ok(exists $r1a->{_}, 'has node');
isa_ok($r1a->{_}, 'XML::LibXML::Element');
compare_xml($r1a->{_}->toString, $mixed1);

# test generic writer

my $w1 = create_writer($schema, "nameless with attrs" => 'test1');
my $w1node = XML::LibXML::Element->new('test1');
my $w1a = writer_test($w1, $w1node);
compare_xml($w1a,  '<test1/>');

my $w1b = writer_test($w1, { _ => $w1node, id => 6});
compare_xml($w1b,  '<test1 id="6"/>');

# test template

is($schema->template(PERL => "{$TestNS}test1"), <<'__TEMPL');
# test1 has a mixed content
{ # is a {http://www.w3.org/2001/XMLSchema}string
  id => "example",

  # mixed content cannot be processed automatically
  _ => XML::LibXML::Element->new('test1'), }
__TEMPL

#### explicit ATTRIBUTES

set_compile_defaults mixed_elements => 'ATTRIBUTES';

my $r2 = create_reader($schema, "attributes" => 'test1');
my $r2a = $r2->($mixed1);

isa_ok($r2a, 'HASH', 'got result');
is($r2a->{id}, '5', 'check attribute');
ok(exists $r2a->{_}, 'has node');
isa_ok($r2a->{_}, 'XML::LibXML::Element');
compare_xml($r2a->{_}->toString, $mixed1);

#### CODE reference

my @caught;
set_compile_defaults mixed_elements => sub {@caught = @_; '42' };

my $r3 = create_reader($schema, "code reference" => 'test1');
my $r3a = $r3->($mixed1);
is($r3a, 42);
cmp_ok(scalar @caught, '==', 1);
isa_ok($caught[0], 'XML::LibXML::Element');

#### XML_NODE

set_compile_defaults mixed_elements => 'XML_NODE';

my $r4 = create_reader($schema, "xml-node" => 'test1');
my $r4a = $r4->($mixed1);
isa_ok($r4a, 'XML::LibXML::Element');

#### TEXTUAL

set_compile_defaults mixed_elements => 'TEXTUAL';

my $r5 = create_reader($schema, "textual" => 'test1');
my $r5a = $r5->($mixed1);

isa_ok($r5a, 'HASH', 'got result');
is($r5a->{id}, '5', 'check attribute');
ok(exists $r5a->{_}, 'has text');
is($r5a->{_}, <<'__TEXT');

  aaa
  13
  bbb
__TEXT

#### STRUCTURAL

set_compile_defaults mixed_elements => 'STRUCTURAL';

my $r6 = create_reader($schema, "structural" => 'test1');
my $r6a = $r6->($mixed1);
is_deeply($r6a, {count => 13, id => 5});

#### XML_STRING

set_compile_defaults mixed_elements => 'XML_STRING';

my $r7 = create_reader($schema, "xml-string" => 'test1');
my $r7a = $r7->($mixed1);
is(ref $r7a, '', 'returned is string');
$r7a =~ s/\n?$/\n/;
is($r7a, $mixed1);
