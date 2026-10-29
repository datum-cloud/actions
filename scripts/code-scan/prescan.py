"""Check what Semgrep's rules can't see, and write the results as Semgrep JSON.

    python3 prescan.py --scan-root DIR --semgrep-results FILE --output FILE
        [--ignore-file PATH] [--explicit-targets FILE]

--semgrep-results is the JSON of the main Semgrep pass; its paths.scanned
field lists the files Semgrep read, relative to --scan-root, so this pass
covers the same files and honours the same excludes. An empty list while the
scan root holds files (other than .git and --ignore-file) is an error: a scan
that read nothing must not pass.
--output gets {"results": [...], "errors": []} in the shape of Semgrep's JSON
results, so list-findings.py and filter.py treat these findings like any
other: they fail the scan, and an ignore entry can suppress one per path.

Rules:
  non-utf8-text  A text file that is not valid UTF-8. Semgrep's regex engine
                 runs in UTF mode and silently matches nothing in such a file,
                 so a single Latin-1 byte would switch off every regex rule
                 for it. Any other file with a NUL byte in its first 8000
                 bytes is binary (git's test) and is not flagged.
  nul-in-text-file
                 A NUL byte in a code or text file (see is_text_file) that is
                 otherwise valid UTF-8. A NUL never makes such a file binary:
                 Node runs a .mjs file with a NUL in a comment.
  unscanned-content
                 Content the checkout doesn't hold, so no rule reads it: a
                 .gitattributes line that routes files through Git LFS, a
                 .gitmodules file, and (when the scan root is in a Git work
                 tree) any gitlink, which is a submodule commit.

--explicit-targets gets, NUL-separated, the files Node can run that Semgrep
doesn't treat as JavaScript or TypeScript by extension, for scan.sh to scan
again with --scan-unknown-extensions: .mts and .cts files, files whose first
line is a node, bun, or deno shebang, and the targets of symlinks named like
JavaScript files (Semgrep skips symlinks) that resolve to a selected target
inside the scan root.

Exits 0, or 2 when a listed target is missing or unreadable: a target this
pass can't read is a hole, not a pass.
"""
import argparse
import fnmatch
import json
import subprocess
import os
import re
import sys

from report import escape_data

BINARY_PROBE = 8000
# Files that are code or text by name: they never get the binary exemption.
TEXT_EXTENSIONS = {
    ".js", ".mjs", ".cjs", ".jsx", ".ts", ".mts", ".cts", ".tsx", ".json", ".jsonc", ".json5",
    ".sh", ".bash", ".zsh", ".ps1", ".py", ".rb", ".pl", ".php", ".go", ".rs",
    ".yml", ".yaml", ".toml", ".ini", ".cfg", ".conf", ".env", ".xml", ".html", ".htm",
    ".css", ".scss", ".sass", ".less", ".svg", ".vue", ".svelte", ".astro",
    ".md", ".mdx", ".markdown", ".txt", ".csv", ".tsv", ".lock", ".graphql", ".gql", ".sql",
}
TEXT_NAME_PREFIXES = ("Dockerfile", "Makefile", "Taskfile", ".eslintrc", ".prettierrc", ".npmrc", ".env")
# Paths that are text by location, whatever their name: Husky v9 hooks have
# no shebang, and sh runs them anyway. The same globs as download-pipe-to-
# shell's path includes, in Semgrep's gitignore style; a test keeps the two
# lists equal.
TEXT_PATH_GLOBS = (
    "*.sh", "*.bash", "*.zsh", "*.js", "*.mjs", "*.cjs", "*.jsx", "*.ts", "*.mts", "*.cts", "*.tsx",
    "package.json", "/.github/**", "/.husky/**", "lefthook.yml", "lefthook.yaml",
    "Dockerfile*", "Makefile", "Taskfile*",
)
TEXT_NAMES = {"package.json", "lefthook.yml", "lefthook.yaml", ".gitattributes", ".gitmodules", ".gitignore"}
JS_EXTENSIONS = {".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx"}
UNRECOGNISED_JS_EXTENSIONS = {".mts", ".cts"}
NODE_SHEBANG = re.compile(rb"^#!.*\b(?:node|nodejs|bun|deno|tsx|ts-node)\b")

NON_UTF8_MESSAGE = (
    "The file is not valid UTF-8. Semgrep's regex rules match nothing in it, "
    "so hidden code would go unseen. Re-encode it as UTF-8, or suppress it if "
    "it is not text."
)
LFS_MESSAGE = (
    "Git LFS keeps the files this line matches outside the repository, so the "
    "scan reads only their pointer files. Review that content another way, "
    "then suppress this finding."
)
SUBMODULE_MESSAGE = (
    "A submodule's files aren't in this checkout, so the scan doesn't read "
    "them. Scan the submodule's own repository, then suppress this finding."
)


def result(rule, path, line, col, message):
    position = {"line": line, "col": col, "offset": 0}
    return {"check_id": rule, "path": path, "start": position, "end": position, "extra": {"message": message}}


NUL_MESSAGE = (
    "A code or text file holds a NUL byte. It still runs, but tools treat it "
    "as binary and reviewers can't see the byte. Remove it."
)


def glob_match(path, glob):
    """Semgrep's gitignore-style match for the globs in TEXT_PATH_GLOBS: a
    leading / anchors at the root, /** matches everything below, and a glob
    without a slash matches the file name at any depth."""
    anchored, glob = glob.startswith("/"), glob.lstrip("/")
    if glob.endswith("/**"):
        prefix = glob[:-3] + "/"
        return path.startswith(prefix) if anchored else ("/" + path).find("/" + prefix) >= 0
    if "/" not in glob:
        return fnmatch.fnmatchcase(os.path.basename(path), glob)
    return fnmatch.fnmatchcase(path, glob)


def is_text_file(path, data):
    """Code or text by name, location, or shebang, so never exempt as binary."""
    name = os.path.basename(path)
    return (
        any(glob_match(path, glob) for glob in TEXT_PATH_GLOBS)
        or
        os.path.splitext(name)[1].lower() in TEXT_EXTENSIONS
        or name in TEXT_NAMES
        or name.startswith(TEXT_NAME_PREFIXES)
        or data.startswith(b"#!")
    )


def position(data, offset):
    line_start = data.rfind(b"\n", 0, offset) + 1
    return data.count(b"\n", 0, offset) + 1, offset - line_start + 1


def non_utf8(path, data, text=None):
    """A finding at the first invalid byte or, in a code or text file, the
    first NUL byte. None for clean UTF-8, and for binary data: a file with a
    NUL in its first 8000 bytes whose name isn't code or text."""
    if text is None:
        text = is_text_file(path, data)
    if not text and b"\0" in data[:BINARY_PROBE]:
        return None
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as err:
        return result("non-utf8-text", path, *position(data, err.start), NON_UTF8_MESSAGE)
    if text and b"\0" in data:
        return result("nul-in-text-file", path, *position(data, data.index(b"\0")), NUL_MESSAGE)
    return None


def has_files(root, ignore_file):
    """Whether root holds a regular file other than .git/** and ignore_file."""
    for top, dirs, files in os.walk(root):
        if top == root and ".git" in dirs:
            dirs.remove(".git")
        for name in files:
            full = os.path.join(top, name)
            if os.path.isfile(full) and not os.path.islink(full) and os.path.relpath(full, root) != ignore_file:
                return True
    return False


def read_targets(root, results_file, ignore_file):
    """The paths Semgrep scanned, relative to root. Every entry must be a
    regular file under root."""
    with open(results_file) as f:
        try:
            scanned = json.load(f)["paths"]["scanned"]
        except (ValueError, KeyError, TypeError) as err:
            raise OSError(f"{results_file} has no paths.scanned list: {err}")
    if not isinstance(scanned, list) or not all(isinstance(p, str) for p in scanned):
        raise OSError(f"{results_file}: paths.scanned is not a list of paths")
    if not scanned and has_files(root, ignore_file):
        raise OSError("Semgrep scanned no files, but the scan root holds files; check exclude-paths and path")
    targets = []
    for name in scanned:
        if name.startswith("./"):
            name = name[2:]
        full = os.path.join(root, name)
        if not os.path.isfile(full) or os.path.islink(full):
            raise OSError(f"Semgrep listed target {name!r}, which is not a regular file under the scan root")
        targets.append(name)
    return targets


def lfs_line(data):
    """The number of the first non-comment line that sets filter=lfs."""
    for number, line in enumerate(data.split(b"\n"), start=1):
        if not line.lstrip().startswith(b"#") and b"filter=lfs" in line:
            return number
    return None


def gitlinks(root):
    """Paths of gitlinks (mode 160000) under root, when root is in a work tree."""
    inside = subprocess.run(["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if inside.returncode != 0 or inside.stdout.strip() != b"true":
        return []
    listing = subprocess.run(["git", "-C", root, "ls-files", "--stage", "-z"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if listing.returncode != 0:
        raise OSError(f"git ls-files failed: {listing.stderr.decode('utf-8', 'replace').strip()}")
    links = []
    for entry in listing.stdout.split(b"\0"):
        meta, _, path = entry.partition(b"\t")
        if meta.startswith(b"160000 "):
            links.append(os.fsdecode(path))
    return links


def unscanned_content(name, data):
    if os.path.basename(name) == ".gitattributes":
        line = lfs_line(data)
        if line:
            return result("unscanned-content", name, line, 1, LFS_MESSAGE)
    if name == ".gitmodules":
        return result("unscanned-content", name, 1, 1, SUBMODULE_MESSAGE)
    return None


def needs_explicit_scan(name, data):
    ext = os.path.splitext(name)[1].lower()
    if ext in UNRECOGNISED_JS_EXTENSIONS:
        return True
    if ext in JS_EXTENSIONS:
        return False
    return bool(NODE_SHEBANG.match(data.split(b"\n", 1)[0]))


def symlink_targets(root, selected):
    """{link: target} for symlinks with a JavaScript name that point to a
    selected target, both relative to root."""
    found = {}
    for top, dirs, files in os.walk(root):
        if top == root and ".git" in dirs:
            dirs.remove(".git")
        for entry in dirs + files:
            link = os.path.join(top, entry)
            if not os.path.islink(link):
                continue
            if os.path.splitext(entry)[1].lower() not in JS_EXTENSIONS | UNRECOGNISED_JS_EXTENSIONS:
                continue
            real = os.path.realpath(link)
            if os.path.commonpath([root, real]) != root or not os.path.isfile(real):
                continue
            rel = os.path.relpath(real, root)
            if rel in selected:
                found[os.path.relpath(link, root)] = rel
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scan-root", required=True)
    parser.add_argument("--semgrep-results", required=True)
    parser.add_argument("--ignore-file", default="")
    parser.add_argument("--output", required=True)
    parser.add_argument("--explicit-targets")
    args = parser.parse_args()
    root = os.path.realpath(args.scan_root)
    results = []
    explicit = set()
    try:
        targets = read_targets(root, args.semgrep_results, os.path.normpath(args.ignore_file) if args.ignore_file else "")
        links = symlink_targets(root, set(targets))
        linked = {}
        for link, target in links.items():
            linked.setdefault(target, []).append(link)
        explicit.update(linked)
        for name in targets:
            with open(os.path.join(root, name), "rb") as f:
                data = f.read()
            if needs_explicit_scan(name, data):
                explicit.add(name)
            # Node runs an explicit target as code whatever its name, so it
            # never counts as binary. A finding in a symlink target is also
            # reported on each link, the path Node loads.
            finding = non_utf8(name, data, text=True if name in explicit else None)
            if finding:
                results.append(finding)
                for link in sorted(linked.get(name, [])):
                    results.append({**finding, "path": link})
            results += [f for f in (unscanned_content(name, data),) if f]
        results += [result("unscanned-content", path, 1, 1, SUBMODULE_MESSAGE) for path in gitlinks(root)]
        if args.explicit_targets:
            with open(args.explicit_targets, "wb") as f:
                f.write(b"".join(os.fsencode(name) + b"\0" for name in sorted(explicit)))
        with open(args.output, "w") as f:
            json.dump({"results": results, "errors": []}, f)
    except OSError as err:
        print(f"::error title=Code scan::{escape_data(f'pre-scan failed: {err}')}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
