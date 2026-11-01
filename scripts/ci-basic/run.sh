#!/usr/bin/env bash
set -euo pipefail

stage=${1:?usage: run.sh node|go|python|docker|extra|check-skip}
dir=${CI_PATH:-.}
known=(typecheck lint build test docker)

skips=()
skip_raw=${SKIP_STEPS:-}
read -r -a skips <<<"${skip_raw//,/ }"

skipped() {
  local s
  for s in "${skips[@]}"; do [[ $s == "$1" ]] && return 0; done
  return 1
}

step() {
  if skipped "$1"; then
    echo "::notice title=ci-basic::skipping $1 (skip input)"
    return 0
  fi
  shift
  echo "::group::$*"
  "$@"
  echo "::endgroup::"
}

cd "$dir"

case $stage in
  check-skip)
    for s in "${skips[@]}"; do
      ok=false
      for k in "${known[@]}"; do [[ $s == "$k" ]] && ok=true; done
      if [[ $ok != true ]]; then
        echo "::error title=ci-basic::unknown skip '$s'; expected any of: ${known[*]}"
        exit 2
      fi
    done
    ;;
  node)
    pm=${NODE_PM:?}
    case $pm in
      npm) npm ci ;;
      pnpm) pnpm install --frozen-lockfile ;;
      bun) bun install --frozen-lockfile ;;
      *) echo "::error title=ci-basic::unsupported package manager '$pm'"; exit 2 ;;
    esac
    ran=0
    for s in typecheck lint build test; do
      if jq -e --arg s "$s" '.scripts[$s] // empty' package.json >/dev/null; then
        step "$s" "$pm" run "$s"
        ran=$((ran + 1))
      fi
    done
    echo "package.json defines $ran of typecheck, lint, build, test"
    ;;
  go)
    step build go build ./...
    step test go test ./...
    ;;
  python)
    step build poetry install --no-interaction
    if [[ -n $(find . -path ./.venv -prune -o \( -name 'test_*.py' -o -name '*_test.py' \) -print -quit) ]]; then
      step test poetry run pytest
    else
      echo "No test_*.py or *_test.py files; pytest not run"
    fi
    ;;
  docker)
    step docker docker build -f "${DOCKERFILE:?}" "${DOCKER_CONTEXT:-.}"
    ;;
  extra)
    echo "::group::$EXTRA_RUN"
    bash -euo pipefail -c "$EXTRA_RUN"
    echo "::endgroup::"
    ;;
  *)
    echo "::error title=ci-basic::unknown stage '$stage'"
    exit 2
    ;;
esac
