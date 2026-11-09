#!/usr/bin/env bash
# Run the plugin catalog tests with the pinned libraries and datumctl.
# PLUGIN_CATALOG_PYTHON and DATUMCTL work as in install-deps.sh and
# install-datumctl.sh, for local runs.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python=$(bash "$script_dir/install-deps.sh")
DATUMCTL=$(bash "$script_dir/install-datumctl.sh")
export DATUMCTL
"$python" -m unittest discover -s "$script_dir" -p 'test_*.py' -v
