#!/usr/bin/env bash
# Print the base commit of a pull request's merge checkout, for scan.sh's
# IGNORE_BASE_REF.
#
#   PULL_REQUEST_HEAD_SHA=<sha> bash pr-base.sh [REPO_DIR]
#
# On pull_request, actions/checkout checks out the merge commit GitHub builds
# for the pull request. Its first parent is the base branch as merged and its
# second parent is the pull request's head. The event's base.sha can lag that
# merge commit (reopened, labeled, and edited events reuse an older payload),
# so it may not be in a shallow checkout; the first parent always is, with
# fetch-depth 2. To be sure the checkout really is that merge commit, the
# second parent must equal PULL_REQUEST_HEAD_SHA.
#
# Exit status: 0 with the base SHA on stdout, or 2 with an ::error message on
# stderr, which a $(...) capture in the workflow leaves for the log.
set -euo pipefail

repo=${1:-.}
head_sha=${PULL_REQUEST_HEAD_SHA:-}

fail() {
  echo "::error title=Code scan::$1" >&2
  exit 2
}

[[ $head_sha =~ ^[0-9a-f]{40}$ ]] || fail "PULL_REQUEST_HEAD_SHA must be the pull request's head commit SHA"
second=$(git -C "$repo" rev-parse --verify --quiet 'HEAD^2^{commit}') ||
  fail "the checkout is not a pull request merge commit (no second parent); the scan can't find the base to read the ignore file from"
[[ $second == "$head_sha" ]] ||
  fail "the checkout's second parent ($second) is not the pull request's head ($head_sha); push again or re-run the job once GitHub has rebuilt the merge commit"
git -C "$repo" rev-parse --verify --quiet 'HEAD^1^{commit}' ||
  fail "the base parent of the merge commit is not in the checkout; fetch-depth must be at least 2"
