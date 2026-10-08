#!/usr/bin/env bash
#
# Lists the GitHub repos linked in README.md whose last commit is older than a
# given age, one repo per line.
#
# Requires: gh (authenticated), jq.
#
# Usage:
#   ./github-graveyard-checker.sh [-y YEARS] [-j JOBS] [-v]
#
#   -y  age threshold in years (default: 2)
#   -j  parallel API requests (default: 8)
#   -v  also print the last-commit date and unreachable repos

set -uo pipefail

years=2
readme="README.md"
jobs=8
verbose=0

while getopts ':y:f:j:vh' opt; do
  case "$opt" in
    y) years="$OPTARG" ;;
    j) jobs="$OPTARG" ;;
    v) verbose=1 ;;
    h) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh is required: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required: https://jqlang.github.io/jq" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run 'gh auth login' first (the API rate limit makes anonymous runs useless here)" >&2; exit 1; }
[ -r "$readme" ] || { echo "cannot read $readme" >&2; exit 1; }

# Cutoff as an ISO-8601 UTC string. Timestamps in that format sort
# lexicographically, so the comparison below needs no date parsing.
if cutoff=$(date -u -d "$years years ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  : # GNU date
else
  cutoff=$(date -u -v-"${years}"y +%Y-%m-%dT%H:%M:%SZ) # BSD/macOS date
fi

# Every github.com link in the README, normalized to owner/repo: strips any
# /tree/... or /blob/... subpath, a trailing .git, and duplicates.
repos=()
while IFS= read -r repo; do
  repos+=("$repo")
done < <(
  grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$readme" |
    sed -E 's#^https://github\.com/##; s#\.git$##' |
    sort -u
)

[ "${#repos[@]}" -gt 0 ] || { echo "no github.com links found in $readme" >&2; exit 1; }

echo -e "checking ${#repos[@]} repos from $readme against $cutoff (${years}y)...\n\n" >&2

# One worker per repo: prints "<status>\t<date>\t<repo>".
check_repo() {
  local repo="$1" date
  if date=$(gh api "repos/${repo}/commits/HEAD" --jq '.commit.committer.date' 2>/dev/null) && [ -n "$date" ]; then
    printf 'ok\t%s\t%s\n' "$date" "$repo"
  else
    printf 'gone\t-\t%s\n' "$repo"
  fi
}
export -f check_repo

results=$(printf '%s\n' "${repos[@]}" | xargs -P "$jobs" -I{} bash -c 'check_repo "$@"' _ {})

stale=$(awk -F'\t' -v cutoff="$cutoff" '$1 == "ok" && $2 < cutoff' <<<"$results" | sort -t$'\t' -k2)
gone=$(awk -F'\t' '$1 == "gone" {print $3}' <<<"$results" | sort)

if [ -n "$stale" ]; then
  if [ "$verbose" -eq 1 ]; then
    awk -F'\t' '{printf "%s  https://github.com/%s\n", substr($2, 1, 10), $3}' <<<"$stale"
  else
    awk -F'\t' '{print "https://github.com/" $3}' <<<"$stale"
  fi
fi

stale_count=$([ -n "$stale" ] && wc -l <<<"$stale" || echo 0)
gone_count=$([ -n "$gone" ] && wc -l <<<"$gone" || echo 0)

echo -e "\n\n${stale_count// /} of ${#repos[@]} repos untouched for ${years}+ year(s)" >&2

if [ "$gone_count" -gt 0 ]; then
  echo "${gone_count// /} repo(s) unreachable (deleted, renamed, or private)" >&2
  [ "$verbose" -eq 1 ] && sed 's#^#  https://github.com/#' <<<"$gone" >&2
fi
