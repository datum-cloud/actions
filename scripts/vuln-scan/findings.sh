#!/usr/bin/env bash
# Decide whether scanner findings fail the vulnerability scan.
#
# Usage:
#   findings.sh check-ignores <osv-scanner.toml>
#   findings.sh govulncheck <govulncheck.json> <osv-scanner.toml>
#   findings.sh osv <osv-scanner.json> <counts-file>
#
# check-ignores fails if any [[IgnoredVulns]] entry in the caller's
# osv-scanner.toml has no id, no reason, or no ignoreUntil, or an ignoreUntil
# more than 12 months after today, so every suppression says why it exists and
# comes up for review within a year.
#
# govulncheck has no suppression file of its own, so the scan applies the same
# entries to its findings. This is a second implementation of osv-scanner's
# matching, not osv-scanner's own: an entry matches a finding by its Go
# vulnerability ID (GO-...) or any alias (CVE-..., GHSA-...), and stops
# applying at its ignoreUntil. The govulncheck command reads -format json
# output, prints each finding that the code calls and whether an entry covered
# it, and fails if any is not covered.
#
# osv reads osv-scanner -format json output, which already leaves out ignored
# entries, and fails if any advisory is a vulnerability. An advisory group whose
# every entry is informational in its source database, such as a RustSec
# notice that a crate is unmaintained or unsound, is reported but doesn't fail;
# cargo audit treats these as warnings too. It writes "<vulnerabilities>
# <informational>" group counts to counts-file.
#
# TOML goes through toml-to-json.py, which says why it's Python; everything
# else is jq.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

toml_json() {
  if ! python3 -c 'import tomllib' 2> /dev/null; then
    echo "::error title=Vulnerability scan::reading osv-scanner.toml needs python3 3.11 or later (tomllib)" >&2
    return 1
  fi
  python3 -I "$script_dir/toml-to-json.py" "$1"
}

check_ignores() {
  local errors
  errors=$(toml_json "$1" | jq -r --arg path "$1" '
    def blank: . == null or (tostring | test("^\\s*$"));
    (now | gmtime | .[0] += 1 | mktime) as $limit
    | (.IgnoredVulns // []) | to_entries[]
    | (.key + 1) as $number | .value as $entry
    | (if ($entry.id | blank) then "no id" else ($entry.id | tostring) end) as $label
    | (if ($entry.id | blank) then "has no id" else empty end),
      (if ($entry.reason | blank) then "has no reason" else empty end),
      (if $entry.ignoreUntil == null then
         "has no ignoreUntil; every entry needs one, at most 12 months away"
       elif ($entry.ignoreUntil | type) != "string"
         or ($entry.ignoreUntil | test("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$") | not) then
         "has an ignoreUntil that is not a TOML date"
       elif ($entry.ignoreUntil | fromdateiso8601) > $limit then
         "has ignoreUntil \($entry.ignoreUntil[:10]), more than 12 months away; the latest allowed is \($limit | todate[:10])"
       else empty end)
    | "::error title=Vulnerability scan::\($path): IgnoredVulns entry \($number) (\($label)) \(.)"
  ')
  [[ -z $errors ]] && return 0
  printf '%s\n' "$errors"
  return 1
}

govulncheck_findings() {
  local ignores lines
  ignores=$(toml_json "$2")
  # govulncheck writes a stream of JSON objects, which jq reads one by one.
  lines=$(jq -rn --argjson config "$ignores" '
    now as $now
    | ([$config.IgnoredVulns // [] | .[]
        | select(.ignoreUntil == null or (.ignoreUntil | fromdateiso8601) > $now)
        | {(.id | tostring): (.reason // "")}] | add // {}) as $ignores
    | [inputs] as $messages
    | ([$messages[] | .osv | select(. != null) | {(.id): ([.id] + (.aliases // []))}] | add // {}) as $aliases
    # Only a trace that ends in a function is a call govulncheck proved
    # reachable; module- and package-level findings are not.
    | [$messages[] | .finding | select(. != null)
       | select(((.trace // [{}])[0].function // "") != "") | .osv] | unique[]
    | . as $vuln
    | ([($aliases[$vuln] // [$vuln])[] | select($ignores[.] != null)] | first) as $match
    | if $match then "\($vuln): ignored by osv-scanner.toml entry \($match): \($ignores[$match])"
      else "\($vuln): not ignored" end
  ' "$1")
  [[ -z $lines ]] || printf '%s\n' "$lines"
  ! grep -q ': not ignored$' <<< "$lines"
}

osv_findings() {
  local result vulns notices
  result=$(jq -c '
    # The informational kind, if every entry for this package has one.
    def informational($name):
      [.affected[]? | select(.package.name == $name) | .database_specific.informational]
      | if length > 0 and all(. != null and . != "") then .[0] else null end;
    [ .results[]?.packages[]? as $package
      | $package.package as $info
      | ([$package.vulnerabilities[]? | {(.id): .}] | add // {}) as $by_id
      | $package.groups[]? as $group
      | [$group.ids[] as $id | $by_id[$id] | select(. != null)] as $vulns
      | select($vulns | length > 0)
      | [$vulns[] | informational($info.name)] as $kinds
      | ([$vulns[] | .affected[]? | select(.package.name == $info.name)
          | .ranges[]?.events[]? | .fixed // empty] | unique) as $fixed
      | "\($group.ids | join(", "))  \($info.name)@\($info.version)  fixed in: \(if $fixed == [] then "no fix yet" else $fixed | join(", ") end)  \($vulns[0].summary // "" | gsub("^\\s+|\\s+$"; ""))" as $line
      | if all($kinds[]; . != null) then {notice: "  \($line)  [\($kinds | unique | join(", "))]"}
        else {vuln: "  \($line)"} end
    ] | {vulns: [.[].vuln // empty], notices: [.[].notice // empty]}
  ' "$1")
  vulns=$(jq '.vulns | length' <<< "$result")
  notices=$(jq '.notices | length' <<< "$result")
  if [[ $vulns -gt 0 ]]; then
    echo "Vulnerabilities ($vulns):"
    jq -r '.vulns[]' <<< "$result"
  fi
  if [[ $notices -gt 0 ]]; then
    echo "Informational advisories, not failing ($notices):"
    jq -r '.notices[]' <<< "$result"
  fi
  [[ $vulns -gt 0 || $notices -gt 0 ]] || echo "No known vulnerabilities."
  echo "$vulns $notices" > "$2"
  [[ $vulns -eq 0 ]]
}

case "${1:-} $#" in
  "check-ignores 2") check_ignores "$2" ;;
  "govulncheck 3") govulncheck_findings "$2" "$3" ;;
  "osv 3") osv_findings "$2" "$3" ;;
  *)
    sed -n '3,7s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
