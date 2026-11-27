#!/usr/bin/env perl
# SPDX-License-Identifier: MPL-2.0
# Coq-only lexical proof-hole guard. Callers must classify .v files as Coq.
# Coq's nested (* ... *) comments can contain quoted strings; delimiters
# within those strings never change the comment depth. SSReflect // is code,
# not a line comment. This is not a substitute for compiling Coq proofs.
# Exit 0 checked/clean; 1 proof hole; 2 no reliable assessment.
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

my ($visible, $depth, $quoted, $comment_quoted) = ('', 0, 0, 0);
my $len = length($raw);
for (my $i = 0; $i < $len;) {
    my $pair = substr($raw, $i, 2);
    my $c = substr($raw, $i, 1);
    if ($depth > 0) {
        if ($comment_quoted) {
            if ($pair eq '""') { $visible .= '  '; $i += 2; next; }
            if ($c eq '"') { $comment_quoted = 0; }
        } else {
            if ($c eq '"') { $comment_quoted = 1; }
            elsif ($pair eq '(*') { $depth++; $visible .= '  '; $i += 2; next; }
            elsif ($pair eq '*)') { $depth--; $visible .= '  '; $i += 2; next; }
        }
        $visible .= ($c eq "\n" ? "\n" : ' ');
        $i++;
        next;
    }
    if ($quoted) {
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
if ($depth || $comment_quoted || $quoted) {
    print STDERR "NOT_RUN: unterminated Coq comment or string: $path\n";
    exit 2;
}

my $found = 0;
# Coq 'admit' is a tactic, including forms such as admit; idtac.
# Admitted. closes the proof without a term. Never mask SSReflect //.
while ($visible =~ /\b(?:Admitted\s*\.|admit\b)/g) {
    my $offset = $-[0];
    my $prefix = substr($visible, 0, $offset);
    my $line = 1 + ($prefix =~ tr/\n/\n/);
    print "$path:$line: Coq unproved term (Admitted. or admit tactic)\n";
    $found = 1;
}
exit($found ? 1 : 0);
