#!/usr/bin/env perl
# SPDX-License-Identifier: MPL-2.0
# Lexical Coq proof-hole detector: match executable statements, not comments
# or string literals. Nested (* ... *) comments are handled explicitly.
# Exit 0: checked and clean; 1: proof hole detected; 2: no check performed.
use strict;
use warnings;

if (@ARGV != 1 || !-f $ARGV[0] || !-r $ARGV[0]) {
    print STDERR "NOT_RUN: expected one readable Coq source file\n";
    exit 2;
}
my $path = $ARGV[0];
open my $fh, '<', $path or do {
    print STDERR "NOT_RUN: cannot read Coq source: $path\n";
    exit 2;
};
local $/;
my $raw = <$fh>;
defined $raw or do {
    print STDERR "NOT_RUN: cannot read content: $path\n";
    exit 2;
};
close $fh;
my $visible = '';
my $depth = 0;
my $quoted = 0;
my $len = length($raw);
for (my $i = 0; $i < $len;) {
    my $pair = substr($raw, $i, 2);
    my $c = substr($raw, $i, 1);
    if ($depth > 0) {
        if ($pair eq '(*') { $depth++; $visible .= '  '; $i += 2; next; }
        if ($pair eq '*)') { $depth--; $visible .= '  '; $i += 2; next; }
        $visible .= ($c eq "\n" ? "\n" : ' ');
        $i++;
        next;
    }
    if ($quoted) {
        # Coq strings escape a quote by doubling it.
        if ($pair eq '""') { $visible .= '  '; $i += 2; next; }
        if ($c eq '"') { $quoted = 0; }
        $visible .= ($c eq "\n" ? "\n" : ' ');
        $i++;
        next;
    }
    if ($pair eq '(*') { $depth = 1; $visible .= '  '; $i += 2; next; }
    if ($c eq '"') { $quoted = 1; $visible .= ' '; $i++; next; }
    $visible .= $c;
    $i++;
}
if ($depth || $quoted) {
    print STDERR "NOT_RUN: unterminated Coq comment or string: $path\n";
    exit 2;
}
my $found = 0;
while ($visible =~ /\b(?:Admitted|admit)\s*\./g) {
    my $offset = $-[0];
    my $prefix = substr($visible, 0, $offset);
    my $line = 1 + ($prefix =~ tr/\n/\n/);
    print "$path:$line: Coq unproved term (Admitted. or admit.)\n";
    $found = 1;
}
exit($found ? 1 : 0);
