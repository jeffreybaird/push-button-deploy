# Legacy shared-guide lifecycle fixtures

These gzip-compressed JSON file maps were generated with `agent-docs.sh update`
for Phoenix, Sinatra, Rails, React, and Zola at utility commit
`29d9a035bede113c5be3be4d5a9f41c66a6cdfc8`, before canonical `.docs/` outputs.
Each represents an authentic generated `example_app`, including ownership hashes
and both legacy copies. They contain generated guidance and native configuration,
not application secrets or data. Compression avoids repeating large identical
workflow scripts in five text snapshots. Tests unpack them into temporary folders.

Do not regenerate these fixtures with the new layout: migration must remain
compatible with the historical manifests and file bytes.
