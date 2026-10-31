#!/usr/bin/env bash
# Builds image-like trees from the certificates in testdata/, runs filter.sh on
# each, and checks that distrusted roots are dropped from bundles and single
# files, that other roots and symlinks are left alone, that a clean tree
# produces no output, and that an unreadable certificate fails the run.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
testdata=$script_dir/testdata
test_root=$(mktemp -d "${TMPDIR:-/tmp}/drop-distrusted-roots.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

passed=0
failed=0

pass() { passed=$((passed + 1)); echo "ok: $1"; }
fail() { failed=$((failed + 1)); echo "FAIL: $1"; }

expect_certs() {
  local file=$1 want=$2 got
  got=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$file" || true)
  if [[ $got == "$want" ]]; then pass "$file holds $want certificates"; else fail "$file holds $got certificates, want $want"; fi
}

expect_absent() {
  if [[ ! -e $1 && ! -L $1 ]]; then pass "$1 not written"; else fail "$1 written"; fi
}

expect_not_holding() {
  local file=$1 pem=$2 marker
  marker=$(sed -n 2p "$testdata/$pem")
  if grep -qF -- "$marker" "$file"; then fail "$file still holds $pem"; else pass "$file drops $pem"; fi
}

expect_holding() {
  local file=$1 pem=$2 marker
  marker=$(sed -n 2p "$testdata/$pem")
  if grep -qF -- "$marker" "$file"; then pass "$file keeps $pem"; else fail "$file lost $pem"; fi
}

# Debian layout: a bundle, per-root files, and hashed symlinks to them.
image=$test_root/debian/image
out=$test_root/debian/out
mkdir -p "$image/etc/ssl/certs" "$image/usr/share/ca-certificates/mozilla"
cat "$testdata"/{isrg-root-x1,emsign-c1,emsign-g1,emsign-c3,emsign-g3}.pem > "$image/etc/ssl/certs/ca-certificates.crt"
cp "$testdata/emsign-c1.pem" "$image/usr/share/ca-certificates/mozilla/emSign_Root_CA_-_C1.crt"
cp "$testdata/emsign-g1.pem" "$image/usr/share/ca-certificates/mozilla/emSign_Root_CA_-_G1.crt"
ln -s ../../../usr/share/ca-certificates/mozilla/emSign_Root_CA_-_C1.crt "$image/etc/ssl/certs/emSign_Root_CA_-_C1.pem"
sh "$script_dir/filter.sh" "$image" "$out"

bundle=$out/etc/ssl/certs/ca-certificates.crt
expect_certs "$bundle" 2
expect_holding "$bundle" isrg-root-x1.pem
expect_holding "$bundle" emsign-g1.pem
for pem in emsign-c1.pem emsign-c3.pem emsign-g3.pem; do
  expect_not_holding "$bundle" "$pem"
done
if openssl crl2pkcs7 -nocrl -certfile "$bundle" | openssl pkcs7 -print_certs -noout > /dev/null; then
  pass "$bundle parses"
else
  fail "$bundle does not parse"
fi
single=$out/usr/share/ca-certificates/mozilla/emSign_Root_CA_-_C1.crt
if [[ -f $single && ! -s $single ]]; then pass "$single written empty"; else fail "$single not written empty"; fi
expect_absent "$out/usr/share/ca-certificates/mozilla/emSign_Root_CA_-_G1.crt"
expect_absent "$out/etc/ssl/certs/emSign_Root_CA_-_C1.pem"

# A tree with no distrusted roots, as in an image already cleaned upstream.
image=$test_root/clean/image
out=$test_root/clean/out
mkdir -p "$image/etc/ssl/certs"
cat "$testdata"/{isrg-root-x1,emsign-g1}.pem > "$image/etc/ssl/certs/ca-certificates.crt"
sh "$script_dir/filter.sh" "$image" "$out"
if [[ -z $(find "$out" -mindepth 1 -print -quit) ]]; then pass "clean tree writes nothing"; else fail "clean tree wrote files"; fi

# An image with no CA files at all, such as scratch.
image=$test_root/scratch/image
out=$test_root/scratch/out
mkdir -p "$image"
sh "$script_dir/filter.sh" "$image" "$out"
if [[ -z $(find "$out" -mindepth 1 -print -quit) ]]; then pass "empty tree writes nothing"; else fail "empty tree wrote files"; fi

# A certificate block with no body must fail rather than pass unread.
image=$test_root/broken/image
out=$test_root/broken/out
mkdir -p "$image/etc/ssl/certs"
printf -- '-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n' > "$image/etc/ssl/certs/ca-certificates.crt"
if sh "$script_dir/filter.sh" "$image" "$out" 2> /dev/null; then fail "empty certificate passed"; else pass "empty certificate fails"; fi

echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
