#!/usr/bin/env bash
set -euo pipefail

# renovate: datasource=git-refs depName=https://github.com/avito-tech/go-mutesting branch=master
GO_MUTESTING_VERSION=9ce5f731e32140feacf391dc683ff8bd32c3aa41

BIN_DIR=${BIN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/guard-tamper-bin}
mkdir -p "$BIN_DIR"
GOBIN=$BIN_DIR GOTOOLCHAIN=auto GOFLAGS='' go install "github.com/avito-tech/go-mutesting/cmd/go-mutesting@$GO_MUTESTING_VERSION"
"$BIN_DIR/go-mutesting" --list-mutators >/dev/null
if [[ -n ${GITHUB_PATH:-} ]]; then
  echo "$BIN_DIR" >> "$GITHUB_PATH"
fi
echo "go-mutesting $GO_MUTESTING_VERSION installed in $BIN_DIR"
