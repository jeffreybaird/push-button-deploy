# Repository-specific protected files

An optional `protected_globs` policy list contains repository-relative glob
patterns. Omission means an empty list. Entries are nonempty string patterns
without absolute paths or traversal. Invalid entries or list shape deny policy
evaluation. Matching files are not writable by any role, even if they also match
test_globs or artifact_roots. This preserves repository restrictions such as
biometry's clinical reference data. It does not imply that approved arbitrary
test programs are confined by the guard. Core accepted tests remain unchanged.
