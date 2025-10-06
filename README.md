# RC Release Management Scripts

This repository contains automated scripts for managing release candidates (RC) in a hybrid development workflow. The scripts support two distinct lifecycles: **Normal Development** (hybrid automation) and **Hotfix** (manual process).

## Table of Contents
- [🚀 Normal Development Lifecycle](#-normal-development-lifecycle)
- [🔧 Hotfix Lifecycle](#-hotfix-lifecycle)
- [🎯 Key Insights](#-key-insights)
- [Scripts Overview](#scripts-overview)
- [Setup](#setup)
- [Script Documentation](#script-documentation)
- [Workflow Examples](#workflow-examples)
- [Troubleshooting](#troubleshooting)
- [CI/CD Integration](./docs/ci-cd-integration.md)

---

## 🚀 Normal Development Lifecycle
*Starting from production tag creation*

📊 **[View Interactive Flow Diagram →](./docs/normal-development-flow.md)**

### 1. Production Release Milestone
✅ **Production tag created** (e.g., `v2.11.0`) from latest RC  
✅ **Production workflow triggers**: Deploy + bump main to next minor (`2.12.0`)  
✅ **Main becomes**: The starting point for next development cycle  

### 2. New Development Train Starts
🔧 **Engineer runs**: `../cliq-rc-scripts/cut_rc.sh --version 2.12.0 --replace`  
🔧 **Or similarly grabbing the latest/recent bumped version**: `../cliq-rc-scripts/cut_rc.sh --version $(node -p "require('./package.json').version") --replace`  
✅ **New RC created**: `release/2.12.0-rc.0` (first staging snapshot)  
✅ **Development begins**: Feature branches cut from main  

### 3. Active Development Phase
👥 **Engineers create**: Feature branches from main (`feature/EN-1234-cool-thing`)  
📝 **Work flows through**: PRs back to main  
🔄 **Each main merge**: Triggers staging → continues RC train (`rc.0` → `rc.1` → `rc.2`...)  
🧪 **Each RC deployment**: Tests the cumulative changes on staging  

### 4. Ready for Next Release
✅ **Latest RC**: Contains all merged features (e.g., `release/2.12.0-rc.8`)  
🚀 **Engineer promotes**: `../cliq-rc-scripts/promote_rc.sh` → creates `v2.12.0` tag  
🔄 **Cycle repeats**: Back to step 1 with `2.13.0`  

---

## 🔧 Hotfix Lifecycle
*Starting with cutting hotfix branch*

📊 **[View Interactive Flow Diagram →](./docs/hotfix-lifecycle-flow.md)**

### 1. Production Issue Identified
🚨 **Critical bug found** in production `v2.11.0`  
📍 **Current state**: Main is ahead at `2.12.0-rc.5`, production is behind  

### 2. Hotfix Branch Creation
🔧 **Engineer cuts**: `git checkout -b hotfix/critical-bug v2.11.0` (from production tag)  
🛠️ **Fix applied**: Minimal change to address the issue  
📦 **Version bumped**: `package.json` → `2.11.1` (patch increment)  

### 3. Hotfix Release
🏷️ **Tag created**: `v2.11.1` from hotfix branch  
🚀 **Production deploys**: Hotfix goes live immediately  
✅ **Production workflow**: Detects hotfix → deploys only (no RC train changes)  

### 4. Integration Back to Main
📝 **Engineer creates PR**: Merge `hotfix/critical-bug` → `main`  
👀 **Team reviews**: Visible integration of production fix  
✅ **PR merged**: Hotfix code now in main alongside ongoing development  

### 5. Staging Picks Up Hotfix
🔄 **Staging workflow**: Triggered by main merge  
📦 **Continues RC**: `release/2.12.0-rc.5` → `release/2.12.0-rc.6` (now includes hotfix)  
🧪 **Staging testing**: Validates hotfix works with new features  

---

## 🎯 Key Insights

### Normal Development:
- **Linear progression**: Each cycle builds on the last  
- **Predictable**: Version bumps and RC creation follow pattern  
- **Collaborative**: Multiple features flow through main  

### Hotfix Process:
- **Branch from production**: Not from main (which may be ahead)  
- **Manual integration**: Visible via PR process for team awareness  
- **Non-disruptive**: Doesn't interfere with ongoing development train  
- **Eventually consistent**: Hotfix gets into next release automatically  

---

## Scripts Overview

The release management workflow consists of three main scripts that support both normal development and hotfix processes:

1. **`cut_rc.sh`** - Creates or advances release candidate branches
2. **`promote_rc.sh`** - Promotes an RC branch to a production release tag  
3. **`status_rc.sh`** - Shows current release state and recommends next actions

These scripts enforce a structured release workflow:
- Development happens on `main`
- Release candidates are cut to `release/X.Y.Z-rc.N` branches
- After testing, RCs are promoted to production tags `vX.Y.Z`
- Hotfixes branch from production tags and integrate back to main

---

## Setup

### Making Scripts Executable

Before you can run these scripts from anywhere in your filesystem, you need to make them executable:

```bash
git clone git@github.com:adsupnow/cliq-rc-scripts.git
```

```bash
chmod +x ../cliq-rc-scripts/scripts/cut_rc.sh
chmod +x ../cliq-rc-scripts/promote_rc.sh  
chmod +x ../cliq-rc-scripts/status_rc.sh
```

Or to make all scripts in the directory executable at once:

```bash
chmod +x ../cliq-rc-scripts/scripts/*.sh
```

---

## Script Documentation
**Used in the staging and prod github actions or by the engineer managing the production release or hotfix.**

### cut_rc.sh

**Purpose**: Creates or advances release candidate branches from the main branch.

**Usage**:
```bash
./cut_rc.sh [options]
```

**Key Options**:
- `--version X.Y.Z` - Force specific target version  
- `--bump <patch|minor|major>` - Start a new train with semantic version bump  
- `--base <ref>` - Base ref for cutting RC (default: `origin/main`)  
- `--replace` - Delete previous RC branch for the same version  
- `--dry-run` - Preview actions without making changes  

**Examples**:
```bash
# Start new development cycle after production release
./cut_rc.sh --version 2.12.0 --replace

# Continue existing RC train (rc.0 → rc.1 → rc.2...)  
./cut_rc.sh --replace
```

### promote_rc.sh

**Purpose**: Promotes a tested release candidate branch to a production release tag.

**Usage**:
```bash
./promote_rc.sh [options]
```

**Key Options**:
- `--rc <branch>` - RC branch to promote (defaults to current branch)  
- `--message "<text>"` - Custom annotated tag message  
- `--dry-run` - Preview actions without making changes  

**Examples**:
```bash
# Promote latest RC to production
./promote_rc.sh

# Promote specific RC branch  
./promote_rc.sh --rc release/2.12.0-rc.8

# Promote with custom message
./promote_rc.sh --message "Release v2.12.0 - New features and bug fixes"
```

### status_rc.sh

**Purpose**: Displays the current state of release management and provides intelligent recommendations.

**Usage**:
```bash
./status_rc.sh [options]
```

**Key Options**:
- `--commits` - Show commits since last release  
- `--verbose` - Show additional details like authors and commit counts  
- `--max <n>` - Maximum commits to display (default: 10)  

**Examples**:
```bash
# Check current release state
./status_rc.sh

# See what commits are ready for next release  
./status_rc.sh --commits

# Detailed status for team reviews
./status_rc.sh --verbose --commits --max 20
```

---

## Workflow Examples

### Normal Development Lifecycle Example

#### Starting New Development Cycle (After Production Release)
```bash
# Production v2.11.0 was just released
# Main gets bumped to 2.12.0 (automated)
./cut_rc.sh --version 2.12.0 --replace
# Creates: release/2.12.0-rc.0
```

#### Active Development Phase  
```bash
# Engineer merges feature PR to main
# Staging needs latest changes
./cut_rc.sh --replace  
# Creates: release/2.12.0-rc.1 (deletes rc.0)

# Another feature merged
./cut_rc.sh --replace
# Creates: release/2.12.0-rc.2 (deletes rc.1)

# Continue until ready for production...
./cut_rc.sh --replace  
# Creates: release/2.12.0-rc.8 (deletes rc.7)
```

#### Ready for Production
```bash
# All tests pass on release/2.12.0-rc.8
./promote_rc.sh
# Creates: v2.12.0 production tag
# Cycle repeats with 2.13.0
```

### Hotfix Lifecycle Example

#### Critical Bug in Production
```bash
# Production is on v2.11.0, main is ahead with 2.12.0-rc.5
git checkout -b hotfix/critical-security-fix v2.11.0
# Apply minimal fix
# Update patch in package.json to 2.11.1
git commit -am "fix: critical security vulnerability"
git push origin hotfix/critical-security-fix
```

#### Release Hotfix
```bash
# Create hotfix RC
./cut_rc.sh --base hotfix/critical-security-fix --version 2.11.1 --replace

# Creates: release/2.11.1-rc.0

# Promote immediately after testing
./promote_rc.sh  
# Creates: v2.11.1 (production deploys this)
```

#### Integrate Back to Main
```bash
# Create PR: hotfix/critical-security-fix → main
# Team reviews and merges

# Staging automatically picks up hotfix in next RC
./cut_rc.sh --replace
# Creates: release/2.12.0-rc.6 (includes hotfix + ongoing features)
```

### Using status_rc.sh for Decision Making

```bash  
# Check current state before any action
./status_rc.sh --commits

# Example output guides next steps:
# Latest Production: v2.11.0
# Active RC: release/2.12.0-rc.5  
# Commits since v2.11.0: 25 commits
# Recommendation: Test RC or continue development
```

---



## Troubleshooting

### Common Issues

**Working Tree Not Clean**
```bash
# Error: working tree not clean
git status
git stash  # or commit your changes
```

**Tag Already Exists**  
```bash
# Error: tag vX.Y.Z already exists
# Could be a failed promotion or the version was already released

# If promotion failed, delete the tag and retry:
git tag -d v2.10.0                    # delete local tag
git push origin :refs/tags/v2.10.0    # delete remote tag
# Fix any issues in RC, then re-run:
./promote_rc.sh

# If version was already released, continue RC train or start new version:
./cut_rc.sh --replace  # continue current train
# or 
./cut_rc.sh --version X.Y.Z+1 --replace  # start new version
```

**Wrong Branch for Promotion**
```bash
# Error: branch 'xxx' must match pattern: release/X.Y.Z-rc.N  
git checkout release/2.12.0-rc.8  # switch to correct RC branch
./promote_rc.sh
```

### Recovery Commands

**Undo RC Branch (if not yet promoted)**
```bash
git push origin :release/X.Y.Z-rc.N  # delete remote branch
git branch -D release/X.Y.Z-rc.N     # delete local branch
```

**Undo Production Tag (⚠️ coordinate with team first)**
```bash
git push origin :refs/tags/vX.Y.Z    # delete remote tag  
git tag -d vX.Y.Z                    # delete local tag
```

**Check Current State**
```bash
./status_rc.sh --commits              # see what's ready for release
git tag -l 'v*' --sort=-version:refname | head -5  # recent production tags
```

### Best Practices

- Always use `--dry-run` first when learning the scripts
- Use `./status_rc.sh` before taking any action
- Coordinate with team - only one person should manage releases at a time  
- Use `--replace` to keep branch history clean
- Test RCs thoroughly before promoting to production

---

