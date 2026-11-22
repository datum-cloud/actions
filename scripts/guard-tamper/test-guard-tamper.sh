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

run overcap GT_REQUIRED=true GT_MAX_MUTANTS=1
if (( rc == 1 )) && grep -q 'exceed max-mutants' "$scratch/overcap.log"; then
  pass "required mode fails over the mutant cap"
else
  fail "required mode fails over the mutant cap (rc=$rc)"
fi

run emptyranges GT_REQUIRED=false GT_RANGES_FILE=/dev/null GT_BASE=
if (( rc == 0 )) && grep -q 'nothing to tamper' "$scratch/emptyranges.log"; then
  pass "empty ranges pass"
else
  fail "empty ranges pass (rc=$rc)"
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
