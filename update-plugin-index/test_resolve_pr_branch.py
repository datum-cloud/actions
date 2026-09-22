"""Regression tests for keeping plugin releases in the same catalog review."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import resolve_pr_branch


INDEX_REPO = "datum-cloud/datumctl-plugins"
PLUGIN_FILE = "plugins/dns.yaml"
STABLE_BRANCH = "update-plugin/dns"


def pull(number, branch=STABLE_BRANCH, *, base="main", repo=INDEX_REPO, state="open"):
    return {
        "number": number,
        "state": state,
        "head": {
            "ref": branch,
            "repo": {"full_name": repo} if repo is not None else None,
        },
        "base": {"ref": base},
    }


class ResolveBranchTests(unittest.TestCase):
    def resolve(self, pulls, files=None, *, plugin_file=PLUGIN_FILE, base="main"):
        files = files or {}

        def api(path, **params):
            if path == f"repos/{INDEX_REPO}/pulls":
                self.assertEqual(params.get("state"), "open")
                self.assertNotIn("base", params)
                return pulls
            if path.startswith(f"repos/{INDEX_REPO}/pulls/") and path.endswith("/files"):
                number = int(path.split("/")[-2])
                return [
                    {"filename": name}
                    for name in files.get(number, [PLUGIN_FILE])
                ]
            self.fail(f"Unexpected API request: {path}")

        with patch.object(resolve_pr_branch, "api", side_effect=api):
            return resolve_pr_branch.resolve_branch(
                INDEX_REPO, "dns", plugin_file, base
            )

    def test_first_release_uses_a_stable_branch(self):
        self.assertEqual(self.resolve([]), STABLE_BRANCH)

    def test_new_release_reuses_an_open_legacy_branch(self):
        branch = "update-plugin/dns-v0.3.0"
        self.assertEqual(self.resolve([pull(12, branch)]), branch)

    def test_stable_branch_wins_over_older_legacy_prs(self):
        self.assertEqual(
            self.resolve([pull(4, "update-plugin/dns-v0.1.0"), pull(20)]),
            STABLE_BRANCH,
        )

    def test_oldest_legacy_pr_wins_regardless_of_api_order(self):
        oldest_branch = "update-plugin/dns-v0.1.0"
        self.assertEqual(
            self.resolve(
                [pull(30, "update-plugin/dns-v0.3.0"), pull(10, oldest_branch)]
            ),
            oldest_branch,
        )

    def test_similarly_named_plugin_does_not_match(self):
        self.assertEqual(
            self.resolve(
                [pull(10, "update-plugin/dns-extra-v0.1.0")],
                {10: ["plugins/dns-extra.yaml"]},
            ),
            STABLE_BRANCH,
        )

    def test_unrelated_branch_changing_the_manifest_is_not_reused(self):
        self.assertEqual(self.resolve([pull(10, "fix-dns-platforms")]), STABLE_BRANCH)

    def test_legacy_pr_with_other_changes_is_not_overwritten(self):
        self.assertEqual(
            self.resolve(
                [pull(10, "update-plugin/dns-v0.1.0")],
                {10: [PLUGIN_FILE, "README.md"]},
            ),
            STABLE_BRANCH,
        )

    def test_custom_manifest_path_identifies_the_correct_pr(self):
        custom_file = "catalog/network/dns.yaml"
        branch = "update-plugin/dns-v0.2.0"
        self.assertEqual(
            self.resolve(
                [pull(10, "update-plugin/dns-v0.1.0"), pull(20, branch)],
                {10: [PLUGIN_FILE], 20: [custom_file]},
                plugin_file=custom_file,
            ),
            branch,
        )

    def test_relative_manifest_path_reuses_the_existing_pr(self):
        branch = "update-plugin/dns-v0.1.0"
        self.assertEqual(
            self.resolve([pull(10, branch)], plugin_file=f"./{PLUGIN_FILE}"),
            branch,
        )

    def test_fork_deleted_head_and_wrong_base_legacy_prs_are_ignored(self):
        cases = [
            {"repo": "someone/datumctl-plugins"},
            {"repo": None},
            {"base": "release"},
            {"state": "closed"},
        ]
        for kwargs in cases:
            with self.subTest(**kwargs):
                self.assertEqual(
                    self.resolve([pull(10, "update-plugin/dns-v0.1.0", **kwargs)]),
                    STABLE_BRANCH,
                )

    def test_head_repository_comparison_is_case_insensitive(self):
        branch = "update-plugin/dns-v0.1.0"
        self.assertEqual(
            self.resolve([pull(10, branch, repo=INDEX_REPO.upper())]), branch
        )

    def test_requested_base_branch_is_used(self):
        branch = "update-plugin/dns-v0.2.0"
        self.assertEqual(
            self.resolve(
                [pull(10, "update-plugin/dns-v0.1.0"), pull(20, branch, base="release")],
                base="release",
            ),
            branch,
        )

    def test_closed_stable_pr_does_not_reserve_the_branch(self):
        self.assertEqual(self.resolve([pull(10, state="closed")]), STABLE_BRANCH)

    def test_fork_stable_pr_does_not_reserve_the_catalog_branch(self):
        self.assertEqual(
            self.resolve([pull(10, repo="someone/datumctl-plugins")]), STABLE_BRANCH
        )

    def test_stable_branch_for_another_base_is_not_overwritten(self):
        with self.assertRaises(ValueError):
            self.resolve([pull(10, base="release")])

    def test_stable_branch_shared_across_bases_is_not_overwritten(self):
        with self.assertRaises(ValueError):
            self.resolve([pull(10), pull(20, base="release")])

    def test_legacy_branch_shared_across_bases_is_not_overwritten(self):
        branch = "update-plugin/dns-v0.1.0"
        self.assertEqual(
            self.resolve([pull(10, branch), pull(20, branch, base="release")]),
            STABLE_BRANCH,
        )

    def test_shared_branch_does_not_prevent_reusing_a_dedicated_pr(self):
        dedicated_branch = "update-plugin/dns-v0.2.0"
        for shared_branch in (STABLE_BRANCH, "update-plugin/dns-v0.1.0"):
            with self.subTest(shared_branch=shared_branch):
                self.assertEqual(
                    self.resolve(
                        [
                            pull(10, shared_branch),
                            pull(20, shared_branch, base="release"),
                            pull(30, dedicated_branch),
                        ]
                    ),
                    dedicated_branch,
                )

    def test_stable_branch_with_unrelated_changes_is_not_overwritten(self):
        for filenames in (["plugins/compute.yaml"], [PLUGIN_FILE, "README.md"], []):
            with self.subTest(filenames=filenames):
                with self.assertRaises(ValueError):
                    self.resolve([pull(10)], {10: filenames})

    def test_existing_legacy_pr_can_be_used_when_stable_branch_is_reserved(self):
        branch = "update-plugin/dns-v0.1.0"
        self.assertEqual(
            self.resolve([pull(10, base="release"), pull(20, branch)]), branch
        )

    def test_api_failure_does_not_fall_back_to_creating_a_pr(self):
        failure = subprocess.CalledProcessError(1, ["gh", "api"])
        with patch.object(resolve_pr_branch, "api", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError):
                resolve_pr_branch.resolve_branch(INDEX_REPO, "dns", PLUGIN_FILE, "main")


class GitHubApiTests(unittest.TestCase):
    def test_paginated_results_are_combined(self):
        pages = [[{"number": 1}], [{"number": 2}], []]
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps(pages))
        with patch.object(resolve_pr_branch.subprocess, "run", return_value=result) as run:
            self.assertEqual(
                resolve_pr_branch.api(f"repos/{INDEX_REPO}/pulls", state="open"),
                [{"number": 1}, {"number": 2}],
            )
        command = run.call_args.args[0]
        self.assertIn("--paginate", command)
        self.assertIn("--slurp", command)
        self.assertIn("GET", command)
        self.assertTrue(run.call_args.kwargs.get("check"))

    def test_matching_pr_on_later_page_is_reused(self):
        branch = "update-plugin/dns-v0.1.0"
        responses = [
            subprocess.CompletedProcess(
                [], 0, stdout=json.dumps([[pull(1, "unrelated")], [pull(20, branch)]])
            ),
            subprocess.CompletedProcess(
                [], 0, stdout=json.dumps([[{"filename": PLUGIN_FILE}]])
            ),
        ]
        with patch.object(resolve_pr_branch.subprocess, "run", side_effect=responses):
            self.assertEqual(
                resolve_pr_branch.resolve_branch(INDEX_REPO, "dns", PLUGIN_FILE, "main"),
                branch,
            )

    def test_cli_failure_is_propagated(self):
        failure = subprocess.CalledProcessError(1, ["gh", "api"])
        with patch.object(resolve_pr_branch.subprocess, "run", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError):
                resolve_pr_branch.api(f"repos/{INDEX_REPO}/pulls", state="open")


class ActionOutputTests(unittest.TestCase):
    def test_selected_branch_is_written_to_github_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            output.write_text("existing=value\n")
            environment = {
                "INDEX_REPO": INDEX_REPO,
                "PLUGIN_NAME": "dns",
                "PLUGIN_FILE": PLUGIN_FILE,
                "BASE_BRANCH": "main",
                "GITHUB_OUTPUT": str(output),
            }
            with patch.dict(os.environ, environment), patch.object(
                resolve_pr_branch, "resolve_branch", return_value=STABLE_BRANCH
            ) as resolve:
                resolve_pr_branch.main()
            resolve.assert_called_once_with(INDEX_REPO, "dns", PLUGIN_FILE, "main")
            self.assertEqual(output.read_text(), f"existing=value\nbranch={STABLE_BRANCH}\n")

    def test_failed_lookup_does_not_publish_a_branch_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            output.write_text("existing=value\n")
            environment = {
                "INDEX_REPO": INDEX_REPO,
                "PLUGIN_NAME": "dns",
                "PLUGIN_FILE": PLUGIN_FILE,
                "BASE_BRANCH": "main",
                "GITHUB_OUTPUT": str(output),
            }
            with patch.dict(os.environ, environment), patch.object(
                resolve_pr_branch, "resolve_branch", side_effect=ValueError("unsafe branch")
            ):
                with self.assertRaises((ValueError, SystemExit)):
                    resolve_pr_branch.main()
            self.assertEqual(output.read_text(), "existing=value\n")


if __name__ == "__main__":
    unittest.main()
