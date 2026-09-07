#!/usr/bin/env perl
use strict;
use warnings;
my ($provider, $source, $topic, $description) = @ARGV;
open my $fh, '<', $source or die "$source: $!\n";
local $/;
my $body = <$fh>;
$body =~ s/MyApp/$ENV{AGENT_MODULE}/g;
$body =~ s/my_app/$ENV{AGENT_NAME}/g;
$body =~ s/\bMy Site\b/$ENV{AGENT_TITLE}/g;
$body =~ s/\bmy_site\b/$ENV{AGENT_NAME}/g;
if ($provider eq 'codex') {
    $body =~ s/\A---\r?\n.*?\r?\n---\r?\n\s*//s if length $topic;
    $body =~ s{\.claude/([a-z0-9-]+)\.md}{.agents/skills/$1/SKILL.md}g;
    $body =~ s{\.claude/}{.agents/skills/}g;
    $body =~ s/CLAUDE\.md/AGENTS.md/g;
    $body =~ s/Claude Code|Claude/Codex/g;
    $body =~ s{(?<![\w/-])/a11y-audit}{\$a11y-audit}g;
    $body =~ s/\$ARGUMENTS/Use the files requested by the user, or the current diff when no files are specified./g;
    die "Unconverted Claude syntax in $source\n" if $body =~ /\.claude|CLAUDE|Claude|\$ARGUMENTS/;
    if (length $topic) {
        die "Invalid skill metadata for $source\n" unless $topic =~ /^[a-z0-9-]+$/ && length $description && $description !~ /[\r\n]/;
        $description =~ s/'/''/g;
        $body = "---\nname: $topic\ndescription: '$description'\n---\n\n$body";
    }
}
print $body;
