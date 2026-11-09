#!/usr/bin/env bash
# Install the pinned datumctl release and print the binary's path. The archive
# is checked against the release's checksums file before it is unpacked.
# DATUMCTL, when set, names a datumctl to use instead, for local runs.
#
#   DATUMCTL=$(bash install-datumctl.sh)
set -euo pipefail

# renovate: datasource=github-releases depName=datum-cloud/datumctl
DATUMCTL_VERSION=v0.23.3

if [[ -n ${DATUMCTL:-} ]]; then
  command -v "$DATUMCTL"
  exit 0
fi

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) asset=datumctl_Linux_x86_64.tar.gz ;;
  Linux/aarch64 | Linux/arm64) asset=datumctl_Linux_arm64.tar.gz ;;
  Darwin/arm64) asset=datumctl_Darwin_arm64.tar.gz ;;
  Darwin/x86_64) asset=datumctl_Darwin_x86_64.tar.gz ;;
  *) echo "::error title=Plugin catalog::no datumctl build for $(uname -s)/$(uname -m)" >&2; exit 2 ;;
esac

dir=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/plugin-catalog-datumctl-$DATUMCTL_VERSION
if [[ ! -x $dir/datumctl ]]; then
  mkdir -p "$dir"
  base=https://github.com/datum-cloud/datumctl/releases/download/$DATUMCTL_VERSION
  sums=datumctl_${DATUMCTL_VERSION#v}_checksums.txt
  curl -fsSL --retry 3 -o "$dir/$asset" "$base/$asset"
  curl -fsSL --retry 3 -o "$dir/$sums" "$base/$sums"
  expected=$(awk -v f="$asset" '$2 == f { print $1 }' "$dir/$sums")
  [[ -n $expected ]] || { echo "::error title=Plugin catalog::$asset is not in $sums" >&2; exit 2; }
  if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$dir/$asset" | awk '{ print $1 }')
  else
    actual=$(shasum -a 256 "$dir/$asset" | awk '{ print $1 }')
  fi
  [[ $actual == "$expected" ]] ||
    { echo "::error title=Plugin catalog::checksum mismatch for $asset: expected $expected, got $actual" >&2; exit 2; }
  tar -xzf "$dir/$asset" -C "$dir" datumctl
fi
echo "$dir/datumctl"
