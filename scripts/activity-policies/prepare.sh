#!/usr/bin/env bash
set -euo pipefail

source_dir=$GITHUB_WORKSPACE/.activity-policies-action
head=$(git -C "$source_dir" rev-parse HEAD)
if [[ $head != "$WORKFLOW_SHA" ]]; then
  echo "::error title=Activity policy tests::scripts checked out at $head, expected $WORKFLOW_SHA"
  exit 1
fi

mv "$source_dir" "$RUNNER_TEMP/activity-policies-action"
echo "SCRIPTS=$RUNNER_TEMP/activity-policies-action/scripts/activity-policies" >> "$GITHUB_ENV"
