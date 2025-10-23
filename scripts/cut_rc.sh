#!/usr/bin/env bash
set -euo pipefail

# cut_rc.sh
#
# See `./cut_rc.sh --help` for usage and examples.

REMOTE="origin"
BASE_REF="origin/main"
DRY_RUN=false
FORCED_VERSION=""
REPLACE_PREV=false

print_help() {
  cat <<'EOF'
Usage: ./cut_rc.sh [options]

Cut or advance a release-candidate (RC) branch.

Default behavior:
  - If an active RC train exists (e.g., release/2.0.20-rc.2), continues it -> release/2.0.20-rc.3
  - Else, if no active train exists, starts a new train from the latest Production release tag
  - Always branches from origin/main

RC Numbering:
  - Continued trains increment (rc.0 -> rc.1 -> rc.2, etc.)
  - rc.0 = "Initial RC for this version"
  - rc.1+ = "Iteration with fixes/changes"

Options:
  --version X.Y.Z            Force specific version (e.g., from package.json)
  --replace                  After creating new RC, delete previous RC branch(es)
                             When starting new version, also cleans up active RC train
  --dry-run                  Print actions without changing anything
  --help                     Show this help message and exit

Examples:
  # Continue current RC train (increments RC number):
  ./cut_rc.sh --replace
  # Creates: release/2.0.20-rc.1, then rc.2, etc.

  # Start new RC train after production release (main already bumped to 2.12.0):
  ./cut_rc.sh --version $(node -p "require('./package.json').version") --replace
  # Creates: release/2.12.0-rc.0

  # Dry run to preview changes:
  ./cut_rc.sh --replace --dry-run

EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need git
need awk
need sed
need grep
need sort

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) print_help; exit 0;;
    --version)     FORCED_VERSION="${2:?X.Y.Z}"; shift 2;;
    --replace)     REPLACE_PREV=true; shift;;
    --dry-run)     DRY_RUN=true; shift;;
    *) echo "Unknown arg: $1" >&2; echo "Run ./cut_rc.sh --help for usage."; exit 2;;
  esac
done

semver_ok() { [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; }

git_safe() {
  if $DRY_RUN; then
    echo "(dry-run) git $*"
  else
    git "$@"
  fi
}

# --- Repo & cleanliness checks ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not a git repo" >&2; exit 1; }

# Stash any uncommitted changes before proceeding
STASHED=false
if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Stashing uncommitted changes..."
  if ! $DRY_RUN; then
    git stash push -u -m "cut_rc.sh temporary stash"
    STASHED=true
  fi
fi

echo "==> Fetching refs from ${REMOTE}..."

# Delete any local tags that might conflict with the fetch
echo "==> Cleaning up potentially conflicting local tags..."
if $DRY_RUN; then
  echo "(dry-run) git tag -l 'v*' | xargs -r git tag -d"
else
  git tag -l 'v*' | xargs -r git tag -d 2>/dev/null || true
fi

git_safe fetch --tags --prune "${REMOTE}" '+refs/heads/*:refs/remotes/'"${REMOTE}"'/*'

git rev-parse --verify -q "${BASE_REF}" >/dev/null || { echo "ERROR: base ref '${BASE_REF}' not found" >&2; exit 1; }

# --- Discover latest Prod release tag ---
LATEST_TAG="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n1 || true)"
PROD_VER="${LATEST_TAG#v}"
[[ -z "${LATEST_TAG}" ]] && PROD_VER="0.0.0"

# --- Discover highest active RC train on remote ---
ACTIVE_RC_VER=""
RC_HEADS="$(git ls-remote --heads "${REMOTE}" 'release/*-rc.*' \
  | awk '{print $2}' \
  | sed 's#refs/heads/release/##' \
  | sed -E 's/-rc\.[0-9]+$//' || true)"
if [[ -n "${RC_HEADS}" ]]; then
  ACTIVE_RC_VER="$(echo "${RC_HEADS}" \
    | sort -u -t. -k1,1n -k2,2n -k3,3n \
    | tail -n1)"
fi

# --- Decide TARGET_VERSION ---
TARGET_VERSION=""

if [[ -n "${FORCED_VERSION}" ]]; then
  semver_ok "${FORCED_VERSION}" || { echo "ERROR: --version must be X.Y.Z" >&2; exit 1; }
  TARGET_VERSION="${FORCED_VERSION}"
elif [[ -n "${ACTIVE_RC_VER}" ]]; then
  # Continue the existing train.
  TARGET_VERSION="${ACTIVE_RC_VER}"
else
  echo "ERROR: No active RC train found. Use --version X.Y.Z to specify version." >&2
  exit 1
fi

echo "==> Latest Prod release: ${LATEST_TAG:-<none>} | Active RC: ${ACTIVE_RC_VER:-<none>} | Target: ${TARGET_VERSION}"

# --- Determine next RC number for TARGET_VERSION & previous RC branch (for --replace) ---
PATTERN="release/${TARGET_VERSION}-rc."
RC_LIST_FOR_TARGET="$(git ls-remote --heads "${REMOTE}" "${PATTERN}*" || true)"

NEXT_RC=0
PREV_BRANCH=""
if [[ -n "${RC_LIST_FOR_TARGET}" ]]; then
  MAX_N=-1
  while read -r _sha _ref; do
    name="${_ref#refs/heads/}"   # release/X.Y.Z-rc.N
    n="${name##*.}"              # N
    [[ "${n}" =~ ^[0-9]+$ ]] || continue
    if (( n > MAX_N )); then
      MAX_N="${n}"
      PREV_BRANCH="${name}"
    fi
  done <<< "${RC_LIST_FOR_TARGET}"

  # If we found existing RCs, increment from the highest
  if (( MAX_N >= 0 )); then
    NEXT_RC=$((MAX_N + 1))
  fi
fi

NEW_BRANCH="release/${TARGET_VERSION}-rc.${NEXT_RC}"

echo "==> Creating ${NEW_BRANCH} from ${BASE_REF}"
git_safe checkout -q -B "${NEW_BRANCH}" "${BASE_REF}"

# --- Push the RC branch ---
git_safe push -u "${REMOTE}" "${NEW_BRANCH}"

# --- Optionally delete previous RC branches ---
if ${REPLACE_PREV}; then
  # Delete previous RC branch for same version (if exists)
  if [[ -n "${PREV_BRANCH}" ]]; then
    echo "==> Deleting previous RC on remote: ${PREV_BRANCH}"
    git_safe push "${REMOTE}" ":${PREV_BRANCH}"
  fi
  
  # Delete active RC branches from different version (if --version was specified)
  if [[ -n "${FORCED_VERSION}" ]] && [[ -n "${ACTIVE_RC_VER}" ]] && [[ "${ACTIVE_RC_VER}" != "${TARGET_VERSION}" ]]; then
    echo "==> Starting new version ${TARGET_VERSION}, cleaning up active RC train for ${ACTIVE_RC_VER}"
    ACTIVE_RC_BRANCHES="$(git ls-remote --heads "${REMOTE}" "release/${ACTIVE_RC_VER}-rc.*" \
      | awk '{print $2}' \
      | sed 's#refs/heads/##' || true)"
    
    if [[ -n "${ACTIVE_RC_BRANCHES}" ]]; then
      while read -r branch; do
        [[ -n "${branch}" ]] || continue
        echo "==> Deleting active RC branch: ${branch}"
        git_safe push "${REMOTE}" ":${branch}"
      done <<< "${ACTIVE_RC_BRANCHES}"
    fi
  fi
fi

echo "==> Done. RC branch is ${NEW_BRANCH}"
if $DRY_RUN; then
  echo "NOTE: run without --dry-run to apply changes."
fi

# Restore stashed changes if any
if $STASHED; then
  echo "==> Restoring stashed changes..."
  git stash pop
fi
