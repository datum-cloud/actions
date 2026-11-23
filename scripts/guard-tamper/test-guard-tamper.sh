#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fixture=$here/testdata/fixture
empty_tree=$(git -C "$here" hash-object -t tree /dev/null)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/guard-tamper-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
failures=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

guarded=$(grep -n 'if caller == "" || owner != caller {' "$fixture/guard.go" | cut -d: -f1)
unguarded=$(grep -n 'if n > maxSize {' "$fixture/guard.go" | cut -d: -f1)
[[ -n $guarded && -n $unguarded ]] || { echo "fixture guards not found"; exit 1; }
prefix=$(git -C "$fixture" rev-parse --show-prefix)

cat > "$scratch/good.patch" <<'PATCH'
diff --git a/a.go b/a.go
--- a/a.go
+++ b/a.go
@@ -3,0 +4,2 @@ func f() {
+	if x {
+	}
@@ -10 +12 @@ func g() {
-	y()
+	z()
@@ -20,2 +22,0 @@ func h() {
-	a()
-	b()
diff --git a/a_test.go b/a_test.go
--- a/a_test.go
+++ b/a_test.go
@@ -1 +1 @@
-x
+y
diff --git a/gone.go b/gone.go
--- a/gone.go
+++ /dev/null
@@ -1 +0,0 @@
-package gone
PATCH
expected=$'a.go\t4\t5\na.go\t12\t12'
if [[ $(bash "$here/diff-ranges.sh" < "$scratch/good.patch") == "$expected" ]]; then
  pass "diff parser keeps added lines of non-test Go files"
else
  fail "diff parser keeps added lines of non-test Go files"
fi

sed 's/^@@ -10 +12 @@/@@ -10 +x12 @@/' "$scratch/good.patch" > "$scratch/broken.patch"
if bash "$here/diff-ranges.sh" < "$scratch/broken.patch" > /dev/null 2>&1; then
  fail "diff parser rejects a malformed hunk header"
else
  pass "diff parser rejects a malformed hunk header"
fi

sed '/^+++ b\/a.go$/d' "$scratch/good.patch" | sed '1,3d' > "$scratch/headless.patch"
if bash "$here/diff-ranges.sh" < "$scratch/headless.patch" > /dev/null 2>&1; then
  fail "diff parser rejects hunks without a file header"
else
  pass "diff parser rejects hunks without a file header"
fi

if [[ -z $(bash "$here/diff-ranges.sh" < /dev/null) ]]; then
  pass "diff parser accepts an empty diff"
else
  fail "diff parser accepts an empty diff"
fi

run() {
  local name=$1
  shift
  rm -rf "$scratch/out"
  rc=0
  env GT_PATH="$fixture" GT_BASE="$empty_tree" GT_REPORT_DIR="$scratch/out" GT_PARALLEL=2 GITHUB_OUTPUT="$scratch/$name.out" "$@" \
    bash "$here/run.sh" > "$scratch/$name.log" 2>&1 || rc=$?
}

run advisory GT_REQUIRED=false
if (( rc == 0 )); then pass "advisory mode exits 0 with survivors"; else fail "advisory mode exits 0 with survivors (rc=$rc)"; cat "$scratch/advisory.log"; fi
if grep -q -x -F "${prefix}guard.go:$unguarded" "$scratch/advisory.out"; then
  pass "the untested guard is reported"
else
  fail "the untested guard is reported"; cat "$scratch/advisory.log"
fi
if grep -q -F "guard.go:$guarded" "$scratch/advisory.out"; then
  fail "the tested guard is not reported"
else
  pass "the tested guard is not reported"
fi
if grep -q -x 'survivors=1' "$scratch/advisory.out" && grep -q '^::warning file=.*guard.go,line='"$unguarded"',' "$scratch/advisory.log"; then
  pass "one guard is annotated"
else
  fail "one guard is annotated"
fi
logline=$((guarded + 1))
if grep -q -x -F "guard.go"$'\t'"$logline" "$scratch/out/filtered.tsv"; then
  pass "the logger call is skipped"
else
  fail "the logger call is skipped"
fi
if [[ ! -e $fixture/report.json ]] && git -C "$fixture" diff --quiet -- .; then
  pass "the checkout is left untouched"
else
  fail "the checkout is left untouched"
fi

run required GT_REQUIRED=true
if (( rc == 1 )); then pass "required mode fails on a survivor"; else fail "required mode fails on a survivor (rc=$rc)"; fi

run nodiff GT_REQUIRED=true GT_BASE=HEAD
if (( rc == 0 )) && grep -q 'nothing to tamper' "$scratch/nodiff.log"; then
  pass "no changed Go lines passes"
else
  fail "no changed Go lines passes (rc=$rc)"
fi

run overcap GT_REQUIRED=false GT_MAX_MUTANTS=1
if (( rc == 0 )) && grep -q -x 'truncated=true' "$scratch/overcap.out" && grep -q -x 'skipped-mutants=3' "$scratch/overcap.out" && grep -q '^::warning title=Guard tamper truncated::ran 1 of 4 mutants' "$scratch/overcap.log"; then
  pass "over the mutant cap, advisory mode runs the cap and says it truncated"
else
  fail "over the mutant cap, advisory mode runs the cap and says it truncated (rc=$rc)"; cat "$scratch/overcap.log"
fi

run overcaprequired GT_REQUIRED=true GT_MAX_MUTANTS=1
if (( rc == 1 )); then pass "required mode fails when the run was truncated"; else fail "required mode fails when the run was truncated (rc=$rc)"; fi

run undercap GT_REQUIRED=false GT_MAX_MUTANTS=4
if grep -q -x 'truncated=false' "$scratch/undercap.out"; then pass "at the cap nothing is truncated"; else fail "at the cap nothing is truncated"; fi

run emptyranges GT_REQUIRED=false GT_RANGES_FILE=/dev/null GT_BASE=
if (( rc == 0 )) && grep -q 'nothing to tamper' "$scratch/emptyranges.log"; then
  pass "empty ranges pass"
else
  fail "empty ranges pass (rc=$rc)"
fi

run nobaserequired GT_REQUIRED=true GT_BASE=
if (( rc == 1 )) && grep -q 'no base commit' "$scratch/nobaserequired.log"; then
  pass "required mode fails when there is no base to diff against"
else
  fail "required mode fails when there is no base to diff against (rc=$rc)"
fi

run nobaseadvisory GT_REQUIRED=false GT_BASE=
if (( rc == 0 )); then pass "advisory mode passes when there is no base"; else fail "advisory mode passes when there is no base (rc=$rc)"; fi

run targetrequired GT_REQUIRED=true GT_EVENT=pull_request_target
if (( rc == 1 )) && grep -q 'pull_request_target' "$scratch/targetrequired.log"; then
  pass "required mode fails under pull_request_target"
else
  fail "required mode fails under pull_request_target (rc=$rc)"
fi

run nobudget GT_REQUIRED=false GT_BUDGET_SECONDS=0
if (( rc == 0 )) && grep -q -x 'truncated=true' "$scratch/nobudget.out" && grep -q -x 'killed=0' "$scratch/nobudget.out" && grep -q 'No mutation produced a verdict' "$scratch/out/report.md"; then
  pass "out of time, advisory mode passes, reports the truncation and claims no verdict"
else
  fail "out of time, advisory mode passes, reports the truncation and claims no verdict (rc=$rc)"; cat "$scratch/nobudget.log"
fi

run jobstart GT_REQUIRED=false GT_JOB_STARTED=$(( $(date +%s) - 3600 )) GT_JOB_TIMEOUT_MINUTES=20
if (( rc == 0 )) && grep -q -x 'truncated=true' "$scratch/jobstart.out" && grep -q -x 'killed=0' "$scratch/jobstart.out"; then
  pass "the time budget counts from the job start"
else
  fail "the time budget counts from the job start (rc=$rc)"
fi

run nobudgetrequired GT_REQUIRED=true GT_BUDGET_SECONDS=0
if (( rc == 1 )); then pass "out of time, required mode fails"; else fail "out of time, required mode fails (rc=$rc)"; fi

mkdir -p "$scratch/timeout/work" "$scratch/timeout/mutants"
cp "$fixture/go.mod" "$fixture/guard.go" "$fixture/guard_test.go" "$scratch/timeout/work/"
awk '/^func CheckSize/ { print "func CheckSize(n int) error {"; print "\tfor {"; print "\t}"; print "}"; skip = 1; next } skip && /^}/ { skip = 0; next } !skip' "$fixture/guard.go" > "$scratch/timeout/mutants/0001.go"
printf '0001\tguard.go\t.\t1\t1\n' > "$scratch/timeout/shard.tsv"
GT_TEST_TIMEOUT=3 GT_MUTANTS=$scratch/timeout/mutants bash "$here/worker.sh" "$scratch/timeout/shard.tsv" "$scratch/timeout/work" "$scratch/timeout/verdicts.tsv" > /dev/null
if [[ $(cat "$scratch/timeout/verdicts.tsv") == $'0001\ttimeout' ]]; then
  pass "a mutant whose tests time out is reported as timed out, not killed"
else
  fail "a mutant whose tests time out is reported as timed out, not killed: $(cat "$scratch/timeout/verdicts.tsv")"
fi

mkdir -p "$scratch/flaky/work" "$scratch/flaky/mutants" "$scratch/flaky/out"
cp "$fixture/go.mod" "$fixture/guard.go" "$fixture/guard_test.go" "$scratch/flaky/work/"
cat > "$scratch/flaky/work/flaky_test.go" <<'GO'
package guardfixture

import (
	"os"
	"testing"
)

func TestFailsOnlyOnTheFirstRun(t *testing.T) {
	mark := os.Getenv("GT_FLAKY_MARK")
	if mark == "" {
		return
	}
	if _, err := os.Stat(mark); err == nil {
		return
	}
	if err := os.WriteFile(mark, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Fatal("fails on the first run only")
}
GO
cp "$fixture/guard.go" "$scratch/flaky/mutants/0001.go"
printf '0001\tguard.go\t.\t%s\t%s\n' "$((unguarded + 1))" "$((unguarded + 1))" > "$scratch/flaky/shard.tsv"
GT_FLAKY_MARK=$scratch/flaky/mark GT_MUTANTS=$scratch/flaky/mutants bash "$here/worker.sh" "$scratch/flaky/shard.tsv" "$scratch/flaky/work" "$scratch/flaky/verdicts.tsv" > /dev/null
if [[ $(cat "$scratch/flaky/verdicts.tsv") == $'0001\tflaky' ]]; then
  pass "a mutant that fails once and passes on a re-run is flaky, not killed"
else
  fail "a mutant that fails once and passes on a re-run is flaky, not killed: $(cat "$scratch/flaky/verdicts.tsv")"
fi
printf '< \t\treturn ErrTooLarge\n> \t\t_ = ErrTooLarge\n' > "$scratch/flaky/out/0001.diff"
rc=0
GT_REQUIRED=true GT_TOTAL_MUTANTS=1 bash "$here/report.sh" "$scratch/flaky/shard.tsv" "$scratch/flaky/verdicts.tsv" "$fixture" "$scratch/flaky/out" "" > "$scratch/flaky/report.log" 2>&1 || rc=$?
if (( rc == 1 )) && grep -q '^## Flaky' "$scratch/flaky/out/report.md" && grep -q "guard.go:$unguarded" "$scratch/flaky/out/report.md"; then
  pass "required mode fails on a flaky guard and the report lists it"
else
  fail "required mode fails on a flaky guard and the report lists it (rc=$rc)"; cat "$scratch/flaky/report.log"
fi

mkdir -p "$scratch/uncompiled/work" "$scratch/uncompiled/mutants"
cp "$fixture/go.mod" "$fixture/guard.go" "$fixture/guard_test.go" "$scratch/uncompiled/work/"
sed 's/return ErrTooLarge/return ErrTooLarge +/' "$fixture/guard.go" > "$scratch/uncompiled/mutants/0001.go"
printf '0001\tguard.go\t.\t1\t1\n' > "$scratch/uncompiled/shard.tsv"
GT_MUTANTS=$scratch/uncompiled/mutants bash "$here/worker.sh" "$scratch/uncompiled/shard.tsv" "$scratch/uncompiled/work" "$scratch/uncompiled/verdicts.tsv" > /dev/null
if [[ $(cat "$scratch/uncompiled/verdicts.tsv") == $'0001\tuncompiled' ]] && cmp -s "$fixture/guard.go" "$scratch/uncompiled/work/guard.go"; then
  pass "a mutant that does not compile is excluded, not killed, and the file is restored"
else
  fail "a mutant that does not compile is excluded, not killed, and the file is restored"
fi

if (( failures )); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
