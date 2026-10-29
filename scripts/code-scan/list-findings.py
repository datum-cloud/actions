"""Report the findings in Semgrep JSON files; exit 1 for findings, 2 for errors.

    list-findings.py RESULTS IGNORE_FILE SCAN_ROOT TODAY [SUMMARY_FILE]
        [--extra-results FILE]... [--ignore-file-name NAME] [--path-prefix PREFIX]
        [--ignore-source-label LABEL]

RESULTS is the main Semgrep pass; each --extra-results file (the pre-pass, the
explicit-target pass) has the same shape and is merged into it. Scanner
errors from any of them come first and are final: no ignore entry can excuse
them. Findings then go through filter.py, and report.py prints the kept ones
as annotations (and appends a job summary to SUMMARY_FILE); only the kept ones
fail the scan.
"""
import argparse
import json
import os
import subprocess
import sys

from report import escape_data


def is_fatal(e):
    """Errors at level error, and any timeout or out-of-memory error: Semgrep
    reports those as warnings and skips the file, which would hide a payload."""
    kind = e.get("type", "")
    # Some types are [name, details]; only the name says what failed, and the
    # details hold file paths.
    if isinstance(kind, list):
        kind = kind[0] if kind else ""
    kind = "".join(c for c in str(kind).lower() if c.isalpha())
    return str(e.get("level", "")).lower() == "error" or "timeout" in kind or "memory" in kind


def load(path):
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a JSON object")
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results")
    parser.add_argument("ignore_file")
    parser.add_argument("scan_root")
    parser.add_argument("today")
    parser.add_argument("summary", nargs="?", default="")
    parser.add_argument("--extra-results", action="append", default=[])
    parser.add_argument("--ignore-file-name", help="the ignore file as the caller named it, for the summary")
    parser.add_argument("--ignore-source-label", help="where the ignore entries came from, for messages and the summary")
    parser.add_argument("--path-prefix", default="", help="the scan root's path in the repository, for annotations")
    args = parser.parse_args()

    merged = {"results": [], "errors": []}
    for path in [args.results, *args.extra_results]:
        try:
            data = load(path)
        except (OSError, ValueError) as err:
            print(f"::error title=Code scan::{escape_data(f'cannot read semgrep results: {err}')}")
            return 2
        merged["results"] += data.get("results", [])
        merged["errors"] += data.get("errors", [])

    errors = [e for e in merged["errors"] if is_fatal(e)]
    for e in errors:
        detail = e.get("message", e)
        print(f"::error title=Code scan::{escape_data(f'semgrep error: {detail}')}")
    if errors:
        return 2

    merged_file = args.results + ".merged.json"
    with open(merged_file, "w") as f:
        json.dump(merged, f)
    here = os.path.dirname(os.path.abspath(__file__))
    proc = subprocess.run(
        [sys.executable, os.path.join(here, "filter.py"), "--results", merged_file,
         "--ignore-file", args.ignore_file, "--scan-root", args.scan_root, "--today", args.today]
        + ([f"--source-label=the ignore file at the {args.ignore_source_label}"] if args.ignore_source_label else []),
        stdout=subprocess.PIPE, text=True,
    )
    if proc.returncode != 0:
        return 2
    filtered_file = args.results + ".filtered.json"
    with open(filtered_file, "w") as f:
        f.write(proc.stdout)
    command = [sys.executable, os.path.join(here, "report.py"), "--findings", filtered_file]
    if args.summary:
        command += ["--summary", args.summary]
    if args.ignore_file_name:
        command.append(f"--ignore-file-name={args.ignore_file_name}")
    command.append(f"--path-prefix={args.path_prefix}")
    if args.ignore_source_label:
        command.append(f"--ignore-source-label={args.ignore_source_label}")
    sys.stdout.flush()
    return subprocess.run(command).returncode


if __name__ == "__main__":
    sys.exit(main())
