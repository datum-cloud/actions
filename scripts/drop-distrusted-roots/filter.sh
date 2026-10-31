#!/bin/sh
# filter.sh ROOT OUT
#
# Finds every CA certificate file under ROOT that holds a distrusted root and
# writes a copy without it to the same path under OUT. A file that held only
# distrusted roots is written empty, which also neutralizes the hashed
# symlinks OpenSSL resolves to it. Files with nothing to drop are not written,
# so OUT stays empty for an image that is already clean.
set -eu

root=${1:?usage: filter.sh ROOT OUT}
out=${2:?usage: filter.sh ROOT OUT}

distrusted='86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b emSign ECC Root CA - G3
125609aa301da0a249b97a8239cb6a34216f44dcac9f3954b14292f2e8c8608f emSign Root CA - C1
bc4d809b15189d78db3e1d8cf4f9726a795da1643ca5f1358e1ddb0edc0d7eb3 emSign ECC Root CA - C3'

search_dirs='etc/ssl etc/pki usr/share/ca-certificates usr/local/share/ca-certificates'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

scanned=0
changed=0

for dir in $search_dirs; do
  [ -d "$root/$dir" ] || continue
  find "$root/$dir" -type f
done > "$work/files"

while IFS= read -r file; do
  grep -q -- '-----BEGIN CERTIFICATE-----' "$file" || continue
  scanned=$((scanned + 1))

  rm -rf "$work/certs"
  mkdir "$work/certs"
  awk -v dir="$work/certs" '
    /-----BEGIN CERTIFICATE-----/ { n++; body = dir "/" n; inside = 1; next }
    /-----END CERTIFICATE-----/ { close(body); inside = 0; next }
    inside { print > body }
  ' "$file"

  drop=
  for cert in "$work/certs"/*; do
    sum=$(base64 -d < "$cert" | sha256sum | cut -d' ' -f1)
    if [ "$sum" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then
      echo "error: certificate ${cert##*/} in ${file#"$root"} decodes to nothing" >&2
      exit 1
    fi
    name=$(printf '%s\n' "$distrusted" | awk -v sum="$sum" '$1 == sum { $1 = ""; sub(/^ /, ""); print }')
    if [ -n "$name" ]; then
      drop="$drop ${cert##*/}"
      echo "dropped $name from ${file#"$root"}"
    fi
  done
  [ -n "$drop" ] || continue

  rel=${file#"$root"/}
  mkdir -p "$out/$(dirname "$rel")"
  awk -v drop="$drop " '
    /-----BEGIN CERTIFICATE-----/ { n++; skip = index(drop, " " n " ") > 0 }
    !skip { print }
    /-----END CERTIFICATE-----/ { skip = 0 }
  ' "$file" > "$out/$rel"
  chmod 644 "$out/$rel"
  changed=$((changed + 1))
done < "$work/files"

echo "rewrote $changed of $scanned CA certificate files"
