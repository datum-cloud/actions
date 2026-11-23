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
timedout=$(count timeout)
flaky=$(count flaky)
unrun=$(count unrun)
deletions=${GT_DELETION_HUNKS:-0}
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
if [[ -s $out/skipped.tsv ]]; then skipped=$(wc -l < "$out/skipped.tsv" | tr -d ' '); fi
notrun=$(( skipped + unrun ))
unchecked=0
: > "$out/unchecked.txt"
if (( notrun > 0 )); then
  : > "$out/keys-all.txt"
  : > "$out/keys-run.txt"
  [[ ! -s $out/skipped.tsv ]] || cut -f6 "$out/skipped.tsv" >> "$out/keys-all.txt"
  while IFS=$'\t' read -r id f _ fl _; do
    key=$f:$(guard_line "$source_root/$f" "$fl")
    echo "$key" >> "$out/keys-all.txt"
    v=$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$verdicts")
    [[ $v == unrun ]] || echo "$key" >> "$out/keys-run.txt"
  done < "$mutants"
  sort -u "$out/keys-all.txt" | { grep -v -x -F -f "$out/keys-run.txt" || true; } > "$out/unchecked.txt"
  if [[ ! -s $out/keys-run.txt ]]; then sort -u "$out/keys-all.txt" > "$out/unchecked.txt"; fi
  unchecked=$(wc -l < "$out/unchecked.txt" | tr -d ' ')
fi
verdicts_seen=$(( killed + survived ))

level=warning
if [[ $required == true ]]; then level=error; fi

{
  echo "## Guard tamper"
  echo
  echo "| Guards with surviving mutants | Surviving mutants | Killed | Timed out | Flaky | Did not compile | Logger calls skipped | Not run |"
  echo "|---|---|---|---|---|---|---|---|"
  echo "| $guards | $survived | $killed | $timedout | $flaky | $uncompiled | $filtered | $notrun |"
  echo
  if (( notrun > 0 )); then
    echo "**Truncated.** $notrun of ${GT_TOTAL_MUTANTS:-?} mutants were not run: $skipped over max-mutants, $unrun out of time. A guard below the cut can still hide an untested clause. Guards with no mutant run: $unchecked."
    echo
    if (( unchecked > 0 )); then
      sed "s|^|- \`$prefix|; s|\$|\`|" "$out/unchecked.txt"
      echo
    fi
  fi
  if (( timedout > 0 || flaky > 0 )); then
    echo "Timed out and flaky mutants count as neither caught nor surviving. A flaky mutant failed once and passed on a re-run."
    echo
  fi
  if (( deletions > 0 )); then
    echo "$deletions hunk(s) only delete lines. Deleted code has nothing to mutate, so a removed guard is not checked here."
    echo
  fi
  if (( guards > 0 )); then
    echo "Each guard below can be removed or weakened and every test still passes. Add a test that fails without it."
  elif (( verdicts_seen == 0 )); then
    echo "No mutation produced a verdict: none was caught or survived, so this run says nothing about the tests."
  elif (( notrun > 0 || timedout > 0 || flaky > 0 )); then
    echo "Every mutation that finished with a verdict fails a test."
  else
    echo "Every guard-shaped mutation on the changed lines fails a test."
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
echo "guards=$guards surviving=$survived killed=$killed timedout=$timedout flaky=$flaky uncompiled=$uncompiled filtered=$filtered notrun=$notrun unchecked-guards=$unchecked deletions=$deletions"
echo "Report: $out/report.md"

if (( notrun > 0 )); then
  echo "::$level title=Guard tamper truncated::ran $(( judged - unrun )) of ${GT_TOTAL_MUTANTS:-?} mutants; $skipped over max-mutants and $unrun out of time were not run, and $unchecked guard(s) were not checked. Raise max-mutants or timeout-minutes, or split the pull request."
fi
if (( verdicts_seen == 0 )); then
  echo "::$level title=Guard tamper::no mutation produced a verdict ($timedout timed out, $flaky flaky, $uncompiled did not compile, $notrun not run)"
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then cat "$out/report.md" >> "$GITHUB_STEP_SUMMARY"; fi
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "survivors=$guards"
    echo "surviving-mutants=$survived"
    echo "killed=$killed"
    if (( notrun > 0 )); then echo "truncated=true"; else echo "truncated=false"; fi
    echo "skipped-mutants=$notrun"
    echo "timed-out=$timedout"
    echo "flaky=$flaky"
    echo "uncompiled=$uncompiled"
    echo "guards<<GUARD_TAMPER_EOF"
    awk -F'\t' -v p="$prefix" '{ print p $1 ":" $2 }' "$out/guards.tsv"
    echo "GUARD_TAMPER_EOF"
  } >> "$GITHUB_OUTPUT"
fi

if [[ $required == true ]] && (( guards > 0 || notrun > 0 || verdicts_seen == 0 )); then
  echo "::error title=Guard tamper::$guards guard(s) survive tampering, $notrun mutant(s) not run, $verdicts_seen verdict(s)"
  exit 1
fi
