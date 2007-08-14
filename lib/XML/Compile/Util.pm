# Copyrights 2006-2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.
use warnings;
use strict;

package XML::Compile::Util;
use vars '$VERSION';
$VERSION = '0.52';
use base 'Exporter';

our @EXPORT = qw/pack_type unpack_type pack_id unpack_id
  odd_elements block_label/;

use Log::Report 'xml-compile';


sub pack_type($$) {
   defined $_[0] && defined $_[1]
       or report PANIC => "pack_type with undef `$_[0]' or `$_[1]'";
   "{$_[0]}$_[1]"
}


sub unpack_type($) { $_[0] =~ m/^\{(.*?)\}(.*)$/ ? ($1, $2) : () }


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

1;
