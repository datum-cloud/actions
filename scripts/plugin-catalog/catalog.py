#!/usr/bin/env python3
"""Validate a datumctl plugin catalog and build its index.

A catalog repository keeps one manifest per plugin in plugins/*.yaml and
publishes index.yaml, the file datumctl reads, built from those manifests.

  catalog.py validate [--download all|none|FILE...] [--datumctl PATH]
  catalog.py index [--check] [--keep-header] [--if-exists] [--name N --description D --owner O --homepage H]

validate checks every manifest against the schema, then downloads the archives
of the manifests named by --download (all of them by default) and compares
each sha256. With --datumctl it also builds the index in memory and runs
`datumctl plugin index validate` on it, so the catalog is held to the client's
own rules as well as the schema's.

index writes index.yaml, or with --check fails when the committed one differs
from what the manifests produce. With --keep-header, header fields not given on
the command line are kept from the existing index.yaml, so a tool that edits one
manifest can rebuild the index without knowing the catalog's header. With
--if-exists, a catalog that has no index.yaml is left alone.

Both read the catalog from --catalog (default: the current directory).
"""

import argparse
import difflib
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

import yaml
from jsonschema import Draft7Validator, FormatChecker

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(SCRIPT_DIR, "schema", "plugin-v1alpha1.json")
HEADER_FIELDS = ("name", "description", "owner", "homepage")


def annotate(level, message, path=None):
    """Print a workflow annotation. Newlines and % are escaped as Actions requires."""
    text = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    where = f" file={path}," if path else " "
    print(f"::{level}{where}title=Plugin catalog::{text}")


def manifest_paths(catalog):
    plugins = os.path.join(catalog, "plugins")
    if not os.path.isdir(plugins):
        return []
    return sorted(
        os.path.join("plugins", name)
        for name in os.listdir(plugins)
        if name.endswith(".yaml")
    )


def load_manifest(catalog, path):
    with open(os.path.join(catalog, path)) as handle:
        return yaml.safe_load(handle)


def schema_validator():
    with open(SCHEMA_PATH) as handle:
        return Draft7Validator(json.load(handle), format_checker=FormatChecker())


def schema_errors(validator, manifest):
    """Human-readable schema problems for one manifest, empty when it is valid."""
    found = sorted(validator.iter_errors(manifest), key=lambda e: list(e.path))
    return [f"{'/'.join(str(p) for p in e.path) or '(root)'}: {e.message}" for e in found]


def fetch_sha256(uri):
    """sha256 of the bytes at uri. Raises urllib errors when it can't be read."""
    digest = hashlib.sha256()
    with urllib.request.urlopen(uri, timeout=120) as response:
        for chunk in iter(lambda: response.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_errors(manifest, fetch=None):
    """Problems with a manifest's archives: unreachable URLs and wrong digests."""
    fetch = fetch or fetch_sha256
    problems = []
    for platform in manifest["spec"]["platforms"]:
        uri, expected = platform["uri"], platform["sha256"]
        try:
            actual = fetch(uri)
        except urllib.error.HTTPError as exc:
            problems.append(f"{uri}: HTTP {exc.code}")
            continue
        except (urllib.error.URLError, OSError) as exc:
            problems.append(f"{uri}: unreachable: {getattr(exc, 'reason', exc)}")
            continue
        if actual != expected:
            problems.append(f"{uri}: sha256 is {actual}, the manifest says {expected}")
    return problems


def render_index(catalog, header):
    """index.yaml text built from plugins/*.yaml, and how many plugins it lists."""
    index = {"apiVersion": "datumctl.datum.net/v1alpha1", "kind": "PluginList"}
    index.update({key: header[key] for key in HEADER_FIELDS if header.get(key)})
    index["items"] = [load_manifest(catalog, path) for path in manifest_paths(catalog)]
    text = yaml.dump(index, default_flow_style=False, allow_unicode=True, sort_keys=False)
    return text, len(index["items"])


def datumctl_problems(datumctl, index_text):
    """What `datumctl plugin index validate` reports for an index, empty when it passes."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as handle:
        handle.write(index_text)
        path = handle.name
    try:
        result = subprocess.run(
            [datumctl, "plugin", "index", "validate", path],
            capture_output=True, text=True, check=False,
        )
    finally:
        os.unlink(path)
    if result.returncode == 0:
        return []
    output = (result.stdout + result.stderr).strip()
    return [output or f"datumctl exited {result.returncode} with no output"]


def validate(args):
    paths = manifest_paths(args.catalog)
    if not paths:
        annotate("error", "found no plugin manifests under plugins/, so nothing was validated")
        return 1

    validator = schema_validator()
    failed = False
    manifests = {}
    for path in paths:
        try:
            manifest = load_manifest(args.catalog, path)
        except yaml.YAMLError as exc:
            annotate("error", f"not valid YAML: {exc}", path)
            failed = True
            continue
        problems = schema_errors(validator, manifest)
        for problem in problems:
            annotate("error", f"schema: {problem}", path)
        if problems:
            failed = True
        else:
            manifests[path] = manifest
        print(f"{path}: schema {'FAIL' if problems else 'ok'}")

    if args.datumctl:
        text, _ = render_index(args.catalog, {})
        problems = datumctl_problems(args.datumctl, text)
        for problem in problems:
            annotate("error", f"datumctl plugin index validate rejects the index:\n{problem}")
        failed = failed or bool(problems)
        print(f"datumctl plugin index validate: {'FAIL' if problems else 'ok'}")

    if args.download == ["none"]:
        targets = []
    elif args.download in ([], ["all"]):
        targets = paths
    else:
        targets = [p for p in args.download if p in paths]
        for missing in sorted(set(args.download) - set(paths)):
            print(f"{missing}: not a plugin manifest in this catalog, not downloaded")
    for path in targets:
        if path not in manifests:
            continue
        problems = download_errors(manifests[path])
        for problem in problems:
            annotate("error", f"download: {problem}", path)
        failed = failed or bool(problems)
        count = len(manifests[path]["spec"]["platforms"])
        print(f"{path}: {count} archive(s) {'FAIL' if problems else 'ok'}")
    if not targets:
        print("No manifests selected for download, so no archive was checked.")

    print(f"\n{'FAILED' if failed else 'Passed'}: {len(paths)} manifest(s), {len(targets)} downloaded.")
    return 1 if failed else 0


def existing_header(catalog):
    """Header fields of the catalog's current index.yaml, empty when it has none."""
    path = os.path.join(catalog, "index.yaml")
    if not os.path.exists(path):
        return {}
    with open(path) as handle:
        current = yaml.safe_load(handle)
    if not isinstance(current, dict):
        return {}
    return {key: current[key] for key in HEADER_FIELDS if current.get(key)}


def index(args):
    target = os.path.join(args.catalog, "index.yaml")
    if args.if_exists and not os.path.exists(target):
        print("No index.yaml in this catalog, so none was written.")
        return 0
    header = {key: getattr(args, key) for key in HEADER_FIELDS}
    if args.keep_header:
        kept = existing_header(args.catalog)
        header = {key: header[key] or kept.get(key, "") for key in HEADER_FIELDS}
    expected, count = render_index(args.catalog, header)
    if not args.check:
        with open(target, "w") as handle:
            handle.write(expected)
        print(f"Wrote index.yaml with {count} plugin(s).")
        return 0

    current = ""
    if os.path.exists(target):
        with open(target) as handle:
            current = handle.read()
    if current == expected:
        print(f"index.yaml matches plugins/ ({count} plugin(s)).")
        return 0
    diff = "\n".join(difflib.unified_diff(
        current.splitlines(), expected.splitlines(),
        fromfile="index.yaml (committed)", tofile="index.yaml (from plugins/)", lineterm="",
    ))
    annotate("error", "index.yaml does not match plugins/, so datumctl users see stale entries", "index.yaml")
    print(diff, file=sys.stderr)
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--catalog", default=".", help="catalog repository root (default: .)")
    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("validate", help="check manifests, archives and the index")
    check.add_argument("--download", nargs="*", default=["all"],
                       help="'all' (default), 'none', or the manifest paths whose archives to check")
    check.add_argument("--datumctl", help="datumctl binary to run `plugin index validate` with")
    check.set_defaults(run=validate)

    build = commands.add_parser("index", help="write index.yaml, or check it with --check")
    build.add_argument("--check", action="store_true", help="fail when index.yaml is out of date")
    build.add_argument("--keep-header", action="store_true",
                       help="keep header fields not given here from the existing index.yaml")
    build.add_argument("--if-exists", action="store_true",
                       help="do nothing when the catalog has no index.yaml")
    for key in HEADER_FIELDS:
        build.add_argument(f"--{key}", default="", help=f"catalog {key} shown by datumctl (optional)")
    build.set_defaults(run=index)

    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
