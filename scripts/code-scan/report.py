"""Report filtered findings as PR annotations and a job summary.

    python3 report.py --findings FILE [--summary FILE]

FILE is filter.py's output, {"kept": [...], "suppressed": [...]}. Prints one
::error annotation per kept finding, which GitHub draws on the Files-changed
line, and appends a Markdown summary to --summary (the caller passes
$GITHUB_STEP_SUMMARY). Exits 1 when any finding was kept, 0 when none was, and
2 when FILE cannot be read.

Finding text (the matched source line, the path, the message, an ignore
reason) comes from the pull request, so everything printed is escaped:
GitHub parses every log line that starts with "::" as a workflow command, and
an unescaped newline in the text would start a forged one (::add-mask::,
::stop-commands::, ::error::). The only place finding text appears in the log
is inside an annotation, escaped.
"""
import argparse
import json
import re
import sys

CODE_LIMIT = 200
ELLIPSIS = "…"
DASH = "—"
DEFAULT_IGNORE_FILE = ".github/code-scan-ignore.toml"


def ignore_help(ignore_file):
    return (
        f"To suppress a finding, add an entry to {code_span(ignore_file)} (a rule "
        "id, one exact path, a reason, and an `ignoreUntil` date within 12 "
        "months). On a pull request the scan reads that file from the base "
        "commit, so a new entry takes effect only after it merges to the base "
        "branch. Changes to that file need code owner review in repositories "
        "that guard it."
    )


def escape_data(value):
    """Escape the message part of a workflow command."""
    return str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(value):
    """Escape a property value (file, title) of a workflow command."""
    return escape_data(value).replace(":", "%3A").replace(",", "%2C")


def one_line(value):
    """Collapse CR, LF and other control characters to spaces."""
    return re.sub(r"[\x00-\x1f\x7f\u2028\u2029]", " ", str(value))


def truncate(code):
    """Cut code to CODE_LIMIT characters, with an ellipsis when it was longer."""
    return code if len(code) <= CODE_LIMIT else code[:CODE_LIMIT] + ELLIPSIS


def annotation(finding, path_prefix=""):
    """An ::error command. path_prefix turns the scan-root-relative path into
    the repository-relative one GitHub needs to draw the annotation."""
    title = f"Code scan ({finding['rule']})"
    props = f"file={escape_property(path_prefix + finding['path'])},line={int(finding['line'])},title={escape_property(title)}"
    text = finding["message"]
    if finding.get("code"):
        text += f" {DASH} {truncate(finding['code'])}"
    return f"::error {props}::{escape_data(text)}"


def cell(value):
    """Text for a table cell: no pipe, backtick, bracket, tag or line break."""
    text = one_line(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    for char in "|`[]":
        text = text.replace(char, "\\" + char)
    return text


def code_span(value):
    """A code span that a backtick or pipe in value cannot close or split."""
    text = one_line(value).replace("|", "\\|")
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * (longest + 1)
    return f"{fence} {text} {fence}"


def summary(kept, suppressed, ignore_file=DEFAULT_IGNORE_FILE, source_label=None):
    lines = ["## Code scan", ""]
    if source_label:
        lines += [f"Ignore entries read from the {cell(source_label)}.", ""]
    if kept:
        lines += ["| Rule | Location | Message | Code |", "| --- | --- | --- | --- |"]
        lines += [
            f"| {cell(f['rule'])} | {code_span(f['path'] + ':' + str(f['line']))} | {cell(f['message'])} | {code_span(truncate(f.get('code', '')))} |"
            for f in kept
        ]
    else:
        lines.append("No findings.")
    if suppressed:
        lines += ["", "### Suppressed", "", "| Rule | Path | Reason | Until |", "| --- | --- | --- | --- |"]
        lines += [
            f"| {cell(s['rule'])} | {code_span(s['path'])} | {cell(s['reason'])} | {cell(s['ignoreUntil'])} |"
            for s in suppressed
        ]
    lines += ["", ignore_help(ignore_file), ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--findings", required=True)
    parser.add_argument("--summary")
    parser.add_argument("--ignore-file-name", default=DEFAULT_IGNORE_FILE)
    parser.add_argument("--ignore-source-label", help="where the ignore entries came from, such as 'base commit abc1234'")
    parser.add_argument("--path-prefix", default="")
    args = parser.parse_args()
    try:
        with open(args.findings) as f:
            data = json.load(f)
        kept, suppressed = data["kept"], data["suppressed"]
    except (OSError, ValueError, KeyError) as err:
        print(f"::error title=Code scan::{escape_data('cannot read findings: ' + str(err))}")
        return 2

    for s in suppressed:
        print(one_line(f"suppressed: {s['rule']} {s['path']}:{s['line']} {DASH} {s['reason']} (until {s['ignoreUntil']})"))
    for finding in kept:
        print(annotation(finding, args.path_prefix))
    if args.summary:
        try:
            with open(args.summary, "a") as f:
                f.write(summary(kept, suppressed, args.ignore_file_name, args.ignore_source_label) + "\n")
        except OSError as err:
            print(f"::warning title=Code scan::{escape_data('cannot write the job summary: ' + str(err))}")
    return 1 if kept else 0


if __name__ == "__main__":
    sys.exit(main())
