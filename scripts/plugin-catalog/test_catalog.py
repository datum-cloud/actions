#!/usr/bin/env python3
"""Tests for catalog.py and scan_releases.py. Run through test-plugin-catalog.sh.

The agreement test needs datumctl and reads its path from DATUMCTL, which
test-plugin-catalog.sh always sets, so it never skips in CI.
"""

import copy
import io
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog  # noqa: E402
import scan_releases  # noqa: E402

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testdata", "catalog")

VALID = {
    "apiVersion": "datumctl.datum.net/v1alpha1",
    "kind": "Plugin",
    "metadata": {"name": "sample"},
    "spec": {
        "shortDescription": "A plugin",
        "version": "v1.0.0",
        "platforms": [
            {
                "selector": {"matchLabels": {"os": "linux", "arch": "amd64"}},
                "uri": "https://github.com/acme/sample/releases/download/v1.0.0/sample_Linux_x86_64.tar.gz",
                "sha256": "a" * 64,
            },
            {
                "selector": {"matchLabels": {"os": "darwin", "arch": "arm64"}},
                "uri": "https://github.com/acme/sample/releases/download/v1.0.0/sample_Darwin_arm64.tar.gz",
                "sha256": "b" * 64,
            },
        ],
    },
}


def variant(change):
    manifest = copy.deepcopy(VALID)
    change(manifest)
    return manifest


def quietly(function, *args):
    """Run function, returning its result and everything it printed."""
    out = io.StringIO()
    with redirect_stdout(out), redirect_stderr(out):
        result = function(*args)
    return result, out.getvalue()


class CatalogDir:
    """A throwaway catalog repository with the given manifests in plugins/."""

    def __init__(self, manifests):
        self.manifests = manifests

    def __enter__(self):
        self.root = tempfile.mkdtemp()
        os.mkdir(os.path.join(self.root, "plugins"))
        for name, manifest in self.manifests.items():
            with open(os.path.join(self.root, "plugins", f"{name}.yaml"), "w") as handle:
                yaml.safe_dump(manifest, handle, sort_keys=False)
        return self.root

    def __exit__(self, *exc):
        shutil.rmtree(self.root)


class IndexTest(unittest.TestCase):
    def test_check_passes_after_write_and_fails_after_a_manifest_changes(self):
        with CatalogDir({"sample": VALID}) as root:
            self.assertEqual(quietly(catalog.main, ["--catalog", root, "index"])[0], 0)
            self.assertEqual(quietly(catalog.main, ["--catalog", root, "index", "--check"])[0], 0)
            changed = variant(lambda m: m["spec"].update(version="v1.0.1"))
            with open(os.path.join(root, "plugins", "sample.yaml"), "w") as handle:
                yaml.safe_dump(changed, handle, sort_keys=False)
            status, output = quietly(catalog.main, ["--catalog", root, "index", "--check"])
            self.assertEqual(status, 1)
            self.assertIn("-    version: v1.0.0\n+    version: v1.0.1", output)

    def test_check_fails_when_index_is_missing(self):
        with CatalogDir({"sample": VALID}) as root:
            self.assertEqual(quietly(catalog.main, ["--catalog", root, "index", "--check"])[0], 1)

    def test_header_fields_appear_only_when_set(self):
        with CatalogDir({"sample": VALID}) as root:
            bare, _ = catalog.render_index(root, {})
            named, _ = catalog.render_index(root, {"name": "acme", "owner": "acme-corp"})
        self.assertEqual(list(yaml.safe_load(bare)), ["apiVersion", "kind", "items"])
        self.assertEqual(list(yaml.safe_load(named)), ["apiVersion", "kind", "name", "owner", "items"])

    def test_fixture_index_is_current(self):
        args = ["--catalog", FIXTURE, "index", "--check", "--name", "fixture",
                "--description", "Fixture catalog for the workflow tests",
                "--owner", "datum-cloud", "--homepage", "https://github.com/datum-cloud/actions"]
        self.assertEqual(quietly(catalog.main, args)[0], 0)


class ValidateTest(unittest.TestCase):
    def validate(self, manifests, *extra):
        with CatalogDir(manifests) as root:
            return quietly(catalog.main, ["--catalog", root, "validate", "--download", "none", *extra])

    def test_valid_manifest_passes(self):
        self.assertEqual(self.validate({"sample": VALID})[0], 0)

    def test_empty_catalog_fails(self):
        status, output = self.validate({})
        self.assertEqual(status, 1)
        self.assertIn("found no plugin manifests", output)

    def test_schema_errors_fail(self):
        for name, change in {
            "http download": lambda m: m["spec"]["platforms"][0].update(uri="http://example.com/a.tar.gz"),
            "no host": lambda m: m["spec"]["platforms"][0].update(uri="https://"),
            "uppercase digest": lambda m: m["spec"]["platforms"][0].update(sha256="A" * 64),
            "unknown selector field": lambda m: m["spec"]["platforms"][0]["selector"].update(matchExpressions=[]),
            "unknown label": lambda m: m["spec"]["platforms"][0]["selector"]["matchLabels"].update(libc="musl"),
            "missing version": lambda m: m["spec"].pop("version"),
        }.items():
            with self.subTest(name):
                status, output = self.validate({"sample": variant(change)})
                self.assertEqual(status, 1, output)
                self.assertIn("::error file=plugins/sample.yaml", output)


class DownloadTest(unittest.TestCase):
    def test_matching_digests_pass(self):
        digests = {p["uri"]: p["sha256"] for p in VALID["spec"]["platforms"]}
        self.assertEqual(catalog.download_errors(VALID, fetch=digests.__getitem__), [])

    def test_wrong_digest_fails(self):
        problems = catalog.download_errors(VALID, fetch=lambda uri: "c" * 64)
        self.assertEqual(len(problems), 2)
        self.assertIn("the manifest says " + "a" * 64, problems[0])

    def test_unreachable_archive_fails(self):
        def missing(uri):
            raise urllib.error.HTTPError(uri, 404, "Not Found", {}, None)

        problems = catalog.download_errors(VALID, fetch=missing)
        self.assertEqual(len(problems), 2)
        self.assertIn("HTTP 404", problems[0])

    def test_only_named_manifests_are_downloaded(self):
        fetched = []

        def record(uri):
            fetched.append(uri)
            return "a" * 64 if "Linux" in uri else "b" * 64

        other = variant(lambda m: m["metadata"].update(name="other"))
        original = catalog.fetch_sha256
        catalog.fetch_sha256 = record
        try:
            with CatalogDir({"sample": VALID, "other": other}) as root:
                status, _ = quietly(catalog.main, ["--catalog", root, "validate",
                                                   "--download", "plugins/other.yaml"])
        finally:
            catalog.fetch_sha256 = original
        self.assertEqual(status, 0)
        self.assertEqual(len(fetched), 2)


class ScanTest(unittest.TestCase):
    def test_retarget_pairs_each_uri_with_its_own_digest(self):
        text = yaml.safe_dump(VALID, sort_keys=False)
        sums = {"sample_Linux_x86_64.tar.gz": "1c" * 32, "sample_Darwin_arm64.tar.gz": "2d" * 32}
        out = yaml.safe_load(scan_releases.retarget(text, "v1.0.0", "v1.1.0", sums, lambda url: "x"))
        self.assertEqual(out["spec"]["version"], "v1.1.0")
        linux, darwin = out["spec"]["platforms"]
        self.assertEqual(linux["sha256"], "1c" * 32)
        self.assertEqual(darwin["sha256"], "2d" * 32)
        self.assertTrue(linux["uri"].endswith("/v1.1.0/sample_Linux_x86_64.tar.gz"))


class BaseBranchTest(unittest.TestCase):
    def test_base_branch_comes_from_the_workflow(self):
        original = os.environ.get("BASE_BRANCH")
        os.environ["BASE_BRANCH"] = "trunk"
        try:
            self.assertEqual(scan_releases.base_branch("acme/catalog"), "trunk")
        finally:
            if original is None:
                del os.environ["BASE_BRANCH"]
            else:
                os.environ["BASE_BRANCH"] = original

    def test_no_pull_request_call_names_main(self):
        with open(scan_releases.__file__) as handle:
            source = handle.read()
        self.assertNotIn("base=main", source)
        self.assertNotIn('"--base", "main"', source)


@unittest.skipUnless(os.environ.get("DATUMCTL"), "DATUMCTL is not set; test-plugin-catalog.sh sets it")
class AgreementTest(unittest.TestCase):
    """The schema may be stricter than datumctl, never looser.

    A manifest the schema accepts and datumctl rejects would pass catalog CI
    and then fail for everyone who installs it.
    """

    CASES = {
        "valid": lambda m: None,
        "http download": lambda m: m["spec"]["platforms"][0].update(uri="http://example.com/a.tar.gz"),
        "no host": lambda m: m["spec"]["platforms"][0].update(uri="https://"),
        "space in uri": lambda m: m["spec"]["platforms"][0].update(uri="https://exa mple.com/a"),
        "bad selector operator": lambda m: m["spec"]["platforms"][0]["selector"].update(
            matchExpressions=[{"key": "os", "operator": "Bogus", "values": ["linux"]}]),
        "invalid label key": lambda m: m["spec"]["platforms"][0]["selector"]["matchLabels"].update(
            {"bad key!": "x"}),
        "no selector": lambda m: m["spec"]["platforms"][0].pop("selector"),
        "missing digest": lambda m: m["spec"]["platforms"][0].pop("sha256"),
        "missing version": lambda m: m["spec"].pop("version"),
        "no platforms": lambda m: m["spec"].update(platforms=[]),
        "missing name": lambda m: m["metadata"].pop("name"),
    }

    def test_schema_never_accepts_what_datumctl_rejects(self):
        validator = catalog.schema_validator()
        for name, change in self.CASES.items():
            with self.subTest(name):
                manifest = variant(change)
                index = yaml.safe_dump({"apiVersion": "datumctl.datum.net/v1alpha1",
                                        "kind": "PluginList", "items": [manifest]})
                schema = catalog.schema_errors(validator, manifest)
                client = catalog.datumctl_problems(os.environ["DATUMCTL"], index)
                if not schema:
                    self.assertEqual(client, [], f"the schema accepts {name!r} but datumctl rejects it")

    def test_valid_manifest_passes_datumctl(self):
        index = yaml.safe_dump({"apiVersion": "datumctl.datum.net/v1alpha1",
                                "kind": "PluginList", "items": [VALID]})
        self.assertEqual(catalog.datumctl_problems(os.environ["DATUMCTL"], index), [])


if __name__ == "__main__":
    unittest.main()
