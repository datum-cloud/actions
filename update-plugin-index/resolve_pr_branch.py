"""Find an existing plugin update PR before choosing a new stable branch."""

import json
import os
import posixpath
import subprocess
import sys


def api(path, **params):
    command = ["gh", "api", "--method", "GET", "--paginate", "--slurp", path]
    for name, value in params.items():
        command.extend(["-f", f"{name}={value}"])
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True)
    return [item for page in json.loads(result.stdout) for item in page]


def resolve_branch(index_repo, plugin_name, plugin_file, base_branch):
    plugin_file = posixpath.normpath(plugin_file)
    stable_branch = f"update-plugin/{plugin_name}"
    pulls = api(f"repos/{index_repo}/pulls", state="open", per_page=100)
    # Only branches in the catalog itself can be updated by the catalog token.
    pulls = [
        pull
        for pull in pulls
        if pull["state"] == "open"
        and (pull["head"]["repo"] or {}).get("full_name", "").casefold()
        == index_repo.casefold()
    ]
    other_base_branches = {
        pull["head"]["ref"]
        for pull in pulls
        if pull["base"]["ref"] != base_branch
    }
    candidates = [
        pull
        for pull in pulls
        if pull["base"]["ref"] == base_branch
        and pull["head"]["ref"] not in other_base_branches
        and (
            pull["head"]["ref"] == stable_branch
            or pull["head"]["ref"].startswith(stable_branch + "-")
        )
    ]
    # Prefer the stable branch, then the oldest review thread when several
    # versioned PRs from earlier action releases are still open.
    candidates.sort(
        key=lambda pull: (pull["head"]["ref"] != stable_branch, pull["number"])
    )
    for pull in candidates:
        files = api(
            f"repos/{index_repo}/pulls/{pull['number']}/files", per_page=100
        )
        # Exact paths distinguish similarly named plugins and preserve PRs
        # that include unrelated changes, including hand-edited update PRs.
        if [entry["filename"] for entry in files] == [plugin_file]:
            return pull["head"]["ref"]

    # Even a PR targeting another base shares the same head branch. Refuse to
    # overwrite it when falling back to the stable name.
    for pull in pulls:
        if pull["head"]["ref"] == stable_branch:
            raise ValueError(
                f"Branch {stable_branch} is already used by PR #{pull['number']} "
                f"that does not exclusively update {plugin_file} against {base_branch}"
            )
    return stable_branch


def main():
    branch = resolve_branch(
        os.environ["INDEX_REPO"],
        os.environ["PLUGIN_NAME"],
        os.environ["PLUGIN_FILE"],
        os.environ["BASE_BRANCH"],
    )
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"branch={branch}\n")
    print(f"Using pull request branch: {branch}")


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, ValueError) as error:
        print(f"::error::Could not resolve plugin update PR: {error}", file=sys.stderr)
        sys.exit(1)
