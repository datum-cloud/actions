#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/lockfile-check-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
export GIT_CEILING_DIRECTORIES=$test_root

awks=()
if [[ -n ${TEST_AWKS:-} ]]; then
  for candidate in $TEST_AWKS; do
    command -v "$candidate" > /dev/null || { echo "awk '$candidate' not found" >&2; exit 2; }
    awks+=("$candidate")
  done
else
  for candidate in awk mawk original-awk gawk; do
    command -v "$candidate" > /dev/null && awks+=("$candidate")
  done
fi
for required in ${REQUIRE_AWKS:-}; do
  command -v "$required" > /dev/null || { echo "required awk '$required' not found" >&2; exit 2; }
done
[[ ${#awks[@]} -gt 0 ]] || { echo "no awk found" >&2; exit 2; }

passed=0
failed=0

materialize() {
  local src=$1 dest=$2 file
  mkdir -p "$dest"
  cp -R "$src/." "$dest/"
  rm -f "$dest/expect" "$dest/absent" "$dest/env" "$dest/git" "$dest/delete"
  while IFS= read -r -d '' file; do
    mv "$file" "${file%.fixture}"
  done < <(find "$dest" -name '*.fixture' -print0)
}

run_case() {
  local scripts=$1 awk_cmd=$2 name=$3 quiet=$4
  local src=$script_dir/testdata/$name dir=$test_root/case-$$-$name
  local want status=0 out line problems=""
  case $name in
    pass-*) want=0 ;;
    fail-*) want=1 ;;
    error-*) want=2 ;;
  esac
  rm -rf "$dir"
  materialize "$src" "$dir"
  if [[ -e $src/git ]]; then
    git -C "$dir" init -q
    git -C "$dir" add -A
    git -C "$dir" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -q -m fixture
  fi
  if [[ -f $src/delete ]]; then
    while IFS= read -r line; do
      [[ -z $line ]] || rm -f "${dir:?}/$line"
    done < "$src/delete"
  fi
  out=$(
    unset ALLOWED_REGISTRIES EXCLUDE_PATHS REQUIRE_LOCKFILE ALLOW_UNCHECKED_YARN_ARTIFACTS YQ
    if [[ -f $src/env ]]; then
      while IFS= read -r line; do
        export "${line%%=*}=${line#*=}"
      done < "$src/env"
    fi
    AWK=$awk_cmd SCAN_PATH=$dir bash "$scripts/check.sh" 2>&1
  ) || status=$?
  [[ $status -eq $want ]] || problems="$problems exit $status, want $want;"
  if [[ -f $src/expect ]]; then
    while IFS= read -r line; do
      [[ -z $line ]] || grep -qF -- "$line" <<< "$out" || problems="$problems missing '$line';"
    done < "$src/expect"
  fi
  if [[ -f $src/absent ]]; then
    while IFS= read -r line; do
      [[ -z $line ]] || ! grep -qF -- "$line" <<< "$out" || problems="$problems unexpected '$line';"
    done < "$src/absent"
  fi
  if [[ $want -eq 0 && -z $problems && -d $dir ]] && find "$dir" -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.lock' -o -name 'bun.lock' \) | grep -q .; then
    grep -qE ' 0 violations, 0 errors$|nothing to check' <<< "$out" || problems="$problems summary line missing;"
  fi
  if [[ -n $problems ]]; then
    failed=$((failed + 1))
    [[ $quiet == quiet ]] || { echo "FAIL [$awk_cmd] $name:$problems"; while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$out"; }
  else
    passed=$((passed + 1))
    [[ $quiet == quiet ]] || echo "ok   [$awk_cmd] $name"
  fi
}

run_suite() {
  local scripts=$1 quiet=$2 awk_cmd path before=$failed
  for awk_cmd in "${awks[@]}"; do
    for path in "$script_dir"/testdata/*/; do
      path=${path%/}
      [[ ${path##*/} != workflow ]] || continue
      run_case "$scripts" "$awk_cmd" "${path##*/}" "$quiet"
      [[ $quiet == loud || $failed -eq $before ]] || return 0
    done
  done
}

echo "awks: ${awks[*]}"
run_suite "$script_dir" loud
echo "fixtures: $passed passed, $failed failed"
[[ $passed -gt 0 ]] || { echo "no fixture ran" >&2; exit 1; }

tamper() {
  local file=$1 old=$2 new=$3 copy content before_failed
  copy=$test_root/tamper-$$-$tampered
  rm -rf "$copy"
  mkdir -p "$copy"
  cp "$script_dir"/*.sh "$script_dir"/*.awk "$script_dir"/*.jq "$copy/"
  content=$(cat "$copy/$file")
  [[ $content == *"$old"* ]] || { echo "tamper target not found in $file: $old"; failed=$((failed + 1)); return; }
  printf '%s\n' "${content/"$old"/"$new"}" > "$copy/$file"
  before_failed=$failed
  run_suite "$copy" quiet
  if [[ $failed -eq $before_failed ]]; then
    echo "TAMPER SURVIVED: $file: $old"
    failed=$((failed + 1))
  else
    echo "tamper caught ($((failed - before_failed)) failures): $file: $old"
    failed=$before_failed
  fi
  tampered=$((tampered + 1))
}

[[ ${SKIP_TAMPER:-false} != true ]] || exit "$((failed > 0))"

awks=("${awks[0]}")
tampered=0
tamper evaluate.awk 'if (index(s, reg[i]) == 1) return 1' 'if (index(s, "https://") == 1) return 1'
tamper evaluate.awk 'if (wtop == 0) return 0' 'if (wtop == 0) return 1'
tamper evaluate.awk 'if (records == 0) {' 'if (records < 0) {'
tamper evaluate.awk 'if (index(kind, "git") == 1 ||' 'if (index(kind, "gitx") == 1 ||'
tamper evaluate.awk 'if (index(pth, "builtin<") == 1) continue' 'continue'
tamper evaluate.awk 'if (kind == "http") return "insecure http source"' 'if (kind == "http") return "tarball outside approved registries"'
tamper evaluate.awk 'if (!approved(e)) return "archive URL outside approved registries"' 'if (0) return ""'
tamper evaluate.awk 'return substr(ws, at + 11)' 'return root'
tamper pnpm.jq 'sub("\\(.*$"; "")' '.'
tamper pnpm.jq 'if ($r | has("tarball")) then row($name; $r.tarball // "")' 'if ($r | has("tarball")) then row($name; "")'
tamper pnpm.jq 'row($name; "git+" + ($r.repo | tostring))' 'row($name; "")'
tamper pnpm.jq 'row($name; "resolution-type:" + ($type | tostring))' 'row($name; "")'
tamper pnpm.jq 'else $m.lead + ":" + $importer + "/" + $m.rest' 'else .'
tamper pnpm.jq 'test("^(@[^/]+/)?[^/@:]+@[^/:]+$")' 'test("^$")'
tamper pnpm.jq 'row($name; $entry.specifier | depvalue($importer))' 'row($name; "")'
tamper pnpm.jq 'startswith("catalog:")' 'startswith("zzz:")'
tamper pnpm.jq 'else row($name; "resolution:missing") end)' 'else empty end)'
tamper pnpm.jq 'row($name; "resolution:" + ($r | tostring))' 'row($name; "")'
tamper pnpm.jq 'if $s == null then empty else row($name; $s) end' 'empty'
tamper pnpm.jq '((.snapshots // {}) | snapshot_entries)' 'empty'
tamper pnpm.jq '((.catalogs // {}) | to_entries[] | .value | select(type == "object") | dependency_map("."))' 'empty'
tamper check.sh 'then error("duplicate mapping keys") else . end' 'then . else . end'
tamper check.sh 'YAML_FLAGS=(--yaml-fix-merge-anchor-to-spec=true -o=json -I0)' 'YAML_FLAGS=(-o=json -I0)'
tamper check.sh '[[ $out == *github.com/mikefarah/yq*version\ v4.* ]] ||' 'true ||'
tamper check.sh 'out=$("$YQ" --version 2>&1) ||' 'out=$("$YQ" --version 2>&1 || true) ||'
tamper check.sh 'echo "NOTICE excluded' ': "NOTICE excluded'
tamper check.sh 'echo "::warning title=Lockfile check::$excluded' ': "::warning title=Lockfile check::$excluded'
tamper check.sh 'if [[ ! -f $SCAN_PATH/$file ]]; then' 'if false; then'
tamper check.sh '[[ $ALLOW_UNCHECKED_YARN_ARTIFACTS != true ]] || continue' 'continue'
tamper check.sh '*/.yarn/cache/*.zip | */.pnp.cjs | */.pnp.loader.mjs) ;;' '*/.pnp.cjs | */.pnp.loader.mjs) ;;'
tamper check.sh '*/.yarn/cache/*.zip | */.pnp.cjs | */.pnp.loader.mjs) ;;' '*/.yarn/cache/*.zip | */.pnp.loader.mjs) ;;'
tamper check.sh 'if [[ $violations -gt 0 ]]; then
    echo "::error title=Lockfile check::$violations tracked files' 'if false; then
    echo "::error title=Lockfile check::$violations tracked files'
tamper check.sh 'lockfile[ \t]+v1\r?$/' 'lockfile[ \t]+v1/'
tamper yarn-berry.jq 'else error("entry without exactly one resolution")' 'else "x@npm:1"'
tamper yarn-classic.awk 'emit(entry, strip(value))' 'emit(entry, "")'
tamper yarn-classic.awk 'emit(substr(d, 1, at - 1), source)' 'emit(substr(d, 1, at - 1), "")'
tamper yarn-berry.jq '| row($m.name; $m.source);' '| row($m.name; "");'
tamper yarn-classic.awk 'emit(entry, "resolution:missing")' 'emit(entry, "")'
tamper yarn-classic.awk 'if (resolved > 1) {' 'if (resolved > 99) {'
tamper yarn-classic.awk 'line ~ /^[ \t]+"?resolved"?[ \t:]/ &&' 'line ~ /^[ \t]+zzzz/ &&'
tamper yarn-classic.awk 'if (source !~ /^(link|file):/) local_only = 0' 'local_only = 1'
tamper npm.jq 'else row($path; "file:" + $path)' 'else row($path; "")'
tamper npm.jq 'row($name; $entry.version // "")' 'row($name; "")'
tamper check.sh '[[ $entry == https://* &&' '[[ $entry == * &&'
tamper check.sh 'case /$file/ in */node_modules/*) continue ;; esac' ':'
tamper check.sh '    package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | yarn.lock | bun.lock | bun.lockb) ;;' '    package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | bun.lock | bun.lockb) ;;'

echo "tampers: $tampered applied, $failed unresolved"
echo "total: $failed failed"
[[ $failed -eq 0 ]]
