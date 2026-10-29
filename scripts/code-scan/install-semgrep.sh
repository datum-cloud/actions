#!/usr/bin/env bash
# Install Semgrep into a virtualenv and add its bin directory to GITHUB_PATH.
# Every package, Semgrep's dependencies included, comes from requirements.txt
# beside this script, pinned and checked by hash, so a changed or compromised
# release of any of them fails the install instead of running in the
# scanner. requirements.txt is generated from requirements.in (see its
# header); Renovate updates both. Nothing from the scanned repository is
# installed or run. Needs Python 3.11 or later.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
venv=${CODE_SCAN_VENV:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/code-scan-venv}

python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' ||
  { echo "::error title=Code scan::Python 3.11 or later is required (found $(python3 --version 2>&1))"; exit 2; }
python3 -m venv "$venv"
"$venv/bin/python" -m pip install --quiet --disable-pip-version-check \
  --require-hashes --no-deps --only-binary :all: -r "$script_dir/requirements.txt"
echo "Installed semgrep: $("$venv/bin/semgrep" --version 2>&1 | tail -n 1)"

if [[ -n ${GITHUB_PATH:-} ]]; then
  echo "$venv/bin" >> "$GITHUB_PATH"
fi
