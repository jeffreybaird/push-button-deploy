#!/usr/bin/env perl
# Shared Phoenix declaration check/injection; never fetches dependencies.
use strict;
use warnings;
my ($mode, $file) = @ARGV;
open my $fh, '<', $file or die "$file: $!\n";
local $/;
my $body = <$fh>;
close $fh;
my $defaults = '{:req, "~> 0.5"}|{:oban, "~> 2.19"}|{:cucumberex, "~> 0.2", only: [:dev, :test], runtime: false}';
my $requested = exists $ENV{APP_EXTRA_DEPS} ? $ENV{APP_EXTRA_DEPS} : $defaults;
my @missing;
my %seen;
# Ignore line comments when checking declarations (not a full Elixir parser).
(my $declared = $body) =~ s/^\s*#.*$//mg;
for my $dep (split /\|/, $requested) {
    $dep =~ s/^\s+|\s+$//g;
    $dep =~ s/,$//;
    next unless length $dep;
    $dep =~ /^\{\s*:([a-z][a-z0-9_]*)\s*,/ or die "Invalid APP_EXTRA_DEPS entry: $dep\n";
    my $atom = $1;
    next if $seen{$atom}++;
    push @missing, $dep unless $declared =~ /\{\s*:\Q$atom\E\s*,/;
}
exit 0 unless @missing;
if ($mode eq 'report') {
    print "agent files: mix.exs is missing dependencies assumed by the guides (not installed):\n";
    print "  $_\n" for @missing;
    print "Add these declarations if needed; APP_EXTRA_DEPS controls this check (empty disables it).\n";
} elsif ($mode eq 'inject') {
    my $block = "      # added by inject-skill-docs.sh (agent guide dependencies)\n" . join('', map { "      $_,\n" } @missing);
    $body =~ s/^(\s*\{\s*:phoenix,[^\n]*\n)/$1$block/m
        or die "Cannot inject dependencies: no standalone Phoenix dependency line in $file\n";
    open my $out, '>', $file or die "$file: $!\n";
    print {$out} $body;
    close $out or die "$file: $!\n";
    print "agent files: injected missing dependencies into mix.exs\n";
} else { die "Unknown dependency mode: $mode\n"; }
