#!/usr/bin/env bash
# Run activitytool from the container image in ACTIVITYTOOL_DOCKER_IMAGE as if
# it were a local binary. install-activitytool.sh generates an `activitytool`
# wrapper that calls this with the verified image digest.
#
# The repository root (git rev-parse --show-toplevel, else GITHUB_WORKSPACE,
# else the current directory: the first that contains the current directory)
# is mounted read-only at /work and the working directory is the matching
# subdirectory, so relative paths that climb above the current directory but
# stay inside the repository (`../../base`) resolve as they do natively. The
# tool runs offline, as the image's non-root user, with no capabilities.
set -euo pipefail

image=${ACTIVITYTOOL_DOCKER_IMAGE:?ACTIVITYTOOL_DOCKER_IMAGE must name the activitytool image}
cwd=$(pwd -P)

candidates=()
if command -v git > /dev/null; then
  # Outside a Git work tree is a normal case (copied fixtures, tarballs):
  # git's "not a git repository" is expected, and the fallbacks apply.
  if top=$(git rev-parse --show-toplevel 2> /dev/null); then
    candidates+=("$top")
  fi
fi
if [[ -n ${GITHUB_WORKSPACE:-} ]]; then
  candidates+=("$GITHUB_WORKSPACE")
fi
candidates+=("$cwd")

root=
for candidate in "${candidates[@]}"; do
  [[ -d $candidate ]] || continue
  candidate=$(cd "$candidate" && pwd -P)
  if [[ $cwd == "$candidate" || $cwd == "$candidate"/* ]]; then
    root=$candidate
    break
  fi
done

exec docker run --rm --pull never --network none \
  --user 65532:65532 --read-only --cap-drop ALL --security-opt no-new-privileges \
  --volume "$root:/work:ro" --workdir "/work${cwd#"$root"}" \
  "$image" "$@"
