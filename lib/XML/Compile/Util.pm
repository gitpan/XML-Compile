# Copyrights 2006-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.04.
use warnings;
use strict;

package XML::Compile::Util;
use vars '$VERSION';
$VERSION = '0.80';
use base 'Exporter';

my @constants  = qw/XMLNS SCHEMA1999 SCHEMA2000 SCHEMA2001 SCHEMA2001i/;
our @EXPORT    = qw/pack_type unpack_type/;
our @EXPORT_OK =
  ( qw/pack_id unpack_id odd_elements block_label type_of_node/
  , @constants
  );
our %EXPORT_TAGS = (constants => \@constants);

use constant XMLNS       => 'http://www.w3.org/XML/1998/namespace';
use constant SCHEMA1999  => 'http://www.w3.org/1999/XMLSchema';
use constant SCHEMA2000  => 'http://www.w3.org/2000/10/XMLSchema';
use constant SCHEMA2001  => 'http://www.w3.org/2001/XMLSchema';
use constant SCHEMA2001i => 'http://www.w3.org/2001/XMLSchema-instance';

use Log::Report 'xml-compile';


sub pack_type($;$)
{      @_==1 ? $_[0]
    : !defined $_[0] || !length $_[0] ? $_[1]
    : "{$_[0]}$_[1]"
}


sub unpack_type($) { $_[0] =~ m/^\{(.*?)\}(.*)$/ ? ($1, $2) : ('', $_[0]) }


sub pack_id($$) { "$_[0]#$_[1]" }


sub unpack_id($) { split /\#/, $_[0], 2 }


sub odd_elements(@)
{   my $i = 0;
    map {$i++ % 2 ? $_ : ()} @_;
}


my %block_abbrev = qw/sequence seq_  choice cho_  all all_  group gr_/;
sub block_label($$)
{   my ($kind, $label) = @_;
    return $label if $kind eq 'element';

    $label =~ s/^(?:seq|cho|all|gr)_//;
    $block_abbrev{$kind} . $label;
}


sub type_of_node($)
{   my $node = shift or return ();
    pack_type $node->namespaceURI, $node->localName;
}

1;
