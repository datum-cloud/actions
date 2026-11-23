#!/usr/bin/env bash
set -euo pipefail

fixture=scripts/guard-tamper/testdata/fixture
tested=$(grep -n 'if caller == "" || owner != caller {' "$fixture/guard.go" | cut -d: -f1)
untested=$(grep -n 'if n > maxSize {' "$fixture/guard.go" | cut -d: -f1)
[[ -n $tested && -n $untested ]] || { echo "fixture guards not found"; exit 1; }

echo "survivors=$SURVIVORS killed=$KILLED"
echo "guards:"
echo "$GUARDS"
status=0
[[ $SURVIVORS == 1 ]] || { echo "want 1 surviving guard, got $SURVIVORS"; status=1; }
[[ $TRUNCATED == false ]] || { echo "want an untruncated run, got truncated=$TRUNCATED"; status=1; }
(( KILLED > 0 )) || { echo "want at least one killed mutant, got $KILLED"; status=1; }
grep -q -x -F "$fixture/guard.go:$untested" <<< "$GUARDS" || { echo "untested guard $fixture/guard.go:$untested not reported"; status=1; }
if grep -q -F "$fixture/guard.go:$tested" <<< "$GUARDS"; then echo "tested guard $fixture/guard.go:$tested reported"; status=1; fi
exit "$status"
