#!/bin/sh
# `sh frontend-build/scripts/release-tarball.sh [out dir]`: the source tarball
# to submit to CRAN, with Ember's own frontend JavaScript minified (#60).
# It builds from the committed HEAD (git archive), not the working tree, so
# uncommitted edits never reach a release. Needs `npm ci` in frontend-build/
# first, for terser. r-universe builds its tarballs from main itself and gets
# the readable files; see docs/ui-2.md, "Offline bundle".
set -eu

root=$(git rev-parse --show-toplevel)
out=$(cd "${1:-.}" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git -C "$root" archive --format=tar --prefix=ember/ HEAD | tar -x -C "$tmp"
(cd "$root/frontend-build" && node scripts/minify-release.mjs "$tmp/ember/inst/frontend")
(cd "$out" && R CMD build "$tmp/ember")
