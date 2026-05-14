#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   claude_pr.sh <UP_REPO> <MY_REPO> <PR_NUM> <SHA_PRE> [options]
#
# Required:
#   UP_REPO     upstream GitHub repo (e.g. plume-lib/plume-util)
#   MY_REPO     your GitHub repo     (e.g. tijanaminic1/plume-617-ai-updated)
#   PR_NUM      PR number from the upstream repo
#   SHA_PRE     commit to snapshot as prestate (use <sha>^ for the parent)
#
# Options:
#   --build-cmd CMD    command to verify the build (default: ./gradlew build)
#   --max-attempts N   max Claude iterations before giving up (default: 8)
#   --model MODEL      Claude model: sonnet|opus|haiku or full ID (default: sonnet)
#   --effort LEVEL     Claude effort: low|medium|high (default: medium)
#   --open-pr          open a GitHub PR after pushing (requires gh CLI)
#
# Examples:
#   ./claude_pr.sh plume-lib/plume-util tijanaminic1/plume-617-ai-updated 617 \
#     0623a7574c6684c347dff65245d99174eeeda58b^
#
#   ./claude_pr.sh TEAMMATES/teammates tijanaminic1/teammates-ai 13046 \
#     abc123^ --build-cmd "./gradlew test" --max-attempts 5 --open-pr

# ── Defaults ──────────────────────────────────────────────────────────────────

BUILD_CMD="./gradlew build"
MAX_ATTEMPTS=8
CLAUDE_MODEL="sonnet"
CLAUDE_EFFORT="medium"
CLAUDE_PERMISSION_MODE="acceptEdits"
CLAUDE_CMD="claude"
OPEN_PR=false

WORKDIR="$HOME/Documents/GitHub"
PRE_BRANCH="prestate"
POST_BRANCH="poststate"
PRE_COMMIT_MSG="Before PR snapshot"
POST_COMMIT_MSG="Claude solution snapshot"

# ── Argument parsing ──────────────────────────────────────────────────────────

if [ $# -lt 4 ]; then
  echo "Usage: $0 <UP_REPO> <MY_REPO> <PR_NUM> <SHA_PRE> [options]" >&2
  echo "Run with --help for full usage." >&2
  exit 1
fi

UP_REPO_NAME="$1"
MY_REPO_NAME="$2"
PR_NUM="$3"
SHA_PRE="$4"
shift 4

while [ $# -gt 0 ]; do
  case "$1" in
    --build-cmd)    BUILD_CMD="$2";    shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --model)        CLAUDE_MODEL="$2"; shift 2 ;;
    --effort)       CLAUDE_EFFORT="$2"; shift 2 ;;
    --open-pr)      OPEN_PR=true;      shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Derived ───────────────────────────────────────────────────────────────────

UPSTREAM_REPO_URL="https://github.com/${UP_REPO_NAME}.git"
MY_REPO_URL="https://github.com/${MY_REPO_NAME}.git"

UP_PRE_DIR="$(basename "${UP_REPO_NAME}")-pre"
MY_PRE_DIR="$(basename "${MY_REPO_NAME}")-pr${PR_NUM}-prestate"
MY_POST_DIR="$(basename "${MY_REPO_NAME}")-pr${PR_NUM}-poststate"

INPUT_DIR="$WORKDIR/_inputs"
ISSUE_FILE="$(basename "${MY_REPO_NAME}")-pr${PR_NUM}-issue.txt"
ISSUE_PATH="$INPUT_DIR/$ISSUE_FILE"
BUILD_LOG="$INPUT_DIR/$(basename "${MY_REPO_NAME}")-pr${PR_NUM}-build.log"

# ── Helpers ───────────────────────────────────────────────────────────────────

require_cmd() {
  command -v "$1" >/dev/null || { echo "Missing dependency: $1" >&2; exit 1; }
}

ensure_repo() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "[reuse] $dir"
    (cd "$dir" && git fetch -p origin >/dev/null)
  elif [ -e "$dir" ]; then
    echo "ERROR: $dir exists but is not a git repository." >&2; exit 1
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

capture_issue_text() {
  local out_path="$1"
  cat <<'EOF'

============================================================
PASTE ISSUE / PR DESCRIPTION
- Paste the full issue or PR description below.
- End input with Ctrl-D (EOF) on a new line.
============================================================

EOF
  cat > "$out_path"
  echo
  echo "[ok] Saved description to: $out_path"
}

run_claude_iteration() {
  local attempt="$1"
  local extra_context="${2:-}"

  local prompt
  prompt=$(cat <<EOF
You are working inside a git repository. Implement the changes described below by editing the repository files directly.

Requirements:
- Make the code changes, do not just describe a plan.
- Keep changes minimal and localized.
- The repository must end in a state where this command passes:
  ${BUILD_CMD}
- If the build is currently failing, use the failure output to guide the next fix.
- Preserve the intended behavior from the task description.
- Do NOT add or commit any new artifact files such as issue text, logs, notes, or patches.
- Do NOT modify git metadata or create commits.
- At the end, summarize what files you changed and why.

Task description:
$(cat "$ISSUE_PATH")

Iteration: ${attempt}/${MAX_ATTEMPTS}

${extra_context}
EOF
)

  (
    cd "$WORKDIR/$MY_POST_DIR"
    "$CLAUDE_CMD" -p \
      --model "$CLAUDE_MODEL" \
      --effort "$CLAUDE_EFFORT" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" \
      "$prompt" \
      >/dev/null
  )
}

run_build_check() {
  (cd "$WORKDIR/$MY_POST_DIR" && bash -lc "$BUILD_CMD" >"$BUILD_LOG" 2>&1)
}

# ── Main ──────────────────────────────────────────────────────────────────────

require_cmd git
require_cmd rsync
require_cmd "$CLAUDE_CMD"

mkdir -p "$WORKDIR" "$INPUT_DIR"
cd "$WORKDIR"

# Upstream PRE snapshot
ensure_repo "$UPSTREAM_REPO_URL" "$UP_PRE_DIR"
(cd "$UP_PRE_DIR" && git fetch -p origin >/dev/null && git checkout "${SHA_PRE}")

# PRESTATE branch in your repo
ensure_repo "$MY_REPO_URL" "$MY_PRE_DIR"
(cd "$MY_PRE_DIR" && git fetch origin >/dev/null && git checkout -B "$PRE_BRANCH")
clean_snapshot_into_repo "$WORKDIR/$UP_PRE_DIR" "$WORKDIR/$MY_PRE_DIR"
(cd "$MY_PRE_DIR" && git add -A && git commit -m "$PRE_COMMIT_MSG" --allow-empty && git push -u origin "$PRE_BRANCH" -f)

# POSTSTATE branch based on PRESTATE
ensure_repo "$MY_REPO_URL" "$MY_POST_DIR"
(cd "$MY_POST_DIR" && git fetch origin >/dev/null && git checkout -B "$POST_BRANCH" origin/"$PRE_BRANCH")
clean_snapshot_into_repo "$WORKDIR/$MY_PRE_DIR" "$WORKDIR/$MY_POST_DIR"

# Capture issue text
capture_issue_text "$ISSUE_PATH"

echo
echo "============================================================"
echo "Running Claude/build loop in: $WORKDIR/$MY_POST_DIR"
echo "Task input:   $ISSUE_PATH"
echo "Build cmd:    $BUILD_CMD"
echo "Max attempts: $MAX_ATTEMPTS"
echo "============================================================"
echo

attempt=1
build_passed=0
failure_context=""

while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  echo "[claude] Attempt $attempt/$MAX_ATTEMPTS"
  run_claude_iteration "$attempt" "$failure_context"

  echo "[build] Running: $BUILD_CMD"
  if run_build_check; then
    echo "[ok] Build passed on attempt $attempt"
    build_passed=1
    break
  fi

  echo "[warn] Build failed on attempt $attempt — last 200 lines:"
  tail -n 200 "$BUILD_LOG" || true

  failure_context=$(cat <<EOF
The previous attempt did not pass the build.

Here is the tail of the build output:
$(tail -n 200 "$BUILD_LOG" 2>/dev/null || echo "No build log available.")

Please fix the actual cause of the failure and keep the intended task changes.
Do not revert correct earlier edits unless they are directly causing the build failure.
EOF
)
  attempt=$((attempt + 1))
done

if [ "$build_passed" -ne 1 ]; then
  echo "ERROR: Claude did not produce a build-passing solution after $MAX_ATTEMPTS attempts." >&2
  echo "See build log: $BUILD_LOG" >&2
  exit 1
fi

# Commit and push if Claude made real changes
(
  cd "$WORKDIR/$MY_POST_DIR"

  echo
  echo "Working tree status after Claude:"
  git status --porcelain

  git add -A

  if git diff --cached --quiet; then
    echo "ERROR: No code changes detected (nothing to commit)." >&2
    echo "Claude did not edit any files in the repo." >&2
    exit 1
  fi

  echo
  echo "About to commit:"
  git diff --cached --name-status

  git commit -m "$POST_COMMIT_MSG"
  git push -u origin "$POST_BRANCH" -f

  echo
  echo "Files changed (prestate..poststate):"
  git diff --name-status origin/"$PRE_BRANCH"...origin/"$POST_BRANCH" || true
)

echo
if [ "$OPEN_PR" = true ]; then
  echo "Opening pull request ..."
  gh pr create \
    --repo "$MY_REPO_NAME" \
    --base "$PRE_BRANCH" \
    --head "$POST_BRANCH" \
    --title "PR #${PR_NUM} Claude solution" \
    --body ""
else
  echo "Done. Create a Pull Request with:"
  echo "  Base branch:    ${PRE_BRANCH}"
  echo "  Compare branch: ${POST_BRANCH}"
fi
