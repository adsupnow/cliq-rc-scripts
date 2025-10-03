#!/usr/bin/env bash
set -euo pipefail

# promote_rc.sh
#
# Promote an RC branch to a Production release tag.
#
# What it does:
#   - Verifies the RC branch name matches release/X.Y.Z-rc.N
#   - Creates an annotated tag vX.Y.Z from the RC branch HEAD
#   - Pushes the tag to the remote (defaults to 'origin')
#   - Creates and publishes a GitHub Release (triggers deployment workflows)
#
# Optional:
#   - --update-pkg: Set package.json "version" to X.Y.Z on the RC branch before tagging (off by default)
#   - --pkg <path>: Path to package.json (default: package.json)
#   - --no-commit:  Do not commit package.json change
#
# Requirements:
#   - GitHub CLI (gh) must be installed and authenticated
#
# See `./promote_rc.sh --help` for usage & examples.

REMOTE="origin"
DRY_RUN=false
RC_BRANCH=""          # if empty, deduce from current branch
TAG_MESSAGE=""        # optional tag message
UPDATE_PKG=false
PKG_PATH="package.json"
COMMIT_PKG=true

print_help() {
  cat <<'EOF'
Usage: ./promote_rc.sh [options]

Promote an RC branch to a Production release tag (vX.Y.Z) and publish a GitHub Release.

By default:
  - Automatically finds and promotes the highest RC branch if --rc is not provided
  - Requires the branch to match: release/X.Y.Z-rc.N
  - Creates tag: vX.Y.Z (annotated) from the RC HEAD
  - Pushes the tag to 'origin'
  - Creates and publishes a GitHub Release (triggers deployment workflows)

Requirements:
  - GitHub CLI (gh) must be installed and authenticated

Options:
  --rc <branch>          RC branch to promote (e.g., release/2.0.20-rc.3). If not provided, automatically finds the latest RC
  --message "<text>"     Annotated tag message (defaults to "Release vX.Y.Z")
  --remote <name>        Remote to push tags to (default: origin)
  --dry-run              Print actions without changing anything

Package.json options (optional):
  --update-pkg           Update package.json "version" to X.Y.Z on the RC branch before tagging
  --pkg <path>           Path to package.json (default: package.json)
  --no-commit            Do not commit the package.json change

Examples:
  # Promote the latest RC branch to prod (auto-detects highest version):
  ./promote_rc.sh

  # Promote a specific RC branch:
  ./promote_rc.sh --rc release/2.0.20-rc.3

  # Promote and add a custom tag message:
  ./promote_rc.sh --message "Prod release 2.0.20"

  # Promote and also update package.json on the RC branch to 2.0.20:
  ./promote_rc.sh --update-pkg

  # Dry run (no changes):
  ./promote_rc.sh --dry-run
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need git
need awk
need grep
need sed
need node

# Check for GitHub CLI with helpful error message
if ! command -v gh &> /dev/null; then
  echo "ERROR: GitHub CLI (gh) is not installed" >&2
  echo "This script requires the GitHub CLI to create releases." >&2
  echo "Please install it: https://cli.github.com/" >&2
  echo "" >&2
  echo "On macOS: brew install gh" >&2
  echo "Then authenticate: gh auth login" >&2
  exit 1
fi

# Verify gh is authenticated
if ! gh auth status &> /dev/null; then
  echo "ERROR: GitHub CLI is not authenticated" >&2
  echo "Please run: gh auth login" >&2
  exit 1
fi

git_safe() {
  if $DRY_RUN; then
    echo "(dry-run) git $*"
  else
    git "$@"
  fi
}

find_latest_rc() {
  # Find all RC branches, sort them, and return the highest version
  git branch -r | grep -E "origin/release/[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$" | \
    sed 's|.*origin/||' | \
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | \
    tail -1
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) print_help; exit 0;;
    --rc) RC_BRANCH="${2:?branch}"; shift 2;;
    --message) TAG_MESSAGE="${2:?text}"; shift 2;;
    --remote) REMOTE="${2:?name}"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --update-pkg) UPDATE_PKG=true; shift;;
    --pkg) PKG_PATH="${2:?path}"; shift 2;;
    --no-commit) COMMIT_PKG=false; shift;;
    *) echo "Unknown arg: $1" >&2; echo "Run ./promote_rc.sh --help for usage."; exit 2;;
  esac
done

# --- Repo & cleanliness checks ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not a git repo" >&2; exit 1; }

# Stash any uncommitted changes before proceeding
STASHED=false
if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Stashing uncommitted changes..."
  if ! $DRY_RUN; then
    git stash push -u -m "promote_rc.sh temporary stash"
    STASHED=true
  fi
fi

# Determine RC branch
if [[ -z "${RC_BRANCH}" ]]; then
  echo "==> No --rc flag provided, finding latest RC branch..."
  RC_BRANCH="$(find_latest_rc)"

  if [[ -z "${RC_BRANCH}" ]]; then
    echo "ERROR: No RC branches found matching pattern release/X.Y.Z-rc.N" >&2
    exit 1
  fi

  echo "==> Found latest RC branch: ${RC_BRANCH}"
fi

# Validate RC branch naming
if [[ ! "${RC_BRANCH}" =~ ^release/[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
  echo "ERROR: branch '${RC_BRANCH}' must match pattern: release/X.Y.Z-rc.N" >&2
  exit 1
fi

VERSION_WITH_RC="${RC_BRANCH#release/}"     # 2.0.20-rc.3
VERSION="${VERSION_WITH_RC%%-rc.*}"         # 2.0.20
TAG="v${VERSION}"

echo "==> RC branch: ${RC_BRANCH}"
echo "==> Target Prod release tag: ${TAG}"

echo "==> Fetching refs..."
git_safe fetch --tags --prune "${REMOTE}" '+refs/heads/*:refs/remotes/'"${REMOTE}"'/*'

# Move to RC branch and ensure up-to-date
git_safe checkout -q "${RC_BRANCH}"
git_safe pull --ff-only

# Refuse to overwrite an existing tag
if git ls-remote --tags "${REMOTE}" | awk '{print $2}' | grep -qx "refs/tags/${TAG}"; then
  echo "ERROR: tag ${TAG} already exists on ${REMOTE}" >&2
  exit 1
fi

# Optional: update package.json on this RC branch to X.Y.Z
if $UPDATE_PKG; then
  if [[ ! -f "${PKG_PATH}" ]]; then
    echo "WARNING: --update-pkg specified but '${PKG_PATH}' not found. Skipping package.json update."
  else
    echo "==> Updating ${PKG_PATH} version -> ${VERSION}"
    NODE_SCRIPT="
      const fs = require('fs');
      const p = '${PKG_PATH}'.replace(/\\\\/g, '/');
      const j = JSON.parse(fs.readFileSync(p, 'utf8'));
      j.version = '${VERSION}';
      fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\\n');
    "
    if $DRY_RUN; then
      echo '(dry-run) node -e "<edit package.json>"'
    else
      node -e "${NODE_SCRIPT}"
    fi

    if $COMMIT_PKG; then
      echo "==> Committing ${PKG_PATH} change"
      git_safe add "${PKG_PATH}"
      git_safe commit -m "chore(version): set ${PKG_PATH} to ${VERSION} (promote to Prod)"
    else
      echo "NOTE: --no-commit used: ${PKG_PATH} modified but not committed."
    fi
  fi
fi

# Create annotated tag
if [[ -z "${TAG_MESSAGE}" ]]; then
  TAG_MESSAGE="Release ${TAG}"
fi

# Delete local tag if it exists
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "==> Deleting existing local tag ${TAG}"
  if $DRY_RUN; then
    echo "(dry-run) git tag -d ${TAG}"
  else
    git tag -d "${TAG}"
  fi
fi

echo "==> Tagging ${TAG} from $(git rev-parse --short HEAD)"
if $DRY_RUN; then
  echo "(dry-run) git tag -a ${TAG} -m \"${TAG_MESSAGE}\""
  echo "(dry-run) git push ${REMOTE} ${TAG}"
else
  git tag -a "${TAG}" -m "${TAG_MESSAGE}"
  git push "${REMOTE}" "${TAG}"
fi

# Create and publish GitHub Release
echo "==> Creating GitHub Release for ${TAG}"
if $DRY_RUN; then
  echo "(dry-run) gh release create ${TAG} --title \"${TAG_MESSAGE}\" --notes \"${TAG_MESSAGE}\""
else
  gh release create "${TAG}" --title "${TAG_MESSAGE}" --notes "${TAG_MESSAGE}" --verify-tag
fi

echo "==> Done. Pushed ${TAG} to ${REMOTE} and published GitHub Release."
if $DRY_RUN; then
  echo "NOTE: run without --dry-run to apply changes."
fi

# Restore stashed changes if any
if $STASHED; then
  echo "==> Restoring stashed changes..."
  git stash pop
fi
