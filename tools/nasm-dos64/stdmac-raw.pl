#!/usr/bin/perl
# tools/nasm-dos64/stdmac-raw.pl — regenerate macros.c with zlib
# compression neutralized (identity), so every blob has dsize == zsize.
# preproc.c treats those as incompressible (no uncompress_stdmac call,
# no zlib on the DOS64 target). See docs/25-n4a1-trim.md §2 + N4A.2c.
#
# Usage (from a configured nasm build copy, e.g. build/nasm-x/src):
#   perl -Iperllib /path/to/stdmac-raw.pl version.mac "macros/*.mac" "output/*.mac"
# Output: macros/macros.c (overwrites the configured copy's file only;
# the nasm/ submodule is never touched).
#
# Mechanism: Compress::Zlib::compress is redefined to the identity
# function before macros.pl runs, so `$zlen >= $dlen` always holds and
# macros.pl emits the raw `$data` blob with dsize == zsize. No copy of
# macros.pl, no submodule patch.

use strict;
use warnings;

use Compress::Zlib ();
no warnings 'redefine';
*Compress::Zlib::compress = sub { return $_[0]; };

my $macros_pl = $ENV{NASM_MACROS_PL} // './macros/macros.pl';
do $macros_pl;
die $@ if $@;
