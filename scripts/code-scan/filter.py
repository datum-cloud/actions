"""Split Semgrep findings into kept and suppressed using the central ignore file.

    python3 filter.py --results FILE --ignore-file FILE --scan-root DIR --today YYYY-MM-DD

Writes {"kept": [...], "suppressed": [...]} to stdout. Warnings and errors go
to stderr as workflow commands. Exits 0, or 2 when the ignore file is invalid.

An entry suppresses a finding only when its rule id and its repo-relative path
equal the finding's exactly. There is no glob or prefix matching: the file is
reviewed by code owners, and every pattern widens what a payload can hide
behind. Every entry needs a reason and an ignoreUntil date no more than 12
months after --today. An entry past its date is inactive and warns.
"""
import argparse
import calendar
import datetime
import json
import os
import re
import sys
import tomllib

from report import escape_data

ENTRY_KEYS = {"rule", "path", "reason", "ignoreUntil"}


class IgnoreFileError(Exception):
    pass


def add_months(day, months):
    """Same day-of-month `months` later; a day that does not exist in the
    target month (Feb 29 -> Feb 28) clamps to the month's last day."""
    index = day.year * 12 + day.month - 1 + months
    year, month = divmod(index, 12)
    month += 1
    return datetime.date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def describe(index, entry, label):
    parts = [f"Ignore entry #{index} in {label}"]
    if isinstance(entry, dict) and entry.get("rule") and entry.get("path"):
        parts.append(f"(rule={entry['rule']!r} path={entry['path']!r})")
    return " ".join(parts)


def parse_date(value):
    if isinstance(value, datetime.datetime):
        return None
    if isinstance(value, datetime.date):
        return value
    if isinstance(value, str):
        try:
            return datetime.date.fromisoformat(value)
        except ValueError:
            return None
    return None


def load_entries(ignore_file, today, label=None):
    """Return validated entries as dicts with ignoreUntil as a date. label
    names the file in messages (default: its path), such as "the base commit
    abc1234" when the file is a copy read from Git."""
    label = label or ignore_file
    try:
        with open(ignore_file, "rb") as f:
            doc = tomllib.load(f)
    except FileNotFoundError:
        return []
    except (OSError, tomllib.TOMLDecodeError) as err:
        raise IgnoreFileError(f"cannot read {label}: {err}")

    unknown_tables = set(doc) - {"Ignore"}
    if unknown_tables:
        raise IgnoreFileError(f"{label}: unknown top-level key(s) {sorted(unknown_tables)}; use [[Ignore]]")
    raw = doc.get("Ignore", [])
    if not isinstance(raw, list):
        raise IgnoreFileError(f"{label}: Ignore must be an array of tables, [[Ignore]]")

    latest = add_months(today, 12)
    entries = []
    for i, entry in enumerate(raw, start=1):
        who = describe(i, entry, label)
        if not isinstance(entry, dict):
            raise IgnoreFileError(f"{who} is not a table")
        unknown = set(entry) - ENTRY_KEYS
        if unknown:
            raise IgnoreFileError(f"{who} has unknown key(s) {sorted(unknown)}; allowed: {sorted(ENTRY_KEYS)}")
        for key in ("rule", "path", "reason"):
            value = entry.get(key)
            if not isinstance(value, str) or not value.strip():
                raise IgnoreFileError(f"{who} needs a non-empty string '{key}'")
        if "ignoreUntil" not in entry:
            raise IgnoreFileError(f"{who} needs 'ignoreUntil' (a date up to {latest})")
        until = parse_date(entry["ignoreUntil"])
        if until is None:
            raise IgnoreFileError(f"{who} has an invalid ignoreUntil {entry['ignoreUntil']!r}; use a date like {latest}")
        if until > latest:
            raise IgnoreFileError(f"{who} has ignoreUntil {until}, more than 12 months from {today}; the latest allowed date is {latest}")
        entries.append({**entry, "ignoreUntil": until})
    return entries


SNIPPET_LINES = 20
SNIPPET_CHARS = 2000
# The blank characters of the hidden-code-after-whitespace rule (its W class).
BLANK_RUN = re.compile(
    "[\t\x0b\x0c \u00a0\u1680\u180e\u2000-\u200d\u202f\u205f\u2060\u3000"
    "\ufeff\u2800\u3164\uffa0\u115f\u1160]+"
)


def read_code(scan_root, result):
    """The source lines of a match, which Semgrep's own `lines` field withholds
    ('requires login'). Runs of blank characters (spaces, tabs, Unicode
    spaces, zero-width characters) collapse to one space, so padding cannot
    push the code out of the report. Unreadable files give ''."""
    root = os.path.realpath(scan_root)
    path = os.path.realpath(os.path.join(root, result["path"]))
    if os.path.commonpath([root, path]) != root:
        return ""
    first, last = result["start"]["line"], result.get("end", result["start"])["line"]
    lines = []
    try:
        with open(path, "rb") as f:
            for number, line in enumerate(f, start=1):
                if number > min(last, first + SNIPPET_LINES - 1):
                    break
                if number >= first:
                    lines.append(line.decode("utf-8", "replace").rstrip("\n").rstrip("\r"))
    except OSError:
        return ""
    return BLANK_RUN.sub(" ", "\n".join(lines)).strip()[:SNIPPET_CHARS]


def to_finding(result, scan_root):
    return {
        "rule": result["check_id"].rsplit(".", 1)[-1],
        "path": result["path"],
        "line": result["start"]["line"],
        "message": result.get("extra", {}).get("message", ""),
        "code": read_code(scan_root, result),
    }


def unique(results):
    """One result per rule, path, and line, keeping the first column. Two
    patterns of one rule often match the same line (require("child_process")
    matches at column 1 and at the string), and the explicit-target pass
    repeats the main pass for some files."""
    first = {}
    for r in results:
        key = (r["check_id"].rsplit(".", 1)[-1], r["path"], r.get("start", {}).get("line"))
        col = r.get("start", {}).get("col", 0)
        if key not in first or col < first[key][0]:
            first[key] = (col, id(r))
    keep = {ident for _, ident in first.values()}
    return [r for r in results if id(r) in keep]


def split(findings, entries, today, label="the ignore file"):
    active = {}
    for entry in entries:
        if entry["ignoreUntil"] < today:
            message = f"Ignore entry for rule {entry['rule']} path {entry['path']} in {label} expired on {entry['ignoreUntil']}; its findings are reported again"
            print(f"::warning title=Code scan::{escape_data(message)}", file=sys.stderr)
        else:
            active[(entry["rule"], entry["path"])] = entry
    kept, suppressed = [], []
    for finding in findings:
        entry = active.get((finding["rule"], finding["path"]))
        if entry is None:
            kept.append(finding)
        else:
            suppressed.append({**finding, "reason": entry["reason"], "ignoreUntil": entry["ignoreUntil"].isoformat()})
    return kept, suppressed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True)
    parser.add_argument("--ignore-file", required=True)
    parser.add_argument("--scan-root", required=True)
    parser.add_argument("--today", required=True)
    parser.add_argument("--source-label", help="names the ignore file in messages; default: its path")
    parser.add_argument("--validate-only", action="store_true",
                        help="only check the ignore file: exit 0 if valid, 2 if not, and print nothing on stdout")
    args = parser.parse_args()
    label = args.source_label or args.ignore_file
    try:
        today = datetime.date.fromisoformat(args.today)
        entries = load_entries(args.ignore_file, today, label)
        if args.validate_only:
            return 0
        with open(args.results) as f:
            results = json.load(f).get("results", [])
    except (IgnoreFileError, ValueError, OSError) as err:
        print(f"::error title=Code scan::{escape_data(err)}", file=sys.stderr)
        return 2
    kept, suppressed = split([to_finding(r, args.scan_root) for r in unique(results)], entries, today, label)
    json.dump({"kept": kept, "suppressed": suppressed}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
