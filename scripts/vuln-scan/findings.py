"""Decide whether scanner findings fail the vulnerability scan.

Usage:
  python3 -I findings.py check-ignores <osv-scanner.toml>
  python3 -I findings.py govulncheck <govulncheck.json> <osv-scanner.toml>
  python3 -I findings.py osv <osv-scanner.json> <counts-file>

check-ignores exits 1 if any [[IgnoredVulns]] entry in the caller's
osv-scanner.toml has no id or no reason, so every suppression states why it
exists.

govulncheck has no suppression file of its own, so the scan applies the same
entries to its findings. An entry matches a finding by its Go vulnerability ID
(GO-...) or by any alias (CVE-..., GHSA-...), and stops applying after its
ignoreUntil date. The govulncheck command reads -format json output, prints
each finding that the code calls and whether an entry covered it, and exits 1
if any is not covered.

osv reads osv-scanner -format json output, which already leaves out ignored
entries, and exits 1 if any advisory is a vulnerability. An advisory group
whose every entry is informational in its source database, such as a RustSec
notice that a crate is unmaintained or unsound, is reported but doesn't fail;
cargo audit treats these as warnings too. It writes "<vulnerabilities>
<informational>" group counts to counts-file.
"""

import datetime
import json
import sys
import tomllib


def load_entries(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh).get("IgnoredVulns", [])


def check_ignores(path):
    failed = False
    for number, entry in enumerate(load_entries(path), start=1):
        for key in ("id", "reason"):
            if not str(entry.get(key, "")).strip():
                print(f"::error title=Vulnerability scan::{path}: IgnoredVulns entry {number} "
                      f"({entry.get('id', 'no id')}) has no {key}")
                failed = True
    return 1 if failed else 0


def active_ignores(path):
    now = datetime.datetime.now(datetime.timezone.utc)
    ignores = {}
    for entry in load_entries(path):
        until = entry.get("ignoreUntil")
        if isinstance(until, datetime.datetime):
            if until.tzinfo is None:
                until = until.replace(tzinfo=datetime.timezone.utc)
            if until <= now:
                continue
        elif isinstance(until, datetime.date) and until <= now.date():
            continue
        ignores[entry["id"]] = entry.get("reason", "")
    return ignores


def read_stream(path):
    """govulncheck writes a stream of JSON objects, not one document."""
    decoder = json.JSONDecoder()
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    index = 0
    while True:
        while index < len(text) and text[index].isspace():
            index += 1
        if index == len(text):
            return
        message, index = decoder.raw_decode(text, index)
        yield message


def govulncheck(findings_path, config_path):
    ignores = active_ignores(config_path)
    aliases = {}
    called = set()
    for message in read_stream(findings_path):
        if "osv" in message:
            osv = message["osv"]
            aliases[osv["id"]] = [osv["id"], *osv.get("aliases", [])]
        elif "finding" in message:
            finding = message["finding"]
            # Only a trace that ends in a function is a call govulncheck
            # proved reachable; module- and package-level findings are not.
            trace = finding.get("trace") or [{}]
            if trace[0].get("function"):
                called.add(finding["osv"])

    failed = False
    for vuln in sorted(called):
        match = next((i for i in aliases.get(vuln, [vuln]) if i in ignores), None)
        if match:
            print(f"{vuln}: ignored by osv-scanner.toml entry {match}: {ignores[match]}")
        else:
            print(f"{vuln}: not ignored")
            failed = True
    return 1 if failed else 0


def informational(vuln, package):
    """Return the informational kind if every matching entry has one."""
    kinds = [
        (affected.get("database_specific") or {}).get("informational")
        for affected in vuln.get("affected", [])
        if affected.get("package", {}).get("name") == package
    ]
    return kinds[0] if kinds and all(kinds) else None


def fixed_versions(vuln, package):
    return sorted({
        event["fixed"]
        for affected in vuln.get("affected", [])
        if affected.get("package", {}).get("name") == package
        for range_ in affected.get("ranges", [])
        for event in range_.get("events", [])
        if "fixed" in event
    })


def osv(results_path, counts_path):
    with open(results_path, encoding="utf-8") as fh:
        results = json.load(fh).get("results") or []

    vulnerabilities = []
    notices = []
    for result in results:
        for package in result.get("packages", []):
            info = package["package"]
            by_id = {v["id"]: v for v in package.get("vulnerabilities", [])}
            for group in package.get("groups", []):
                vulns = [by_id[i] for i in group["ids"] if i in by_id]
                if not vulns:
                    continue
                kinds = [informational(v, info["name"]) for v in vulns]
                fixed = sorted({f for v in vulns for f in fixed_versions(v, info["name"])})
                line = (f"{', '.join(group['ids'])}  {info['name']}@{info['version']}"
                        f"  fixed in: {', '.join(fixed) or 'no fix yet'}"
                        f"  {vulns[0].get('summary', '').strip()}")
                if all(kinds):
                    notices.append(f"  {line}  [{', '.join(sorted(set(kinds)))}]")
                else:
                    vulnerabilities.append(f"  {line}")

    if vulnerabilities:
        print(f"Vulnerabilities ({len(vulnerabilities)}):")
        print("\n".join(vulnerabilities))
    if notices:
        print(f"Informational advisories, not failing ({len(notices)}):")
        print("\n".join(notices))
    if not vulnerabilities and not notices:
        print("No known vulnerabilities.")
    with open(counts_path, "w", encoding="utf-8") as fh:
        fh.write(f"{len(vulnerabilities)} {len(notices)}\n")
    return 1 if vulnerabilities else 0


def main(argv):
    if len(argv) == 3 and argv[1] == "check-ignores":
        return check_ignores(argv[2])
    if len(argv) == 4 and argv[1] == "govulncheck":
        return govulncheck(argv[2], argv[3])
    if len(argv) == 4 and argv[1] == "osv":
        return osv(argv[2], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
