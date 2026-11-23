#!/usr/bin/env bash
set -euo pipefail

mutants=$1
verdicts=$2
source_root=$3
out=$4
prefix=$5
required=${GT_REQUIRED:-false}

guard_line() {
  awk -v L="$2" -f "$(dirname "${BASH_SOURCE[0]}")/guard-line.awk" "$1"
}

count() { awk -F'\t' -v v="$1" '$2 == v { n++ } END { print n + 0 }' "$verdicts"; }
killed=$(count killed)
survived=$(count survived)
uncompiled=$(count uncompiled)
filtered=0
if [[ -f $out/filtered.tsv ]]; then filtered=$(wc -l < "$out/filtered.tsv" | tr -d ' '); fi
total=$(wc -l < "$mutants" | tr -d ' ')
judged=$(wc -l < "$verdicts" | tr -d ' ')
if [[ $judged != "$total" ]]; then
  echo "::error title=Guard tamper::$total mutants collected but $judged judged"
  exit 1
fi

: > "$out/survivors.tsv"
while IFS=$'\t' read -r id file _ first _; do
  verdict=$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$verdicts")
  [[ $verdict == survived ]] || continue
  g=$(guard_line "$source_root/$file" "$first")
  printf '%s\t%s\t%s\t%s\n' "$file" "$g" "$id" "$first" >> "$out/survivors.tsv"
done < "$mutants"

sort -t "$(printf '\t')" -k1,1 -k2,2n -k4,4n "$out/survivors.tsv" -o "$out/survivors.tsv"
awk -F'\t' '!seen[$1 FS $2]++ { print $1 "\t" $2 }' "$out/survivors.tsv" > "$out/guards.tsv"
guards=$(wc -l < "$out/guards.tsv" | tr -d ' ')
skipped=0
unchecked=0
if [[ -s $out/skipped.tsv ]]; then
  skipped=$(wc -l < "$out/skipped.tsv" | tr -d ' ')
  cut -f6 "$out/skipped.tsv" | sort -u > "$out/unchecked-all.txt"
  grep -v -x -F -f <(while IFS=$'\t' read -r _ f _ fl _; do printf '%s:%s\n' "$f" "$(guard_line "$source_root/$f" "$fl")"; done < "$mutants") "$out/unchecked-all.txt" > "$out/unchecked.txt" || true
  unchecked=$(wc -l < "$out/unchecked.txt" | tr -d ' ')
fi

level=warning
if [[ $required == true ]]; then level=error; fi

{
  echo "## Guard tamper"
  echo
  echo "| Guards with surviving mutants | Surviving mutants | Killed | Did not compile | Logger calls skipped |"
  echo "|---|---|---|---|---|"
  echo "| $guards | $survived | $killed | $uncompiled | $filtered |"
  echo
  if (( skipped > 0 )); then
    echo "**Truncated.** $skipped of ${GT_TOTAL_MUTANTS:-?} mutants were not run (max-mutants), so a guard below the cut can still hide an untested clause. Guards with no mutant run: $unchecked."
    echo
    if (( unchecked > 0 )); then
      sed "s|^|- \`$prefix|; s|\$|\`|" "$out/unchecked.txt"
      echo
    fi
  fi
  if (( guards == 0 )); then
    if (( skipped > 0 )); then
      echo "Every mutation that ran fails a test."
    else
      echo "Every guard-shaped mutation on the changed lines fails a test."
    fi
  else
    echo "Each guard below can be removed or weakened and every test still passes. Add a test that fails without it."
  fi
} > "$out/report.md"

while IFS=$'\t' read -r file g; do
  text=$(sed -n "${g}p" "$source_root/$file" | sed 's/^[[:space:]]*//')
  n=$(awk -F'\t' -v f="$file" -v g="$g" '$1 == f && $2 == g { n++ } END { print n + 0 }' "$out/survivors.tsv")
  echo "::$level file=$prefix$file,line=$g,title=Guard survives tampering::$n mutant(s) of this guard pass every test: $text"
  {
    echo
    echo "### \`$prefix$file:$g\` $text"
    echo
    echo '```diff'
  } >> "$out/report.md"
  echo
  echo "GUARD $prefix$file:$g  $text"
  awk -F'\t' -v f="$file" -v g="$g" '$1 == f && $2 == g { print $3 "\t" $4 }' "$out/survivors.tsv" |
    while IFS=$'\t' read -r id first; do
      echo "  $prefix$file:$first"
      sed 's/^</    -/; s/^>/    +/' "$out/$id.diff"
      {
        echo "@@ $prefix$file:$first @@"
        sed 's/^< /-/; s/^> /+/' "$out/$id.diff"
      } >> "$out/report.md"
    done
  echo '```' >> "$out/report.md"
done < "$out/guards.tsv"

echo
echo "guards=$guards surviving=$survived killed=$killed uncompiled=$uncompiled filtered=$filtered skipped=$skipped unchecked-guards=$unchecked"
echo "Report: $out/report.md"

if (( skipped > 0 )); then
  echo "::$level title=Guard tamper truncated::ran $judged of ${GT_TOTAL_MUTANTS:-?} mutants; $skipped not run and $unchecked guard(s) not checked. Raise max-mutants or split the pull request."
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then cat "$out/report.md" >> "$GITHUB_STEP_SUMMARY"; fi
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "survivors=$guards"
    echo "surviving-mutants=$survived"
    echo "killed=$killed"
    if (( skipped > 0 )); then echo "truncated=true"; else echo "truncated=false"; fi
    echo "skipped-mutants=$skipped"
    echo "uncompiled=$uncompiled"
    echo "guards<<GUARD_TAMPER_EOF"
    awk -F'\t' -v p="$prefix" '{ print p $1 ":" $2 }' "$out/guards.tsv"
    echo "GUARD_TAMPER_EOF"
  } >> "$GITHUB_OUTPUT"
fi

if [[ $required == true ]] && (( guards > 0 || skipped > 0 )); then
  echo "::error title=Guard tamper::$guards guard(s) survive tampering, $skipped mutant(s) not run"
  exit 1
fi
