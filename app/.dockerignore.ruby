# Copied into the generated Sinatra app root as .dockerignore alongside the
# Dockerfile (prep_app, FRAMEWORK=sinatra).
.git/
.gitignore
# Bundler installs fresh in-image; never ship a host vendor tree.
vendor/bundle/
.bundle/
# Local SQLite databases + Litestream shadow files — the real DB is on the
# droplet volume, restored by Litestream. Never bake one into the image.
db/*.sqlite3
db/*.sqlite3-shm
db/*.sqlite3-wal
# Runtime env arrives via .env over SSH at deploy time — never in the image.
.env
# Tests + dev cruft don't belong in the runtime image.
/spec
/tmp
/log
*.log
# CI-only marker (deploy workflow reads it from the checkout, not the image).
.app-name
node_modules/
