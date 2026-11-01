#!/usr/bin/env bash
set -euo pipefail

dir=${CI_PATH:-.}
dockerfile=${DOCKERFILE:-Dockerfile}
out=${GITHUB_OUTPUT:-/dev/stdout}

[[ -d $dir ]] || { echo "::error title=ci-basic::path '$dir' is not a directory"; exit 2; }
cd "$dir"

emit() { printf '%s=%s\n' "$1" "$2" >>"$out"; }

pm=""
if [[ -f package.json ]]; then
  if [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then pm=npm
  elif [[ -f pnpm-lock.yaml ]]; then pm=pnpm
  elif [[ -f bun.lock || -f bun.lockb ]]; then pm=bun
  else
    echo "::error title=ci-basic::package.json has no npm, pnpm or bun lockfile beside it"
    exit 2
  fi
fi
emit node-pm "$pm"

node_version_file=""
for f in .nvmrc .node-version; do
  if [[ -f $f ]]; then node_version_file="$dir/$f"; break; fi
done
emit node-version-file "$node_version_file"

pnpm_version=""
if [[ $pm == pnpm ]] && ! jq -e '.packageManager // "" | startswith("pnpm@")' package.json >/dev/null; then
  pnpm_version=10
fi
emit pnpm-version "$pnpm_version"

go=false
[[ -f go.mod ]] && go=true
emit go "$go"

python=false
if [[ -f pyproject.toml && -f poetry.lock ]]; then python=true; fi
emit python "$python"

python_version_file=""
[[ -f .python-version ]] && python_version_file="$dir/.python-version"
emit python-version-file "$python_version_file"

docker=false
[[ -f $dockerfile ]] && docker=true
emit docker "$docker"

found=()
[[ -n $pm ]] && found+=("node ($pm)")
[[ $go == true ]] && found+=(go)
[[ $python == true ]] && found+=("python (poetry)")
[[ $docker == true ]] && found+=("docker ($dockerfile)")

if [[ ${#found[@]} -eq 0 && -z ${EXTRA_RUN:-} ]]; then
  echo "::error title=ci-basic::nothing to build in '$dir': no package.json, go.mod, poetry project or $dockerfile, and no run command"
  exit 2
fi

echo "Found: ${found[*]:-nothing; running the run command only}"
