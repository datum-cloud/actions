#!/usr/bin/env bash
set -euo pipefail

: "${INDEX_REPO:?}" "${PLUGIN_NAME:?}" "${PLUGIN_FILE:?}" "${BASE_BRANCH:?}" "${GITHUB_OUTPUT:?}"

stable_branch="update-plugin/$PLUGIN_NAME"
plugin_file=$PLUGIN_FILE
while [[ $plugin_file == ./* ]]; do
  plugin_file=${plugin_file#./}
done

# Read every page and base so a head shared with another base is never changed.
# Only branches in the catalog itself can be updated by the catalog token.
pulls=$(gh api --method GET --paginate --slurp "repos/$INDEX_REPO/pulls" \
  -f state=open -f per_page=100 |
  jq -c --arg repo "$INDEX_REPO" '
    (add // []) | map(select(
      .state == "open" and
      ((.head.repo.full_name // "" | ascii_downcase) == ($repo | ascii_downcase))
    ))')

# Prefer the stable branch, then the oldest matching versioned review thread.
candidates=$(jq -r --arg base "$BASE_BRANCH" --arg stable "$stable_branch" '
  . as $pulls
  | map(select(
      .base.ref == $base and
      (.head.ref == $stable or (.head.ref | startswith($stable + "-")))
    ))
  | map(select(.head.ref as $head |
      all($pulls[]; .head.ref != $head or .base.ref == $base)
    ))
  | sort_by([.head.ref != $stable, .number])
  | .[] | [.number, .head.ref] | @tsv
' <<< "$pulls")

selected_branch=
while IFS=$'\t' read -r number branch; do
  [[ -n $number ]] || continue
  files=$(gh api --method GET --paginate --slurp \
    "repos/$INDEX_REPO/pulls/$number/files" -f per_page=100 |
    jq -c '(add // []) | map(.filename)')
  # Exact paths distinguish similarly named plugins and preserve other edits.
  if jq -e --arg file "$plugin_file" '. == [$file]' <<< "$files" >/dev/null; then
    selected_branch=$branch
    break
  fi
done <<< "$candidates"

if [[ -z $selected_branch ]]; then
  conflict=$(jq -r --arg stable "$stable_branch" '
    [.[] | select(.head.ref == $stable)][0].number // empty
  ' <<< "$pulls")
  if [[ -n $conflict ]]; then
    printf '::error::Branch %s is used by PR #%s that does not exclusively update %s against %s\n' \
      "$stable_branch" "$conflict" "$plugin_file" "$BASE_BRANCH" >&2
    exit 1
  fi
  selected_branch=$stable_branch
fi

printf 'branch=%s\n' "$selected_branch" >> "$GITHUB_OUTPUT"
printf 'Using pull request branch: %s\n' "$selected_branch"
