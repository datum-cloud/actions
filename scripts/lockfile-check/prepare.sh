#!/usr/bin/env bash
set -euo pipefail

if [[ -z ${WORKFLOW_REPOSITORY:-} || -z ${WORKFLOW_SHA:-} ]]; then
  echo "::error title=Lockfile check::job.workflow_repository or job.workflow_sha is empty; this runner can't identify the workflow's own commit"
  exit 1
fi

source_dir=$GITHUB_WORKSPACE/.lockfile-check-action
head=$(git -C "$source_dir" rev-parse HEAD)
if [[ $head != "$WORKFLOW_SHA" ]]; then
  echo "::error title=Lockfile check::scripts checked out at $head, expected $WORKFLOW_SHA"
  exit 1
fi

mv "$source_dir" "$RUNNER_TEMP/lockfile-check-action"
echo "SCRIPTS=$RUNNER_TEMP/lockfile-check-action/scripts/lockfile-check" >> "$GITHUB_ENV"
echo "Lockfile check scripts: $WORKFLOW_REPOSITORY@$WORKFLOW_SHA"
