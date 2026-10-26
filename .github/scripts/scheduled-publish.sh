#!/usr/bin/env bash
# Merges open PRs labelled "scheduled" once every blog post they add or change
# is due: `draft: false` and a `pubDatetime` in the past. Also requires green
# checks and a clean merge. Run by .github/workflows/scheduled-publish.yml.
# DRY_RUN=1 logs what it would do without changing anything.
#
# A label approves a PR, not a commit, so only PRs from this repo's own
# branches by ALLOWED_AUTHOR are merged, and only at the commit that was checked.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY to owner/name}"
LABEL="${LABEL:-scheduled}"
DRY_RUN="${DRY_RUN:-0}"
ALLOWED_AUTHOR="${ALLOWED_AUTHOR:-${REPO%%/*}}"
POSTS_DIR="src/data/blog/"
# Post paths the script will read; anything else could change the API request.
POST_PATH='^src/data/blog/[A-Za-z0-9._/-]+\.md$'

# Prints a frontmatter value from a Markdown file on stdin, without quotes.
frontmatter_value() {
  awk -v key="$1" '
    /^---[[:space:]]*$/ { fences++; next }
    fences == 1 && $0 ~ "^" key ":" {
      sub("^" key ":[[:space:]]*", "")
      gsub(/^["\047]|["\047][[:space:]]*$/, "")
      print
      exit
    }'
}

# Unix seconds for an ISO 8601 time with an offset (as pubDatetime is written).
to_epoch() {
  python3 -c 'import sys, datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))' "$1"
}

# Unix seconds as "YYYY-MM-DD HH:MM UTC".
fmt_utc() {
  python3 -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))' "$1"
}

# True when every check on the PR has finished green; pending counts as not green.
checks_green() {
  gh pr view "$1" --repo "$REPO" --json statusCheckRollup --jq \
    '[.statusCheckRollup[] | (.conclusion // .state)]
     | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")'
}

# Echoes the latest pubDatetime (Unix seconds) of the PR's posts, or a reason
# on stderr and a non-zero status when the PR isn't ready.
due_time() {
  local number="$1" sha="$2" latest=0 found=0
  local paths
  paths=$(gh api "repos/$REPO/pulls/$number/files" --paginate \
    --jq ".[] | select(.status != \"removed\") | .filename | select(startswith(\"$POSTS_DIR\") and endswith(\".md\"))")
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ ! "$path" =~ $POST_PATH || "$path" == *..* ]]; then
      echo "$path is not a plain post path" >&2
      return 1
    fi
    found=1
    local content draft published epoch
    content=$(gh api "repos/$REPO/contents/$path?ref=$sha" -H "Accept: application/vnd.github.raw")
    draft=$(frontmatter_value draft <<<"$content")
    published=$(frontmatter_value pubDatetime <<<"$content")
    if [[ "$draft" == "true" ]]; then
      echo "$path is still draft: true" >&2
      return 1
    fi
    if [[ -z "$published" ]]; then
      echo "$path has no pubDatetime" >&2
      return 1
    fi
    epoch=$(to_epoch "$published")
    ((epoch > latest)) && latest=$epoch
  done <<<"$paths"
  if ((found == 0)); then
    echo "changes no post under $POSTS_DIR" >&2
    return 1
  fi
  echo "$latest"
}

main() {
  local now prs
  now=$(date -u +%s)
  prs=$(gh pr list --repo "$REPO" --label "$LABEL" --state open \
    --json number,headRefOid,isDraft,mergeable,isCrossRepository,author \
    --jq '.[] | "\(.number) \(.headRefOid) \(.isDraft) \(.mergeable) \(.isCrossRepository) \(.author.login)"')
  if [[ -z "$prs" ]]; then
    echo "No open PRs labelled $LABEL."
    return 0
  fi

  while read -r number sha is_draft mergeable cross_repo author; do
    local due
    if [[ "$cross_repo" != "false" || "$author" != "$ALLOWED_AUTHOR" ]]; then
      echo "#$number: from $author (fork: $cross_repo); only $ALLOWED_AUTHOR's own branches are published."
      continue
    fi
    if ! due=$(due_time "$number" "$sha"); then
      echo "#$number: skipped (see above)."
      continue
    fi
    if ((now < due)); then
      echo "#$number: due $(fmt_utc "$due"), not yet."
      continue
    fi
    if [[ "$mergeable" != "MERGEABLE" ]]; then
      echo "#$number: due, but mergeable is $mergeable; skipped."
      continue
    fi
    if [[ "$(checks_green "$number")" != "true" ]]; then
      echo "#$number: due, but checks aren't all green; skipped."
      continue
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "#$number: due and ready; would merge (dry run)."
      continue
    fi
    [[ "$is_draft" == "true" ]] && gh pr ready "$number" --repo "$REPO"
    # Merge only the commit checked above; a push since then cancels the merge.
    gh pr merge "$number" --repo "$REPO" --squash --match-head-commit "$sha"
    gh pr comment "$number" --repo "$REPO" \
      --body "Published by the scheduled-publish workflow at $(date -u '+%Y-%m-%d %H:%M UTC')."
    echo "#$number: merged."
  done <<<"$prs"
}

main "$@"
