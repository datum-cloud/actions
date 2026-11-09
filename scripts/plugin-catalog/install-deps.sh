#!/usr/bin/env bash
# Install the catalog scripts' Python libraries into a virtualenv and print
# its python path. Every package comes from requirements.txt beside this
# script, pinned and checked by hash. requirements.txt is generated from
# requirements.in (see its header); Renovate updates both. PLUGIN_CATALOG_PYTHON
# names the interpreter to build the virtualenv from (default python3).
#
#   PYTHON=$(bash install-deps.sh)
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
venv=${PLUGIN_CATALOG_VENV:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/plugin-catalog-venv}
python=${PLUGIN_CATALOG_PYTHON:-python3}

"$python" -c 'import sys; sys.exit(sys.version_info < (3, 11))' ||
  { echo "::error title=Plugin catalog::Python 3.11 or later is required (found $("$python" --version 2>&1))" >&2; exit 2; }
if [[ ! -x $venv/bin/python ]]; then
  "$python" -m venv "$venv" >&2
  "$venv/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --no-deps --only-binary :all: -r "$script_dir/requirements.txt" >&2
fi
echo "$venv/bin/python"
