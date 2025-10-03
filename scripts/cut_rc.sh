#!/usr/bin/env bash
set -euo pipefail

# mac_cut_rc.sh
#
# See `./mac_cut_rc.sh --help` for usage and examples.

REMOTE="origin"
BASE_REF="origin/main"
DRY_RUN=false
BUMP_KIND=""         # "", "patch", "minor", or "major"
FORCED_VERSION=""
REPLACE_PREV=false

PKG_PATH="package.json"
COMMIT_PKG=true

print_help() {
  cat <<'EOF'
Usage: ./cut_rc.sh [options]

Cut or advance a release-candidate (RC) branch.

Default behavior:
  - If an active RC train exists (e.g., release/2.0.20-rc.2), continues it -> release/2.0.20-rc.3
  - Else, if no active train exists, starts a new train from the latest Production release tag
  - If you pass --bump (patch|minor|major): explicitly start a new train AND update package.json to plain X.Y.Z (no -rc)

RC Numbering:
  - New trains start at rc.0 (e.g., release/2.0.20-rc.0) when using --bump
  - Continued trains increment (rc.0 -> rc.1 -> rc.2, etc.)
  - rc.0 = "Initial RC for this version"
  - rc.1+ = "Iteration with fixes/changes"

Options:
  --bump patch|minor|major   Start a new train (Prod release bump) AND update package.json on the RC branch to X.Y.Z
  --version X.Y.Z            Force target version (advanced). Does NOT update package.json unless --bump is also used
  --base <ref>               Base ref for cutting RC (default: origin/main)
  --replace                  After creating new RC, delete previous RC branch for that same version
  --keep-prev                Do not delete previous RC (default)
  --pkg <path>               package.json path (default: package.json) used ONLY when --bump is present
  --no-commit                Do not commit the package.json change (default commits)
  --dry-run                  Print actions without changing anything
  --help                     Show this help message and exit

Examples:
  # Start a new Dev cycle after a Prod release (creates rc.0):
  ./cut_rc.sh --bump patch --replace
  # Creates: release/2.0.21-rc.0
  
  # Continue current train (increments RC number):
  ./cut_rc.sh --replace
  # Creates: release/2.0.21-rc.1, then rc.2, etc.

  # Dry run to preview changes:
  ./cut_rc.sh --replace --dry-run

  # Force target version AND update package.json (because --bump is also used):
  ./mac_cut_rc.sh --version 2.3.0 --bump minor --replace
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need git
need awk
need sed
need grep
need sort
need node

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) print_help; exit 0;;
    --bump)        BUMP_KIND="${2:?patch|minor|major}"; shift 2;;
    --version)     FORCED_VERSION="${2:?X.Y.Z}"; shift 2;;
    --base)        BASE_REF="${2:?ref}"; shift 2;;
    --replace)     REPLACE_PREV=true; shift;;
    --keep-prev)   REPLACE_PREV=false; shift;;
    --pkg)         PKG_PATH="${2:?path}"; shift 2;;
    --no-commit)   COMMIT_PKG=false; shift;;
    --dry-run)     DRY_RUN=true; shift;;
    --retire-prev) echo "NOTE: --retire-prev is deprecated; use --replace" >&2; REPLACE_PREV=true; shift;;
    *) echo "Unknown arg: $1" >&2; echo "Run ./mac_cut_rc.sh --help for usage."; exit 2;;
  esac
done

semver_ok() { [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; }

bump_semver() {
  local ver="$1" kind="${2:-patch}"
  semver_ok "${ver}" || { echo "bad semver: ${ver}" >&2; return 1; }
  local major minor patch
  IFS='.' read -r major minor patch <<< "${ver}"
  case "${kind}" in
    patch) patch=$((patch+1));;
    minor) minor=$((minor+1)); patch=0;;
    major) major=$((major+1)); minor=0; patch=0;;
    *) echo "bad bump kind: ${kind}" >&2; return 1;;
  esac
  echo "${major}.${minor}.${patch}"
}

git_safe() {
  if $DRY_RUN; then
    echo "(dry-run) git $*"
  else
    git "$@"
  fi
}

# --- Repo & cleanliness checks ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not a git repo" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "ERROR: working tree not clean" >&2; exit 1; }

echo "==> Fetching refs from ${REMOTE}..."
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

# --- Decide TARGET_VERSION and whether this is a "new train" ---
IS_NEW_TRAIN=false
TARGET_VERSION=""

if [[ -n "${FORCED_VERSION}" ]]; then
  semver_ok "${FORCED_VERSION}" || { echo "ERROR: --version must be X.Y.Z" >&2; exit 1; }
  TARGET_VERSION="${FORCED_VERSION}"
  # NOTE: Only --bump triggers package.json update. Forcing a version alone will NOT update package.json.
  # You can combine: --version X.Y.Z --bump patch|minor|major to force version AND update package.json.

elif [[ -n "${BUMP_KIND}" ]]; then
  # Explicit "start a new train" with bump (also triggers package.json update).
  TARGET_VERSION="$(bump_semver "${PROD_VER}" "${BUMP_KIND}")"
  IS_NEW_TRAIN=true

elif [[ -n "${ACTIVE_RC_VER}" ]]; then
  # Continue the existing train.
  TARGET_VERSION="${ACTIVE_RC_VER}"

else
  # No active RC and no --bump: start a new PATCH train by default (no package.json update).
  TARGET_VERSION="$(bump_semver "${PROD_VER}" "patch")"
  IS_NEW_TRAIN=false
fi

echo "==> Latest Prod release: ${LATEST_TAG:-<none>} | Active RC: ${ACTIVE_RC_VER:-<none>} | Target: ${TARGET_VERSION} | New train: ${IS_NEW_TRAIN}"

# --- Determine next RC number for TARGET_VERSION & previous RC branch (for --replace) ---
PATTERN="release/${TARGET_VERSION}-rc."
RC_LIST_FOR_TARGET="$(git ls-remote --heads "${REMOTE}" "${PATTERN}*" || true)"

# Decide starting RC number based on whether this is a new train
if [[ "${IS_NEW_TRAIN}" == "true" ]]; then
  # New train starts at rc.0
  NEXT_RC=0
else
  # Continuing train starts at rc.1 (or increments from existing)
  NEXT_RC=1
fi

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

# --- If this is a NEW TRAIN triggered by --bump, update package.json to plain X.Y.Z on the RC branch ---
maybe_update_pkg_for_new_train() {
  local version_to_write="$1" # X.Y.Z (no rc)
  local pkg="${PKG_PATH}"

  if [[ "${IS_NEW_TRAIN}" != "true" || "${NEXT_RC}" -ne 1 ]]; then
    return 0
  fi

  if [[ ! -f "${pkg}" ]]; then
    echo "WARNING: package.json not found at '${pkg}'. Skipping update."
    return 0
  fi

  echo "==> Updating ${pkg} version -> ${version_to_write}"
  local node_script="
    const fs = require('fs');
    const p = '${pkg}'.replace(/\\\\/g, '/');
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    j.version = '${version_to_write}';
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\\n');
  "
  if $DRY_RUN; then
    echo '(dry-run) node -e "<edit package.json>"'
  else
    node -e "${node_script}"
  fi

  if $COMMIT_PKG; then
    echo "==> Committing ${pkg} change"
    git_safe add "${pkg}"
    git_safe commit -m "chore(version): set ${pkg} to ${version_to_write} (start new train)"
  else
    echo "NOTE: --no-commit used: ${pkg} modified but not committed."
  fi
}

maybe_update_pkg_for_new_train "${TARGET_VERSION}"

# --- Push the RC branch (includes any pkg commit if made) ---
git_safe push -u "${REMOTE}" "${NEW_BRANCH}"

# --- Optionally delete previous RC branch for the same version ---
if ${REPLACE_PREV} && [[ -n "${PREV_BRANCH}" ]]; then
  echo "==> Deleting previous RC on remote: ${PREV_BRANCH}"
  git_safe push "${REMOTE}" ":${PREV_BRANCH}"
fi

echo "==> Done. RC branch is ${NEW_BRANCH}"
$DRY_RUN && echo "NOTE: run without --dry-run to apply changes."
