#!/usr/bin/env bash
# Run each scan in PLAN_FILE (written by detect.sh) and fail if any target has
# a known vulnerability that is not ignored, if a scanner errors, or if a
# dependency file cannot be scanned. Writes a table of what was and was not
# scanned to GITHUB_STEP_SUMMARY when it is set.
#
# Ignores come from the scanners' own files at the root of SCAN_PATH:
# osv-scanner.toml for lockfiles and Go, and .trivyignore.yaml or .trivyignore
# for images.
set -uo pipefail

PLAN_FILE=${PLAN_FILE:-${RUNNER_TEMP:?}/vuln-scan-plan.tsv}
SCAN_PATH=${SCAN_PATH:-.}
INCLUDE_DEV=${INCLUDE_DEV:-false}
ALLOW_EMPTY=${ALLOW_EMPTY:-false}
IMAGE_SEVERITY=${IMAGE_SEVERITY:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}
IMAGE_IGNORE_UNFIXED=${IMAGE_IGNORE_UNFIXED:-true}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$SCAN_PATH" && pwd)
work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vuln-scan.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

rows=()
failures=0
row() {
  rows+=("| $1 | \`$2\` | $3 | $4 |")
}
fail() {
  failures=$((failures + 1))
  echo "::error title=Vulnerability scan ($1)::$2"
}

ignore_file=$root/osv-scanner.toml
if [[ -f $ignore_file ]]; then
  if ! python3 -I "$script_dir/findings.py" check-ignores "$ignore_file"; then
    fail ignores "every [[IgnoredVulns]] entry in osv-scanner.toml needs an id and a reason"
  fi
else
  ignore_file=
fi

# osv-scanner takes one config for the whole run. Start from the caller's
# ignore file and, unless dev dependencies are in scope, drop packages that the
# lockfile records as dev-only. Only npm package-lock.json records them in a
# form osv-scanner reads; every other lockfile reports every package.
osv_config=$work_dir/osv-scanner.toml
if [[ -n $ignore_file ]]; then
  cat "$ignore_file" > "$osv_config"
  printf '\n' >> "$osv_config"
else
  : > "$osv_config"
fi
if [[ $INCLUDE_DEV != true ]]; then
  cat >> "$osv_config" <<'TOML'
[[PackageOverrides]]
group = "dev"
ignore = true
reason = "dev dependency; set include-dev-dependencies to scan"
TOML
fi

trivy_ignore=
for candidate in .trivyignore.yaml .trivyignore; do
  if [[ -f $root/$candidate ]]; then
    trivy_ignore=$root/$candidate
    break
  fi
done

scan_go() {
  local dir=$1 status ignored='' out=$work_dir/govulncheck.json err=$work_dir/govulncheck.err
  echo "govulncheck $dir:"
  (cd "$root/$dir" && govulncheck ./... 2> "$err")
  status=$?
  cat "$err" >&2
  if [[ $status -eq 3 && -n $ignore_file ]]; then
    # Text output cannot be filtered, so rerun for the findings as JSON.
    (cd "$root/$dir" && govulncheck -format json ./... > "$out") &&
      python3 -I "$script_dir/findings.py" govulncheck "$out" "$ignore_file"
    case $? in
      0) status=0 ignored=true ;;
      1) ;;
      *) status=2 ;;
    esac
  fi
  case $status in
    0) row go "$dir" govulncheck "no called vulnerabilities${ignored:+ (some ignored)}" ;;
    3)
      row go "$dir" govulncheck "**vulnerabilities found**"
      fail go "$dir: govulncheck found vulnerabilities that the code calls"
      ;;
    *)
      if grep -q 'no packages matched' "$err"; then
        row go "$dir" govulncheck "no Go packages"
      else
        row go "$dir" govulncheck "**scanner error (exit $status)**"
        fail go "$dir: govulncheck exited $status"
      fi
      ;;
  esac
}

scan_lockfile() {
  local ecosystem=$1 file=$2 status vulns notices
  local out=$work_dir/osv-scanner.json counts=$work_dir/osv-scanner.counts
  echo "::group::osv-scanner $file (scanner log)"
  rm -f "$out"
  (cd "$root" && osv-scanner scan source --config "$osv_config" --format json \
    --output-file "$out" --lockfile "$file")
  status=$?
  echo "::endgroup::"
  # osv-scanner exits 1 for any advisory, including informational ones, so
  # its JSON decides instead.
  if [[ $status -le 1 ]]; then
    echo "osv-scanner $file:"
    python3 -I "$script_dir/findings.py" osv "$out" "$counts"
    case $? in
      0 | 1) read -r vulns notices < "$counts" ;;
      *) status=2 ;;
    esac
  fi
  case $status in
    0 | 1)
      if [[ $vulns -gt 0 ]]; then
        row "$ecosystem" "$file" osv-scanner "**vulnerabilities found ($vulns)**"
        fail "$ecosystem" "$file: osv-scanner found $vulns known vulnerabilities"
      elif [[ $notices -gt 0 ]]; then
        row "$ecosystem" "$file" osv-scanner "no known vulnerabilities ($notices informational advisories)"
        echo "::warning title=Vulnerability scan ($ecosystem)::$file: $notices informational advisories, such as unmaintained or unsound packages"
      else
        row "$ecosystem" "$file" osv-scanner "no known vulnerabilities"
      fi
      ;;
    128) row "$ecosystem" "$file" osv-scanner "no packages" ;;
    *)
      row "$ecosystem" "$file" osv-scanner "**scanner error (exit $status)**"
      fail "$ecosystem" "$file: osv-scanner exited $status"
      ;;
  esac
}

scan_image() {
  local image=$1 status args=()
  [[ $IMAGE_IGNORE_UNFIXED == true ]] && args+=(--ignore-unfixed)
  [[ -n $trivy_ignore ]] && args+=(--ignorefile "$trivy_ignore")
  echo "trivy $image:"
  # Exit 3 marks findings so they are told apart from Trivy's own errors (1).
  trivy image --scanners vuln --severity "$IMAGE_SEVERITY" --exit-code 3 \
    --no-progress --skip-version-check "${args[@]}" "$image"
  status=$?
  case $status in
    0) row image "$image" trivy "no known vulnerabilities" ;;
    3)
      row image "$image" trivy "**vulnerabilities found**"
      fail image "$image: Trivy found known vulnerabilities"
      ;;
    *)
      row image "$image" trivy "**scanner error (exit $status)**"
      fail image "$image: trivy exited $status"
      ;;
  esac
}

meta() {
  awk -F'\t' -v key="$1" -v field="$2" '$1 == "meta" && $2 == key { print $field }' "$PLAN_FILE"
}
discovery="$(meta discovery 3), $(meta discovery 4)"
go_line=
requested_go=$(meta go-version 3)
if [[ -n $requested_go ]]; then
  installed_go=$(go env GOVERSION 2> /dev/null || echo "not installed")
  go_line="Go: $installed_go, $(meta go-version 4). Requested $requested_go."
  echo "$go_line"
  # The workflow sets this, so a setup-go step that installed some other
  # version can't pass for the requested one. A bare X.Y means any X.Y patch.
  if [[ ${REQUIRE_GO_VERSION:-false} == true && $installed_go != "go$requested_go" &&
    ! ($requested_go != *.*.* && $installed_go == go$requested_go.*) ]]; then
    row go "$installed_go" setup-go "**doesn't match the requested $requested_go**"
    fail go "installed Go is $installed_go, but the scan requested $requested_go"
  fi
fi

scanned=0
unlocked=0
while IFS=$'\t' read -r action ecosystem target note; do
  case $action in
    scan)
      scanned=$((scanned + 1))
      case $ecosystem in
        go) scan_go "$target" ;;
        image) scan_image "$target" ;;
        *) scan_lockfile "$ecosystem" "$target" ;;
      esac
      ;;
    skip) row "$ecosystem" "$target" "not scanned" "$note" ;;
    unlocked)
      unlocked=$((unlocked + 1))
      row "$ecosystem" "$target" "not scanned" "**no lockfile:** $note"
      echo "::warning title=Vulnerability scan ($ecosystem)::$target has no lockfile, so its dependencies can't be scanned; commit a lockfile, or list it in exclude-paths if it has no dependencies"
      ;;
    unsupported)
      row "$ecosystem" "$target" "not scanned" "**unsupported:** $note"
      fail "$ecosystem" "$target cannot be scanned: $note"
      ;;
  esac
done < "$PLAN_FILE"

if [[ $scanned -eq 0 && $failures -eq 0 && $unlocked -gt 0 ]]; then
  # allow-empty says there are no dependencies; unlocked manifests say there
  # are, so they don't count as nothing to scan.
  fail all "nothing was scanned, but $unlocked manifest(s) declare dependencies without a lockfile. Commit a lockfile, or list manifests with no dependencies in exclude-paths."
  verdict="**Failed:** nothing was scanned, but $unlocked manifest(s) have no lockfile. \`allow-empty\` doesn't cover unlocked dependencies."
elif [[ $scanned -eq 0 && $failures -eq 0 ]]; then
  if [[ $ALLOW_EMPTY == true ]]; then
    echo "::warning title=Vulnerability scan::nothing was scanned: no supported dependency files or images under '$SCAN_PATH'; passing because allow-empty is true"
    verdict="Nothing was scanned. No supported dependency files or images were found, and \`allow-empty\` is \`true\`."
  else
    fail all "nothing was scanned: no supported dependency files or images under '$SCAN_PATH'. Set allow-empty to true if this repository has no dependencies to scan."
    verdict="**Failed:** nothing was scanned. No supported dependency files or images were found. Set \`allow-empty: true\` if this repository has no dependencies to scan."
  fi
elif [[ $failures -gt 0 ]]; then
  verdict="**Failed:** $failures problem(s) across $scanned scanned target(s)."
else
  verdict="**Passed:** no known vulnerabilities in $scanned scanned target(s)."
fi

summary() {
  echo "## Vulnerability scan"
  echo
  echo "$verdict"
  echo
  if [[ ${#rows[@]} -gt 0 ]]; then
    echo "| Ecosystem | Target | Tool | Result |"
    echo "|---|---|---|---|"
    printf '%s\n' "${rows[@]}"
    echo
  fi
  if [[ $INCLUDE_DEV == true ]]; then
    echo "Dev dependencies: included."
  else
    echo "Dev dependencies: excluded from npm \`package-lock.json\` files and development requirements files. Other lockfiles don't record dev dependencies in a form osv-scanner reads, so every package in them is scanned."
  fi
  echo
  echo "File discovery: $discovery."
  echo
  if [[ -n $go_line ]]; then
    echo "$go_line"
    echo
  fi
  local used=()
  [[ -z $ignore_file ]] || used+=("\`osv-scanner.toml\`")
  [[ -z $trivy_ignore ]] || used+=("\`$(basename "$trivy_ignore")\`")
  local joined
  joined=$(IFS=,; echo "${used[*]:-none}")
  echo "Ignore files: ${joined//,/, }"
}

summary
[[ -z ${GITHUB_STEP_SUMMARY:-} ]] || summary >> "$GITHUB_STEP_SUMMARY"

[[ $failures -eq 0 ]]
