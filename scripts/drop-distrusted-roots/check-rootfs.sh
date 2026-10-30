#!/usr/bin/env bash
# check-rootfs.sh ROOTFS PLATFORM... checks the CA bundle in each platform's
# exported filesystem: no distrusted root left, Let's Encrypt still there, and
# the rest of the bundle intact.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rootfs=$1
shift
[[ $# -gt 0 ]] || { echo "usage: check-rootfs.sh ROOTFS PLATFORM..." >&2; exit 2; }

failed=0
for platform in "$@"; do
  bundle=$rootfs/$platform/etc/ssl/certs/ca-certificates.crt
  if [[ ! -s $bundle ]]; then
    echo "FAIL: $platform has no CA bundle"
    failed=1
    continue
  fi
  for pem in emsign-c1 emsign-c3 emsign-g3; do
    if grep -qF -- "$(sed -n 2p "$script_dir/testdata/$pem.pem")" "$bundle"; then
      echo "FAIL: $platform still trusts $pem"
      failed=1
    fi
  done
  if ! grep -qF -- "$(sed -n 2p "$script_dir/testdata/isrg-root-x1.pem")" "$bundle"; then
    echo "FAIL: $platform lost isrg-root-x1"
    failed=1
  fi
  count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle")
  if [[ $count -lt 100 ]]; then
    echo "FAIL: $platform keeps only $count roots"
    failed=1
  fi
  echo "$platform: $count roots"
done
exit "$failed"
