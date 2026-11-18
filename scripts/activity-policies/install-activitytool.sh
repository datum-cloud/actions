#!/usr/bin/env bash
# Provide activitytool on PATH by using a provided ACTIVITYTOOL binary, pulling
# the pinned ghcr.io/milo-os/activitytool container image and creating a small
# wrapper script, or falling back to `go install` when no image tag is pushed yet.
set -euo pipefail

# renovate: datasource=docker depName=ghcr.io/milo-os/activitytool
PINNED_VERSION=v0.9.2
ACTIVITYTOOL_VERSION=${ACTIVITYTOOL_VERSION:-$PINNED_VERSION}
ACTIVITYTOOL_IMAGE=${ACTIVITYTOOL_IMAGE:-ghcr.io/milo-os/activitytool}

if [[ -n ${ACTIVITYTOOL:-} ]]; then
  if resolved=$(command -v "$ACTIVITYTOOL" 2>/dev/null) && [[ -x $resolved ]]; then
    dir=$(cd "$(dirname "$resolved")" && pwd)
    if [[ -n ${GITHUB_PATH:-} ]]; then
      echo "$dir" >> "$GITHUB_PATH"
    fi
    echo "Using provided activitytool: $resolved"
    exit 0
  fi
  echo "::error title=Activity policy tests::ACTIVITYTOOL='$ACTIVITYTOOL' is not executable" >&2
  exit 2
fi

BIN_DIR=${BIN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/activity-policies-bin}
CACHE_DIR=${CACHE_DIR:-}

dest=$BIN_DIR
if [[ -n $CACHE_DIR ]]; then
  mkdir -p "$CACHE_DIR"
  dest=$CACHE_DIR/activitytool-$ACTIVITYTOOL_VERSION
  if [[ -x $dest/activitytool ]]; then
    if [[ -n ${GITHUB_PATH:-} ]]; then
      echo "$dest" >> "$GITHUB_PATH"
    fi
    echo "Using cached activitytool $ACTIVITYTOOL_VERSION from $dest"
    exit 0
  fi
  stage_dir=$(mktemp -d "$CACHE_DIR/.activitytool-$ACTIVITYTOOL_VERSION.XXXXXX")
else
  mkdir -p "$BIN_DIR"
  stage_dir=$BIN_DIR
fi

cleanup() {
  if [[ -n $CACHE_DIR && -d $stage_dir && $stage_dir != "$dest" ]]; then
    rm -rf "$stage_dir"
  fi
}
trap cleanup EXIT

install_from_docker() {
  local image_ref="${ACTIVITYTOOL_IMAGE}:${ACTIVITYTOOL_VERSION}"
  command -v docker >/dev/null 2>&1 || return 1
  docker pull "$image_ref" >/dev/null 2>&1 || return 1

  cat > "$stage_dir/activitytool" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec docker run --rm -v "\$PWD:/work:ro" -w /work "${image_ref}" "\$@"
EOF
  chmod 0755 "$stage_dir/activitytool"
  return 0
}

install_from_go() {
  command -v go >/dev/null 2>&1 || {
    echo "::error title=Activity policy tests::container image ${ACTIVITYTOOL_IMAGE}:${ACTIVITYTOOL_VERSION} could not be pulled and 'go' is unavailable for fallback install" >&2
    exit 2
  }
  echo "Image ${ACTIVITYTOOL_IMAGE}:${ACTIVITYTOOL_VERSION} not found; building activitytool with go install..."
  if GOBIN=$stage_dir go install "go.miloapis.com/activity/cmd/activitytool@$ACTIVITYTOOL_VERSION" 2>/dev/null; then
    return 0
  fi
  echo "Tag $ACTIVITYTOOL_VERSION does not contain cmd/activitytool; installing from @main..."
  GOBIN=$stage_dir go install "go.miloapis.com/activity/cmd/activitytool@main"
}

if ! install_from_docker; then
  install_from_go
fi

if [[ -n $CACHE_DIR ]]; then
  rm -rf "$dest"
  mv "$stage_dir" "$dest"
  chmod 0755 "$dest"
fi

if [[ -n ${GITHUB_PATH:-} ]]; then
  echo "$dest" >> "$GITHUB_PATH"
fi

echo "Installed activitytool: $("$dest/activitytool" --version 2>&1)"
