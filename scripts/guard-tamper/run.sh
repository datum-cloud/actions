#!/usr/bin/env bash
set -euo pipefail

started=$(date +%s)
scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
module=${GT_PATH:-.}
required=${GT_REQUIRED:-false}
max=${GT_MAX_MUTANTS:-60}
parallel=${GT_PARALLEL:-4}
out=${GT_REPORT_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/guard-tamper}
allowed=(branch/if branch/else branch/case expression/remove statement/remove)
default_ignore='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*(\([^()]*\))?\.)*([Ll]og|[Ll]ogger|klog|slog|logr|[Rr]ecorder|[Ee]ventRecorder|FromContext\([^()]*\))(\.V\([^()]*\))?\.(Info|Infof|Infow|Error|Errorf|Errorw|Debug|Debugf|Warn|Warnf|Warning|Warningf|Print|Printf|Println|Event|Eventf|AnnotatedEventf)\('
export GT_IGNORE_REGEXP=${GT_IGNORE_REGEXP:-$default_ignore}
export GT_REQUIRED=$required
default_priority='authori[sz]|authenticat|permission|forbid|unauthori[sz]ed|denied|tenan|principal|impersonat|caller|signature|resourceversion|quota|conflict|race|lease|epoch'
priority=${GT_PRIORITY_REGEXP:-$default_priority}

budget=${GT_BUDGET_SECONDS:-}
if [[ -z $budget && -n ${GT_JOB_TIMEOUT_MINUTES:-} ]]; then
  budget=$(( (GT_JOB_TIMEOUT_MINUTES - 5) * 60 ))
  (( budget >= 60 )) || budget=60
fi
if [[ -n $budget ]]; then
  export GT_DEADLINE=$(( started + budget ))
  echo "Time budget: ${budget}s; no mutant starts after that"
fi

write_outputs_empty() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'survivors=0\nsurviving-mutants=0\nkilled=0\nuncompiled=0\ntruncated=false\nskipped-mutants=0\ntimed-out=0\nflaky=0\nguards=\n' >> "$GITHUB_OUTPUT"
  fi
}

[[ -f $module/go.mod ]] || { echo "::error title=Guard tamper::no go.mod in $module"; exit 1; }
repo=$(git -C "$module" rev-parse --show-toplevel)
modrel=$(git -C "$module" rev-parse --show-prefix)
case $(cd "$out" 2>/dev/null && pwd -P || echo "$out")/ in
  "$(cd "$repo" && pwd -P)"/*) echo "::error title=Guard tamper::report directory $out is inside the repository"; exit 1 ;;
esac
rm -rf "$out"
mkdir -p "$out/mutants"
: > "$out/mutants/mutants.tsv"
: > "$out/mutants/calls.txt"

if [[ -n ${GT_RANGES_FILE:-} ]]; then
  cp "$GT_RANGES_FILE" "$out/ranges.raw"
else
  if [[ -z ${GT_BASE:-} || ${GT_EVENT:-} == pull_request_target ]]; then
    reason="no base commit to diff against: run it on pull_request, or pass base"
    if [[ ${GT_EVENT:-} == pull_request_target ]]; then reason="pull_request_target checks out the base branch, so there is no diff: run it on pull_request"; fi
    if [[ $required == true ]]; then
      echo "::error title=Guard tamper::$reason"
      exit 1
    fi
    echo "::notice title=Guard tamper::$reason; nothing to tamper"
    write_outputs_empty
    exit 0
  fi
  if [[ $(git -C "$module" cat-file -t "$GT_BASE") == tree ]]; then
    from=$GT_BASE
  else
    from=$(git -C "$module" merge-base "$GT_BASE" HEAD)
  fi
  git -C "$module" diff -U0 --no-color --no-ext-diff --relative --src-prefix=a/ --dst-prefix=b/ "$from" HEAD -- '*.go' > "$out/diff.patch"
  bash "$scripts/diff-ranges.sh" "$out/deletions.tsv" < "$out/diff.patch" > "$out/ranges.raw"
fi

: > "$out/ranges.tsv"
[[ -f $out/deletions.tsv ]] || : > "$out/deletions.tsv"
deletions=$(wc -l < "$out/deletions.tsv" | tr -d ' ')
while IFS=$'\t' read -r file start end; do
  [[ -f $module/$file ]] || continue
  if head -n 30 "$module/$file" | grep -q -E '^// Code generated .* DO NOT EDIT\.$'; then continue; fi
  printf '%s\t%s\t%s\n' "$file" "$start" "$end" >> "$out/ranges.tsv"
done < "$out/ranges.raw"

if [[ ! -s $out/ranges.tsv ]]; then
  msg="No added or changed non-test Go lines; nothing to tamper."
  if (( deletions > 0 )); then msg="$msg $deletions hunk(s) only delete lines, and deleted code has nothing to mutate, so a removed guard is not checked."; fi
  echo "$msg"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '## Guard tamper\n\n%s\n' "$msg" >> "$GITHUB_STEP_SUMMARY"; fi
  write_outputs_empty
  exit 0
fi
echo "Changed ranges:"
cat "$out/ranges.tsv"

for (( i = 0; i < parallel; i++ )); do
  mkdir -p "$out/work/$i"
  tar -C "$repo" --exclude=./.git -cf - . | tar -C "$out/work/$i" -xf -
done
work0=$out/work/0/$modrel
work0=${work0%/}

disable=()
while read -r name; do
  skip=1
  for a in "${allowed[@]}"; do [[ $name == "$a" ]] && skip=0; done
  (( skip )) && disable+=(--disable "$name")
done < <(go-mutesting --list-mutators)
echo "Mutators: ${allowed[*]}"

mapfile -t files < <(cut -f1 "$out/ranges.tsv" | sort -u)
collect() {
  local dir=$out/collect/$1
  mkdir -p "$dir"
  : > "$dir/mutants.tsv"
  : > "$dir/calls.txt"
  (
    cd "$work0"
    GT_MODULE_ROOT=$work0 GT_RANGES=$out/ranges.tsv GT_MUTANTS=$dir \
      go-mutesting --exec "$scripts/collect.sh" "${disable[@]}" "$2" > "$dir/go-mutesting.log" 2>&1
  ) || { echo "go-mutesting failed on $2" >> "$dir/errors.txt"; tail -n 40 "$dir/go-mutesting.log" >> "$dir/errors.txt"; }
}
for i in "${!files[@]}"; do
  while (( $(jobs -r -p | wc -l) >= parallel )); do wait -n || true; done
  collect "$i" "${files[$i]}" &
done
wait

: > "$out/filtered.tsv"
for i in "${!files[@]}"; do
  dir=$out/collect/$i
  if [[ -s $dir/errors.txt ]]; then
    echo "::error title=Guard tamper::mutant collection failed"
    cat "$dir/errors.txt"
    exit 1
  fi
  cat "$dir/calls.txt" >> "$out/mutants/calls.txt"
  [[ ! -f $dir/filtered.tsv ]] || cat "$dir/filtered.tsv" >> "$out/filtered.tsv"
  while IFS=$'\t' read -r id rest; do
    n=$(printf '%04d' "$(( $(wc -l < "$out/mutants/mutants.tsv") + 1 ))")
    mv "$dir/$id.go" "$out/mutants/$n.go"
    mv "$dir/$id.diff" "$out/mutants/$n.diff"
    printf '%s\t%s\n' "$n" "$rest" >> "$out/mutants/mutants.tsv"
  done < "$dir/mutants.tsv"
done
sort -u "$out/mutants/calls.txt" | { grep -v -x -F -f <(printf '%s\n' "${files[@]}") || true; } > "$out/stray.txt"
if [[ -s $out/stray.txt ]]; then
  echo "::error title=Guard tamper::mutated file paths do not match the changed files"
  cat "$out/stray.txt"
  exit 1
fi

total=$(wc -l < "$out/mutants/mutants.tsv" | tr -d ' ')
echo "$total mutants on changed lines"
if (( total == 0 )); then
  echo "::warning title=Guard tamper::Go lines changed but none holds a guard-shaped mutation (if, case, && or || condition, or removable statement); nothing was tested"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '## Guard tamper\n\nGo lines changed, but none holds a guard-shaped mutation, so nothing was tested.\n' >> "$GITHUB_STEP_SUMMARY"; fi
  write_outputs_empty
  exit 0
fi
cp "$out/mutants/mutants.tsv" "$out/selected.tsv"
: > "$out/skipped.tsv"
if (( total > max )); then
  : > "$out/scored.tsv"
  while IFS=$'\t' read -r id file pkg first last; do
    g=$(awk -v L="$first" -f "$scripts/guard-line.awk" "$module/$file")
    text=$(sed -n "${g}p" "$module/$file"; sed -n 's/^< //p' "$out/mutants/$id.diff")
    score=0
    if grep -q -i -E -- "$priority" <<< "$text"; then
      score=2
    elif grep -q -i -E -- "$priority" <<< "$file"; then
      score=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$file" "$pkg" "$first" "$last" "$score" "$file:$g" >> "$out/scored.tsv"
  done < "$out/mutants/mutants.tsv"
  sort -t "$(printf '\t')" -k6,6nr -k1,1 "$out/scored.tsv" |
    awk -F'\t' -v OFS='\t' '{ print ++rank[$7], $0 }' |
    sort -t "$(printf '\t')" -k7,7nr -k1,1n -k2,2 > "$out/ranked.tsv"
  head -n "$max" "$out/ranked.tsv" | cut -f2-6 > "$out/selected.tsv"
  tail -n +"$((max + 1))" "$out/ranked.tsv" | cut -f2-6,8 > "$out/skipped.tsv"
  echo "$total mutants exceed max-mutants ($max): running $max, guards matching the priority pattern first, one mutant per guard before a second"
fi

read -r -a flags <<< "${GT_GO_TEST_FLAGS:-}"
mapfile -t packages < <(cut -f3 "$out/selected.tsv" | sort -u)
echo "Baseline: ${packages[*]}"
baseline_timeout=${GT_TEST_TIMEOUT:-300}
if [[ -n ${GT_DEADLINE:-} ]] && (( GT_DEADLINE - $(date +%s) < baseline_timeout )); then
  baseline_timeout=$(( GT_DEADLINE - $(date +%s) ))
fi
out_of_time=0
if (( baseline_timeout < 5 )); then
  out_of_time=1
elif ! (cd "$work0" && go test -count=1 -timeout "${baseline_timeout}s" "${flags[@]}" "${packages[@]}") > "$out/baseline.log" 2>&1; then
  if [[ -n ${GT_DEADLINE:-} ]] && grep -q -E '^panic: test timed out after' "$out/baseline.log" && (( $(date +%s) + 5 >= GT_DEADLINE )); then
    out_of_time=1
  else
    echo "::error title=Guard tamper::tests fail before any mutation; no verdict is possible"
    tail -n 40 "$out/baseline.log"
    exit 1
  fi
fi
if (( out_of_time )); then
  echo "Time budget spent before the baseline finished; no mutant runs"
  awk -F'\t' -v OFS='\t' '{ print $1, "unrun" }' "$out/selected.tsv" > "$out/verdicts.tsv"
  cp "$out/mutants/"*.diff "$out/"
  GT_TOTAL_MUTANTS=$total GT_DELETION_HUNKS=$deletions bash "$scripts/report.sh" "$out/selected.tsv" "$out/verdicts.tsv" "$module" "$out" "$modrel"
  exit $?
fi

for (( i = 0; i < parallel; i++ )); do : > "$out/shard-$i.tsv"; done
awk -F'\t' -v p="$parallel" -v o="$out" '{ print > (o "/shard-" ((NR - 1) % p) ".tsv") }' "$out/selected.tsv"

pids=()
for (( i = 0; i < parallel; i++ )); do
  w=$out/work/$i/$modrel
  GT_MUTANTS=$out/mutants bash "$scripts/worker.sh" "$out/shard-$i.tsv" "${w%/}" "$out/verdicts-$i.tsv" &
  pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
if (( failed )); then echo "::error title=Guard tamper::a test worker failed"; exit 1; fi
cat "$out"/verdicts-*.tsv > "$out/verdicts.tsv"

cp "$out/mutants/"*.diff "$out/"
GT_TOTAL_MUTANTS=$total GT_DELETION_HUNKS=$deletions bash "$scripts/report.sh" "$out/selected.tsv" "$out/verdicts.tsv" "$module" "$out" "$modrel"
