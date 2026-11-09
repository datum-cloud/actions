#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

shellcheck scripts/*/*.sh update-plugin-index/*.sh
python3 -m py_compile scripts/code-scan/*.py scripts/vuln-scan/toml-to-json.py scripts/plugin-catalog/*.py
bash scripts/drop-distrusted-roots/test-filter.sh
bash update-plugin-index/test-resolve-pr-branch.sh
bash scripts/plugin-catalog/test-plugin-catalog.sh
