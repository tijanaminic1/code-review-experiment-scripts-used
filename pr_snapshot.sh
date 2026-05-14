#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   Standard PR (merged into default branch):
#     pr_snapshot.sh <UP_REPO> <MY_REPO> <PR_NUM> <SHA_PRE> <SHA_POST>
#
#     SHA_PRE is typically the commit just before the merge, written as
#     <merge-commit>^ (e.g. abc123^), and SHA_POST is the merge commit itself.
#
#   Merge commit targeting a non-default branch:
#     pr_snapshot.sh <UP_REPO> <MY_REPO> <PR_NUM> "" <SHA_POST> <BASE_BRANCH>
#
#     Pass an empty string for SHA_PRE and provide the name of the branch the
#     PR was merged into as the 6th argument. The script will compute SHA_PRE
#     automatically via `git merge-base origin/<BASE_BRANCH> <SHA_POST>`.
#     Using SHA_POST^ would give you the wrong parent for a merge commit;
#     merge-base finds the actual divergence point on the target branch.
#
# Examples:
#   ./pr_snapshot.sh plume-lib/plume-util tijanaminic1/pid19-pr1 617 \
#     0623a7574c6684c347dff65245d99174eeeda58b^ \
#     ecdc2bfaf17b01f72cb9f1d52c3be9ca729c010c
#
#   ./pr_snapshot.sh TEAMMATES/teammates tijanaminic1/pid18-pr4 13046 \
#     "" 7955752d26fe7febdb3305465ce8801b0347c0b9 v9-course-migration

# Strip --open-pr flag from args before positional parsing
OPEN_PR=false
ARGS=()
for arg in "$@"; do
  [ "$arg" = "--open-pr" ] && OPEN_PR=true || ARGS+=("$arg")
done
set -- "${ARGS[@]}"

if [ $# -lt 5 ] || [ $# -gt 6 ]; then
  echo "Usage: $0 <UP_REPO> <MY_REPO> <PR_NUM> <SHA_PRE> <SHA_POST> [BASE_BRANCH] [--open-pr]" >&2
  exit 1
fi

UP_REPO_NAME="$1"
MY_REPO_NAME="$2"
PR_NUM="$3"
SHA_PRE="$4"
SHA_POST="$5"
BASE_BRANCH="${6:-}"

WORKDIR="$HOME/Documents/GitHub"

# ── Derived ───────────────────────────────────────────────────────────────────

UPSTREAM_REPO_URL="https://github.com/${UP_REPO_NAME}.git"
MY_REPO_URL="https://github.com/${MY_REPO_NAME}.git"

UP_PRE_DIR="$(basename "${UP_REPO_NAME}")-pre"
UP_POST_DIR="$(basename "${UP_REPO_NAME}")-post"

MY_PRE_DIR="$(basename "${MY_REPO_NAME}")-pr${PR_NUM}-prestate"
MY_POST_DIR="$(basename "${MY_REPO_NAME}")-pr${PR_NUM}-poststate"

PRE_BRANCH="prestate"
POST_BRANCH="poststate"
PR_BRANCH="pr-${PR_NUM}"

# ── Helpers ───────────────────────────────────────────────────────────────────

ensure_repo() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "[reuse] $dir"
    (cd "$dir" && git fetch -p origin >/dev/null)
  elif [ -e "$dir" ]; then
    echo "ERROR: $dir exists but is not a git repository." >&2
    exit 1
  else
    echo "[clone] $url -> $dir"
    git clone "$url" "$dir"
  fi
}

clean_snapshot_into_repo() {
  local src="$1" dst="$2"
  (cd "$dst" && git rm -r --quiet --ignore-unmatch . >/dev/null 2>&1 || true)
  (cd "$dst" && git clean -fdx >/dev/null)
  rsync -a --delete --exclude '.git' "${src}/" "${dst}/"
}

# ── Main ──────────────────────────────────────────────────────────────────────

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Upstream PRE snapshot
ensure_repo "$UPSTREAM_REPO_URL" "$UP_PRE_DIR"
(cd "$UP_PRE_DIR" && git fetch origin "pull/${PR_NUM}/head:${PR_BRANCH}" >/dev/null)
if [ -n "$BASE_BRANCH" ]; then
  (cd "$UP_PRE_DIR" && git fetch origin "$BASE_BRANCH" >/dev/null)
  SHA_PRE="$(cd "$UP_PRE_DIR" && git merge-base "origin/${BASE_BRANCH}" "${SHA_POST}")"
  echo "Computed SHA_PRE (merge-base of origin/${BASE_BRANCH} and ${SHA_POST}): ${SHA_PRE}"
fi
(cd "$UP_PRE_DIR" && git checkout "${SHA_PRE}")

# Upstream POST snapshot
ensure_repo "$UPSTREAM_REPO_URL" "$UP_POST_DIR"
(cd "$UP_POST_DIR" && git fetch origin "pull/${PR_NUM}/head:${PR_BRANCH}" >/dev/null && git checkout "${SHA_POST}")

# PRESTATE branch in your repo
ensure_repo "$MY_REPO_URL" "$MY_PRE_DIR"
(cd "$MY_PRE_DIR" && git fetch origin >/dev/null && git checkout -B "$PRE_BRANCH")
clean_snapshot_into_repo "$WORKDIR/$UP_PRE_DIR" "$WORKDIR/$MY_PRE_DIR"
(cd "$MY_PRE_DIR" && git add -A && git commit -m "Before PR snapshot" --allow-empty && git push -u origin "$PRE_BRANCH" -f)

# POSTSTATE branch based on PRESTATE
ensure_repo "$MY_REPO_URL" "$MY_POST_DIR"
(cd "$MY_POST_DIR" && git fetch origin >/dev/null && git checkout -B "$POST_BRANCH" origin/"$PRE_BRANCH")
clean_snapshot_into_repo "$WORKDIR/$UP_POST_DIR" "$WORKDIR/$MY_POST_DIR"
(cd "$MY_POST_DIR" && git add -A && git commit -m "After PR snapshot" --allow-empty && git push -u origin "$POST_BRANCH" -f)

# Verification diff
(
  cd "$MY_POST_DIR"
  git fetch origin >/dev/null
  echo "Merge base:"
  git merge-base origin/"$PRE_BRANCH" origin/"$POST_BRANCH"
  echo
  echo "Files changed (PR diff):"
  git diff --name-status origin/"$PRE_BRANCH"...origin/"$POST_BRANCH"
)

echo
if [ "$OPEN_PR" = true ]; then
  echo "Opening pull request ..."
  gh pr create \
    --repo "$MY_REPO_NAME" \
    --base "$PRE_BRANCH" \
    --head "$POST_BRANCH" \
    --title "PR #${PR_NUM} snapshot" \
    --body ""
else
  echo "Done. Create a Pull Request with:"
  echo "  Base branch:    ${PRE_BRANCH}"
  echo "  Compare branch: ${POST_BRANCH}"
fi
