#!/usr/bin/env bash
set -euo pipefail

rel=${MUTATE_ORIGINAL#"$GT_MODULE_ROOT"/}
rel=${rel#./}
printf '%s\n' "$rel" >> "$GT_MUTANTS/calls.txt"

changes=$(mktemp "${TMPDIR:-/tmp}/guard-tamper-diff.XXXXXX")
trap 'rm -f "$changes"' EXIT
rc=0
diff "$MUTATE_ORIGINAL" "$MUTATE_CHANGED" > "$changes" || rc=$?
if (( rc > 1 )); then
  printf 'diff failed with %d for %s\n' "$rc" "$rel" >> "$GT_MUTANTS/errors.txt"
  exit 3
fi

read -r hit first last < <(awk -F'\t' -v f="$rel" '
  NR == FNR { if ($1 == f) { n++; s[n] = $2; e[n] = $3 } next }
  /^[0-9]/ {
    split($0, p, /[acd]/)
    m = split(p[1], r, ",")
    a = r[1] + 0
    b = (m > 1) ? r[2] + 0 : a
    if (!seen++) first = a
    if (b > last) last = b
    for (i = 1; i <= n; i++) if (a <= e[i] + 0 && b >= s[i] + 0) hit = 1
  }
  END { printf "%d %d %d\n", hit, first, last }
' "$GT_RANGES" "$changes")

if (( ! hit )); then
  exit 2
fi

if [[ -n ${GT_IGNORE_REGEXP:-} ]]; then
  original=$(sed -n 's/^< //p' "$changes")
  first_line=$(printf '%s\n' "$original" | grep -v -E '^[[:space:]]*$' | head -n 1 || true)
  statements=$(printf '%s\n' "$original" | awk '
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "(" || c == "{" || c == "[") depth++
        else if (c == ")" || c == "}" || c == "]") { depth--; if (depth == 0) closed = 1 }
        else if (c !~ /[[:space:]]/ && depth == 0 && closed) { extra = 1 }
      }
    }
    END { print (extra ? 2 : 1) }
  ')
  if [[ -n $first_line && $statements == 1 ]] && grep -q -E -- "$GT_IGNORE_REGEXP" <<< "$first_line"; then
    printf '%s\t%d\n' "$rel" "$first" >> "$GT_MUTANTS/filtered.tsv"
    exit 2
  fi
fi

pkg=./$(dirname "$rel")
[[ $pkg != ./. ]] || pkg=.
id=$(printf '%04d' "$(( $(wc -l < "$GT_MUTANTS/mutants.tsv") + 1 ))")
cp "$MUTATE_CHANGED" "$GT_MUTANTS/$id.go"
grep -E '^[<>]' "$changes" > "$GT_MUTANTS/$id.diff" || true
printf '%s\t%s\t%s\t%d\t%d\n' "$id" "$rel" "$pkg" "$first" "$last" >> "$GT_MUTANTS/mutants.tsv"
exit 2
