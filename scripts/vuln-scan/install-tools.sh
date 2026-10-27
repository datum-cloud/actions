#!/usr/bin/env bash
# Install the scanners named as arguments (govulncheck, osv-scanner, trivy)
# into BIN_DIR and add it to GITHUB_PATH. Versions are pinned here for
# Renovate; release binaries are checked against the release's checksums.
#
# With CACHE_DIR set, as run.sh does, each tool goes in its own
# CACHE_DIR/<tool>-<version> directory instead, and an existing one is reused,
# so a version bump installs afresh. Each directory is added to GITHUB_PATH.
set -euo pipefail

# renovate: datasource=go depName=golang.org/x/vuln
GOVULNCHECK_VERSION=v1.9.0
# renovate: datasource=github-releases depName=google/osv-scanner
OSV_SCANNER_VERSION=v2.7.0
# renovate: datasource=github-releases depName=aquasecurity/trivy
TRIVY_VERSION=v0.75.0

BIN_DIR=${BIN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vuln-scan-bin}
CACHE_DIR=${CACHE_DIR:-}
mkdir -p "$BIN_DIR" ${CACHE_DIR:+"$CACHE_DIR"}
download_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vuln-scan-download.XXXXXX")
trap 'rm -rf "$download_dir"' EXIT

case $(uname -s) in
  Linux) os=linux trivy_os=Linux ;;
  Darwin) os=darwin trivy_os=macOS ;;
  *) echo "::error::unsupported OS: $(uname -s)"; exit 1 ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=amd64 trivy_arch=64bit ;;
  arm64 | aarch64) arch=arm64 trivy_arch=ARM64 ;;
  *) echo "::error::unsupported architecture: $(uname -m)"; exit 1 ;;
esac

fetch() {
  curl --fail --silent --show-error --location --retry 3 --output "$download_dir/$2" "$1"
}

verify() {
  local line
  # sha256sum passes on empty input, so require the asset's own line.
  if ! line=$(grep -E "^[0-9a-f]{64}[[:space:]]+\*?$2\$" "$download_dir/$1"); then
    echo "::error::no checksum for $2 in $1"
    exit 1
  fi
  (cd "$download_dir" && sha256sum --check --strict - <<< "$line")
}

path_dirs=()
for tool in "$@"; do
  case $tool in
    govulncheck) version=$GOVULNCHECK_VERSION ;;
    osv-scanner) version=$OSV_SCANNER_VERSION ;;
    trivy) version=$TRIVY_VERSION ;;
    *)
      echo "::error::unknown tool: $tool"
      exit 1
      ;;
  esac
  dest=$BIN_DIR
  if [[ -n $CACHE_DIR ]]; then
    dest=$CACHE_DIR/$tool-$version
    path_dirs+=("$dest")
    if [[ -x $dest/$tool ]]; then
      echo "Using cached $tool $version from $dest"
      continue
    fi
    # Install beside the cache entry and rename it into place, so an
    # interrupted install never looks like a cached one.
    BIN_DIR=$(mktemp -d "$CACHE_DIR/.$tool-$version.XXXXXX")
  fi
  case $tool in
    govulncheck)
      # The Go checksum database verifies the module.
      GOBIN=$BIN_DIR go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
      ;;
    osv-scanner)
      url=https://github.com/google/osv-scanner/releases/download/$OSV_SCANNER_VERSION
      asset=osv-scanner_${os}_${arch}
      fetch "$url/osv-scanner_SHA256SUMS" sums
      fetch "$url/$asset" "$asset"
      verify sums "$asset"
      install -m 0755 "$download_dir/$asset" "$BIN_DIR/osv-scanner"
      ;;
    trivy)
      version=${TRIVY_VERSION#v}
      url=https://github.com/aquasecurity/trivy/releases/download/$TRIVY_VERSION
      asset=trivy_${version}_${trivy_os}-${trivy_arch}.tar.gz
      fetch "$url/trivy_${version}_checksums.txt" sums
      fetch "$url/$asset" "$asset"
      verify sums "$asset"
      tar -xzf "$download_dir/$asset" -C "$download_dir" trivy
      install -m 0755 "$download_dir/trivy" "$BIN_DIR/trivy"
      ;;
  esac
  echo "Installed $tool: $("$BIN_DIR/$tool" --version 2>&1 | grep -m 1 -iE "scanner|version")"
  if [[ -n $CACHE_DIR ]]; then
    rm -rf "$dest"
    mv "$BIN_DIR" "$dest"
    chmod 0755 "$dest"
  fi
done

if [[ -n ${GITHUB_PATH:-} ]]; then
  if [[ -n $CACHE_DIR ]]; then
    printf '%s\n' "${path_dirs[@]+"${path_dirs[@]}"}" >> "$GITHUB_PATH"
  else
    echo "$BIN_DIR" >> "$GITHUB_PATH"
  fi
fi
