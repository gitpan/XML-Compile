#!/usr/bin/perl

use warnings;
use strict;

use lib 'lib','t';
use TestTools;

use XML::Compile::Schema;
use XML::Compile::Tester;

use Test::More tests => 105;

use XML::Compile::Util  qw/SCHEMA2001i/;
my $xsi    = SCHEMA2001i;

my $schema = XML::Compile::Schema->new( <<__SCHEMA__ );
<schema targetNamespace="$TestNS"
        xmlns="$SchemaNS"
        xmlns:me="$TestNS">

<element name="test1">
  <complexType>
    <sequence>
      <element name="e1" type="int" />
      <element name="e2" type="int" nillable="true" />
      <element name="e3" type="int" />
    </sequence>
  </complexType>
</element>

#rt.cpan.org #39215
<simpleType name="ID">
  <restriction base="string">
     <length value="18"/>
     <pattern value="[a-zA-Z0-9]{18}"/>
   </restriction>
</simpleType>
<element name="roleId" type="me:ID" nillable="true"/>

<element name="test2">
  <complexType>
    <sequence>
      <element name="roleId" type="me:ID" nillable="true"/>
    </sequence>
  </complexType>
</element>

<element name="test3">
  <complexType>
    <sequence>
       <element name="e3" type="int" minOccurs="0" maxOccurs="12"
           nillable="true" />
    </sequence>
  </complexType>
</element>

<complexType name="t4">
  <sequence>
    <element name="e4a" type="int"/>
    <element name="e4b" type="int"/>
  </sequence>
</complexType>

<element name="test4">
  <complexType>
    <sequence>
      <element name="e4" type="me:t4" minOccurs="0" maxOccurs="12"
         nillable="true" />
    </sequence>
  </complexType>
</element>

<element name="outer">
  <complexType>
    <sequence>
      <element name="inner" minOccurs="0" nillable="true">
        <simpleType>
          <restriction base="string">
            <minLength value="1"/>
          </restriction>
        </simpleType>
      </element>
    </sequence>
  </complexType>
</element>

</schema>
__SCHEMA__

ok(defined $schema);

set_compile_defaults
    include_namespaces => 1
  , elements_qualified => 'NONE';

#
# simple element type
#

test_rw($schema, test1 => <<_XML, {e1 => 42, e2 => 43, e3 => 44} );
<test1 xmlns:xsi="$xsi"><e1>42</e1><e2>43</e2><e3>44</e3></test1>
_XML

test_rw($schema, test1 => <<_XML, {e1 => 42, e2 => 'NIL', e3 => 44} );
<test1 xmlns:xsi="$xsi"><e1>42</e1><e2 xsi:nil="true"/><e3>44</e3></test1>
_XML

my %t1c = (e1 => 42, e2 => 'NIL', e3 => 44);
test_rw($schema, test1 => <<_XML, \%t1c, <<_XMLWriter);
<test1 xmlns:xsi="$xsi"><e1>42</e1><e2 xsi:nil="1" /><e3>44</e3></test1>
_XML
<test1 xmlns:xsi="$xsi"><e1>42</e1><e2 xsi:nil="true"/><e3>44</e3></test1>
_XMLWriter

{   my $error = error_r($schema, test1 => <<_XML);
<test1 xmlns:xsi="$xsi"><e1></e1><e2 xsi:nil="true"/><e3>45</e3></test1>
_XML
   is($error,"illegal value `' for type {http://www.w3.org/2001/XMLSchema}int");
}

{   my %t1b = (e1 => undef, e2 => undef, e3 => 45);
    my $error = error_w($schema, test1 => \%t1b);

    is($error, "required value for element `e1' missing at {http://test-types}test1");
}

{   my $error = error_r($schema, test1 => <<_XML);
<test1><e1>87</e1><e3>88</e3></test1>
_XML
    is($error, "data for element or block starting with `e2' missing at {http://test-types}test1");
}

#
# fix broken specifications
#

set_compile_defaults
    interpret_nillable_as_optional => 1
  , elements_qualified             => 'NONE';

my %t1d = (e1 => 89, e2 => undef, e3 => 90);
my %t1e = (e1 => 91, e2 => 'NIL', e3 => 92);
test_rw($schema, test1 => <<_XML, \%t1d, <<_XML, \%t1e);
<test1><e1>89</e1><e3>90</e3></test1>
_XML
<test1><e1>91</e1><e3>92</e3></test1>
_XML

#
# rt.cpan.org #39215
#

set_compile_defaults   # reset
    include_namespaces => 1
  , elements_qualified => 'NONE';

test_rw($schema, test2 => <<_XML, {roleId => 'NIL'});
<test2 xmlns:xsi="$xsi">
  <roleId xsi:nil="true"/>
</test2>
_XML

test_rw($schema, roleId => <<_XML, 'NIL');
<roleId xmlns:xsi="$xsi" xsi:nil="true"/>
_XML

#
# test3 & test4 based on question by Zbigniew Lukasiak, 24 Nov 2008
#

test_rw($schema, test3 => <<_XML, { e3 => [ 'NIL', 42, 'NIL', 43, 'NIL' ]});
<test3 xmlns:xsi="$xsi">
  <e3 xsi:nil="true"/>
  <e3>42</e3>
  <e3 xsi:nil="true"/>
  <e3>43</e3>
  <e3 xsi:nil="true"/>
</test3>
_XML

my %t4 = ( e4 => [ 'NIL',
                  { 'e4b' => 51, 'e4a' => 50 },
                  'NIL',
                  { 'e4b' => 53, 'e4a' => 52 },
                  { 'e4b' => 55, 'e4a' => 54 },
                  'NIL' ] );

test_rw($schema, test4 => <<_XML, \%t4);
<test4 xmlns:xsi="$xsi">
  <e4 xsi:nil="true"/>
  <e4>
    <e4a>50</e4a>
    <e4b>51</e4b>
  </e4>
  <e4 xsi:nil="true"/>
  <e4>
    <e4a>52</e4a>
    <e4b>53</e4b>
  </e4>
  <e4>
    <e4a>54</e4a>
    <e4b>55</e4b>
  </e4>
  <e4 xsi:nil="true"/>
</test4>
_XML

#
# Bug discovered by Mark Blackman, 20090107
#

set_compile_defaults
    include_namespaces => 1
  , elements_qualified => 1;

test_rw($schema, test1 => <<_XML, {e1 => 42, e2 => 43, e3 => 44} );
<test1 xmlns="$TestNS" xmlns:xsi="$xsi">
  <e1>42</e1>
  <e2>43</e2>
  <e3>44</e3>
</test1>
_XML

test_rw($schema, test1 => <<_XML, {e1 => 42, e2 => 'NIL', e3 => 44} );
<test1 xmlns="$TestNS" xmlns:xsi="$xsi">
   <e1>42</e1>
   <e2 xsi:nil="true"/>
   <e3>44</e3>
</test1>
_XML

#
# Bug reported by Roman Daniel rt.cpan.org#51264
#

set_compile_defaults
    include_namespaces => 1
  , elements_qualified => 1;

test_rw($schema, outer => <<_XML, {});
<outer xmlns="$TestNS" xmlns:xsi="$xsi"/>
_XML

test_rw($schema, outer => <<_XML, {inner => 'NIL'});
<outer xmlns="$TestNS" xmlns:xsi="$xsi">
  <inner xsi:nil="true"/>
</outer>
_XML

test_rw($schema, outer => <<_XML, {inner => 'aap'});
<outer xmlns="$TestNS" xmlns:xsi="$xsi">
  <inner>aap</inner>
</outer>
_XML
