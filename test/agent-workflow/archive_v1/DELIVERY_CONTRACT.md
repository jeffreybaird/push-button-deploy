# Bounded delivery command extension

This additive contract does not change the accepted core guard or installer
tests. The optional `delivery_commands` policy field contains exact argv arrays;
omission is equivalent to an empty list. Parent (both role identity fields
absent) and a valid orchestrator may execute approved delivery commands.
Other children, malformed identity, and unknown identity cannot. The command
must pass both exact policy membership and a bounded delivery syntax check.
These are coordination permissions, not direct source/test edit permissions.

Supported delivery operations are `git branch NAME`, explicit-path
`git add -- PATH...`, `git commit -m MESSAGE`, normal branch-targeted `git push`,
and `gh pr create --draft` with explicitly specified title/body/base/head values.
No prefix allowlist or arbitrary Git/GitHub command becomes authorized. Refuse
shell operators, substitutions, PTY starts, alternate cwd, Git configuration
overrides, reset/clean/checkout/merge/rebase, force pushes, or a non-draft PR,
even if accidentally present in policy. Reject staging root directories,
traversal, absolute external paths, protected enforcement/instruction files,
and options disguised as path arguments. Explicit test paths may be staged;
staging does not grant source editing permission.

Commands with repository hooks execute trusted repository code. This is not a
no-write sandbox guarantee. The installation/audit process must select delivery
commands only after inspecting repository hooks, and must exclude pushes to
default/deployment branches. Known source-writing hooks (including marquee's)
require delivery_commands to remain empty until the hook is made suitable or
the user performs the delivery manually. There is no maintenance command
allowlist in this extension.

Policy values must be arrays of nonempty string argv arrays. Malformed delivery
policy denies evaluation rather than crashing. CLI shape and native platform
event formats are unchanged. Matching uses parsed argv, so harmless shell
quoting is permitted, but appended arguments never inherit an allowance.

## Dynamic per-task delivery

Optional boolean `delivery_enabled` defaults false. When true, the parent and
orchestrator can select per-task arguments within narrowly validated forms:
`git switch -c SAFE_BRANCH`, `git add -- CANONICAL_REPOSITORY_PATH...`,
`git commit -m NONEMPTY_MESSAGE`, `git push -u origin SAFE_NONDEFAULT_BRANCH`,
and `gh pr create --draft --title TEXT --body-file EXISTING_ARTIFACT_FILE`.
No global exact command registration is required for these bounded forms.
Main/master pushes, force/no-verify/config flags, unsafe branch names,
protected or external staging paths, and external body files deny. An absent
staging path is allowed because Git can stage a tracked deletion. Existing
identity, cwd, interactive startup, and shell syntax checks remain applicable.
Nonboolean values deny policy. Repository hook auditing is still mandatory
before enabling this capability; marquee stays disabled while source-writing
hooks exist. Optional exact delivery_commands remains supported independently.
