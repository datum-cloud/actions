#!/usr/bin/env bash
set -euo pipefail

awk '
function fail(msg) { print "diff-ranges: " msg > "/dev/stderr"; bad = 1; exit 1 }
{ lines++ }
/^diff --git / { file = ""; next }
/^\+\+\+ / {
  headers++
  if ($0 == "+++ /dev/null") { file = ""; next }
  if (substr($0, 1, 6) != "+++ b/") fail("unexpected file header at line " NR ": " $0)
  file = substr($0, 7)
  keep = (file ~ /\.go$/ && file !~ /_test\.go$/ && file !~ /(^|\/)(testdata|vendor)\//)
  next
}
/^@@/ {
  if (!headers) fail("hunk before any file header at line " NR)
  if (!match($0, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) fail("unparseable hunk header at line " NR ": " $0)
  split(substr($0, RSTART, RLENGTH), part, " ")
  sub(/^\+/, "", part[3])
  n = split(part[3], span, ",")
  count = (n > 1) ? span[2] + 0 : 1
  if (count > 0 && keep && file != "") printf "%s\t%d\t%d\n", file, span[1], span[1] + count - 1
  next
}
END {
  if (bad) exit 1
  if (lines > 0 && !headers) { print "diff-ranges: input has no file headers" > "/dev/stderr"; exit 1 }
}
'
