# Staging Build Trigger Fix

## The Problem

When manually running `cut_rc.sh` to create an RC branch locally (e.g., after a production release), the new RC branch was created successfully but **no staging build was triggered**.

### Why It Happened

The staging workflow was only configured to trigger on pushes to `main`:

```yaml
on:
  push:
    branches:
      - main
```

So when you pushed an RC branch directly, GitHub Actions didn't respond.

## The Solution

Add RC branch pattern to the staging workflow trigger:

```yaml
on:
  push:
    branches:
      - main
      - 'release/*-rc.*'  # ← Add this line
```

## How It Works

### Scenario 1: Push to main (existing behavior)
```bash
# Engineer merges PR to main
git push origin main

# GitHub Actions:
# 1. Continue-RC-Train job runs (if: github.ref == 'refs/heads/main')
# 2. Calls cut_rc.sh --replace
# 3. Creates new RC branch
# 4. Build job builds that RC
# 5. Deploy job deploys it
```

### Scenario 2: Push RC branch directly (NEW - fixes your issue!)
```bash
# After production release, you manually run:
./cut_rc.sh --version $(node -p "require('./package.json').version") --replace

# This pushes release/2.13.0-rc.0
# GitHub Actions:
# 1. Continue-RC-Train job is skipped (not main branch)
# 2. Build job runs (always() allows it to run when previous job is skipped)
# 3. Build job detects it's an RC branch and builds it directly
# 4. Deploy job deploys it
# ✅ Build triggers correctly!
```

## Implementation

### In your application repository's `.github/workflows/deploy-staging.yml`:

```yaml
on:
    push:
        branches:
            - main
            - 'release/*-rc.*'  # Add this line
```

That's it! No other changes needed. Your existing workflow logic already handles both scenarios correctly:

```yaml
- name: Determine branch to build
  id: branch
  run: |
    if [ "${{ github.ref }}" == "refs/heads/main" ]; then
      echo "ref=${{ needs.Continue-RC-Train.outputs.rc_branch }}" >> $GITHUB_OUTPUT
    else
      echo "ref=${{ github.ref_name }}" >> $GITHUB_OUTPUT  # ← Uses the RC branch directly
    fi
```

## Complete Workflow

### Normal Development
1. Engineers merge features to main
2. Main push → staging workflow → `cut_rc.sh --replace` → builds RC automatically
3. RC branches progress: rc.1, rc.2, rc.3...

### After Production Release
1. Production workflow deploys and bumps main version
2. You run: `./cut_rc.sh --version $(node -p "require('./package.json').version") --replace`
3. RC branch push → staging workflow → builds RC automatically ✅
4. Next development cycle is ready!

### Hotfix Process
1. Cut hotfix from production tag, fix bug, tag and publish
2. Production deploys (with improved hotfix detection)
3. Merge hotfix to main → triggers staging → continues RC train
4. Hotfix is in next release

## Bonus: Improved Hotfix Detection

Also update your production workflow's hotfix detection to handle cases where main is ahead:

```yaml
# Detect hotfix: release version is LESS than current main version
if [[ "$RELEASE_MAJOR" -lt "$CURRENT_MAJOR" ]] || \
   [[ "$RELEASE_MAJOR" -eq "$CURRENT_MAJOR" && "$RELEASE_MINOR" -lt "$CURRENT_MINOR" ]] || \
   [[ "$RELEASE_MAJOR" -eq "$CURRENT_MAJOR" && "$RELEASE_MINOR" -eq "$CURRENT_MINOR" && "$RELEASE_PATCH" -lt "$CURRENT_PATCH" ]]; then
  echo "is_hotfix=true" >> $GITHUB_OUTPUT
  echo "🔧 Detected hotfix release (v$RELEASE_VERSION is behind main v$CURRENT_VERSION)"
else
  echo "is_hotfix=false" >> $GITHUB_OUTPUT
  echo "🚀 Detected normal release - will bump main version"
fi
```

This correctly identifies hotfixes even when main has moved ahead to the next minor version.

## Summary

**One line change** to your staging workflow fixes the manual RC creation build trigger issue:

```diff
on:
    push:
        branches:
            - main
+           - 'release/*-rc.*'
```

Simple, effective, and maintains all existing workflow behavior! 🎉
