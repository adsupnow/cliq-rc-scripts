#!/usr/bin/env bash
set -euo pipefail

# status_rc.sh
#
# Display current release management state including:
#   - Latest production release tag (vX.Y.Z)
#   - Active RC branches (release/X.Y.Z-rc.N)
#   - Commits since last release
#   - Recommended next action (cut_rc.sh or promote_rc.sh)
#
# See `./status_rc.sh --help` for usage.

REMOTE="origin"
VERBOSE=false
SHOW_COMMITS=false
MAX_COMMITS=10

print_help() {
  cat <<'EOF'
Usage: ./status_rc.sh [options]

Display the current state of release management.

Shows:
  - Latest production release tag (vX.Y.Z)
  - Active RC branches (release/X.Y.Z-rc.N)
  - Commits since last release (optional)
  - Recommended next action based on current state

Options:
  --remote <name>    Remote to check (default: origin)
  --verbose          Show additional details (author, commits ahead)
  --commits          Show commits since last release
  --max <n>          Max commits to show (default: 10)
  --help             Show this help message and exit

Examples:
  # Show basic status:
  ./status_rc.sh

  # Show status with recent commits:
  ./status_rc.sh --commits

  # Verbose mode with more details:
  ./status_rc.sh --verbose --commits --max 20

Workflow Integration:
  - Use this to check state before running cut_rc.sh or promote_rc.sh
  - Recommendations align with simplified cut_rc.sh and promote_rc.sh options
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
    --remote) REMOTE="${2:?name}"; shift 2;;
    --verbose) VERBOSE=true; shift;;
    --commits) SHOW_COMMITS=true; shift;;
    --max) MAX_COMMITS="${2:?number}"; shift 2;;
    *) echo "Unknown arg: $1" >&2; echo "Run ./status_rc.sh --help for usage."; exit 2;;
  esac
done

# --- Repo checks ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not a git repo" >&2; exit 1; }

echo "==> Fetching refs from ${REMOTE}..."
git fetch --tags --prune "${REMOTE}" '+refs/heads/*:refs/remotes/'"${REMOTE}"'/*' 2>/dev/null || true

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║               RELEASE MANAGEMENT STATUS                               ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""

# --- Latest Production Release ---
LATEST_TAG="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n1 || true)"
if [[ -n "${LATEST_TAG}" ]]; then
  PROD_VER="${LATEST_TAG#v}"
  TAG_DATE="$(git log -1 --format=%ai "${LATEST_TAG}" 2>/dev/null || echo "unknown")"
  TAG_AUTHOR="$(git log -1 --format=%an "${LATEST_TAG}" 2>/dev/null || echo "unknown")"
  TAG_SHA="$(git rev-parse --short "${LATEST_TAG}" 2>/dev/null || echo "unknown")"
  
  echo "📦 Latest Production Release: ${LATEST_TAG}"
  echo "   Version: ${PROD_VER}"
  echo "   Commit:  ${TAG_SHA}"
  echo "   Date:    ${TAG_DATE}"
  if $VERBOSE; then
    echo "   Author:  ${TAG_AUTHOR}"
    TAG_MSG="$(git tag -l --format='%(contents:subject)' "${LATEST_TAG}" 2>/dev/null || echo "")"
    [[ -n "${TAG_MSG}" ]] && echo "   Message: ${TAG_MSG}"
  fi
else
  echo "📦 Latest Production Release: (none found)"
  PROD_VER="0.0.0"
fi
echo ""

# --- Active RC Branches ---
echo "🔄 Active RC Branches:"
RC_BRANCHES="$(git ls-remote --heads "${REMOTE}" 'release/*-rc.*' 2>/dev/null || true)"

if [[ -z "${RC_BRANCHES}" ]]; then
  echo "   (no active RC branches)"
else
  # Build a list of version:rc_num pairs and find highest RC per version
  # Using bash 3.2 compatible approach (no associative arrays)
  RC_LIST=""
  while read -r sha ref; do
    branch_name="${ref#refs/heads/}"
    version_with_rc="${branch_name#release/}"
    version="${version_with_rc%%-rc.*}"
    rc_num="${version_with_rc##*-rc.}"
    RC_LIST="${RC_LIST}${version}:${rc_num}"$'\n'
  done <<< "${RC_BRANCHES}"
  
  # Get unique versions and find highest RC for each
  VERSIONS="$(echo "${RC_LIST}" | cut -d: -f1 | sort -u -t. -k1,1n -k2,2n -k3,3n)"
  
  # Display grouped results
  for version in ${VERSIONS}; do
    # Find highest RC number for this version
    max_rc=0
    while IFS=: read -r v rc; do
      if [[ "${v}" == "${version}" ]] && [[ "${rc}" =~ ^[0-9]+$ ]] && (( rc > max_rc )); then
        max_rc="${rc}"
      fi
    done <<< "${RC_LIST}"
    
    if (( max_rc > 0 )); then
      branch_name="release/${version}-rc.${max_rc}"
      
      # Get branch details
      branch_sha="$(git rev-parse --short "${REMOTE}/${branch_name}" 2>/dev/null || echo "unknown")"
      branch_date="$(git log -1 --format=%ai "${REMOTE}/${branch_name}" 2>/dev/null || echo "unknown")"
      
      echo "   • ${branch_name}"
      echo "     Commit: ${branch_sha}"
      echo "     Date:   ${branch_date}"
      
      if $VERBOSE; then
        branch_author="$(git log -1 --format=%an "${REMOTE}/${branch_name}" 2>/dev/null || echo "unknown")"
        echo "     Author: ${branch_author}"
        
        # Show how many commits ahead of production
        if [[ -n "${LATEST_TAG}" ]]; then
          ahead_count="$(git rev-list --count "${LATEST_TAG}..${REMOTE}/${branch_name}" 2>/dev/null || echo "?")"
          echo "     Commits ahead of ${LATEST_TAG}: ${ahead_count}"
        fi
      fi
      echo ""
    fi
  done
fi

# --- Commits Since Last Release ---
if $SHOW_COMMITS && [[ -n "${LATEST_TAG}" ]]; then
  echo "📝 Commits Since ${LATEST_TAG} (on ${REMOTE}/main):"
  
  COMMIT_COUNT="$(git rev-list --count "${LATEST_TAG}..${REMOTE}/main" 2>/dev/null || echo "0")"
  
  if [[ "${COMMIT_COUNT}" -eq 0 ]]; then
    echo "   (no new commits)"
  else
    echo "   Total: ${COMMIT_COUNT} commits"
    echo ""
    
    git log "${LATEST_TAG}..${REMOTE}/main" \
      --format="   %C(yellow)%h%C(reset) %C(cyan)%ad%C(reset) %C(green)%an%C(reset) %s" \
      --date=short \
      --max-count="${MAX_COMMITS}" 2>/dev/null || echo "   (error reading commits)"
    
    if (( COMMIT_COUNT > MAX_COMMITS )); then
      echo ""
      echo "   ... and $((COMMIT_COUNT - MAX_COMMITS)) more commits"
      echo "   (use --max <n> to show more)"
    fi
  fi
  echo ""
fi

# --- Current Branch Info ---
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
echo "🌿 Current Branch: ${CURRENT_BRANCH}"

if [[ "${CURRENT_BRANCH}" =~ ^release/[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
  echo "   ℹ️  You are on an RC branch"
fi
echo ""

# --- Recommended Next Action ---
echo "💡 Recommended Next Action:"

# Determine state and recommendation
if [[ -z "${RC_BRANCHES}" ]]; then
  # No active RCs
  if [[ -n "${LATEST_TAG}" ]]; then
    if $SHOW_COMMITS; then
      COMMIT_COUNT="$(git rev-list --count "${LATEST_TAG}..${REMOTE}/main" 2>/dev/null || echo "0")"
      if [[ "${COMMIT_COUNT}" -gt 0 ]]; then
        echo "   → Start new RC train (preview changes):"
        echo "     ./cut_rc.sh --version \$(node -p \"require('./package.json').version\") --replace --dry-run"
        echo ""
        echo "   → Start new RC train (creates release/X.Y.Z-rc.0):"
        echo "     ./cut_rc.sh --version \$(node -p \"require('./package.json').version\") --replace"
      else
        echo "   → No new commits since last release. No action needed."
      fi
    else
      echo "   → Check if there are commits to release: ./status_rc.sh --commits"
      echo ""
      echo "   → Start new RC train (preview changes):"
      echo "     ./cut_rc.sh --version \$(node -p \"require('./package.json').version\") --replace --dry-run"
      echo ""
      echo "   → Start new RC train (creates release/X.Y.Z-rc.0):"
      echo "     ./cut_rc.sh --version \$(node -p \"require('./package.json').version\") --replace"
    fi
  else
    echo "   → No production releases yet. Initialize version in package.json and create first RC:"
    echo "     ./cut_rc.sh --version 1.0.0 --replace"
  fi
else
  # Active RCs exist - find highest version and RC
  HIGHEST_VERSION="$(echo "${VERSIONS}" | tail -1)"
  HIGHEST_RC=0
  
  # Find highest RC for the highest version
  while IFS=: read -r v rc; do
    if [[ "${v}" == "${HIGHEST_VERSION}" ]] && [[ "${rc}" =~ ^[0-9]+$ ]] && (( rc > HIGHEST_RC )); then
      HIGHEST_RC="${rc}"
    fi
  done <<< "${RC_LIST}"
  
  if (( HIGHEST_RC >= 0 )); then
    HIGHEST_BRANCH="release/${HIGHEST_VERSION}-rc.${HIGHEST_RC}"
    echo "   → Test ${HIGHEST_BRANCH} in staging environment"
    echo ""
    echo "   → If tests pass, promote to production:"
    echo "     ./promote_rc.sh --rc ${HIGHEST_BRANCH}"
    echo "     # Creates tag v${HIGHEST_VERSION} and GitHub Release (triggers prod deployment)"
    echo ""
    echo "   → If fixes needed, commit changes to main, then advance RC:"
    echo "     ./cut_rc.sh --replace"
    echo "     # Creates ${HIGHEST_BRANCH%.*}.$((HIGHEST_RC + 1)) and deletes ${HIGHEST_BRANCH}"
  fi
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║ For more details, see: docs/rc-release-scripts.md                    ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
