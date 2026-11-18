#!/usr/bin/env bash
set -euo pipefail

source_dir=$GITHUB_WORKSPACE/.lockfile-check-action
head=$(git -C "$source_dir" rev-parse HEAD)
if [[ $head != "$WORKFLOW_SHA" ]]; then
  echo "::error title=Lockfile check::scripts checked out at $head, expected $WORKFLOW_SHA"
  exit 1
fi

mv "$source_dir" "$RUNNER_TEMP/lockfile-check-action"
echo "SCRIPTS=$RUNNER_TEMP/lockfile-check-action/scripts/lockfile-check" >> "$GITHUB_ENV"
