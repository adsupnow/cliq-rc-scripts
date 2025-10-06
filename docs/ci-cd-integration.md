# CI/CD Integration Guide

This guide explains how to integrate the RC branching scripts into your CI/CD pipelines across multiple repositories using the download-on-demand approach.

## Table of Contents
- [Overview](#overview)
- [GitHub Actions Prod Integration](#github-actions-prod-integration)
- [GitHub Actions Staging Integration](#github-actions-staging-integration)

---

## Overview

The RC scripts (`cut_rc.sh`, `promote_rc.sh`, `status_rc.sh`) are integrated into CI/CD pipelines by downloading them on-demand during workflow execution. This ensures you always use the latest version while keeping repositories clean.

**Implementation:**
- Scripts are downloaded from the cliq-rc-scripts public repo during GitHub Actions workflows
- Production deployment automatically starts new RC trains with minor version bumps
- Staging deployment automatically continues existing RC trains

---

**Implementation:**
```yaml
- name: Download RC scripts
  run: |
    mkdir -p cicd_rc_scripts
    curl -sL https://raw.githubusercontent.com/adsupnow/cliq-rc-scripts/main/scripts/cut_rc.sh -o cicd_rc_scripts/cut_rc.sh
    curl -sL https://raw.githubusercontent.com/adsupnow/cliq-rc-scripts/main/scripts/status_rc.sh -o cicd_rc_scripts/status_rc.sh
    chmod +x cicd_rc_scripts/*.sh
```

> **Note**: If the xperience repository is private, you must include the `Authorization` header with a GitHub token that has access to the repository.

---
## Github Actions Prod Integration
### Example

This example shows a production deployment workflow that automatically starts a new RC train after successful deployment.

Create `.github/workflows/deploy-prod.yml` in your target repository:

```yaml
name: Ad Broker API Production Deployment

run-name: "${{ format('🎉 Production Deploy - {0}', github.ref_name) }}"

on:
    release:
        types: [published]

jobs:
    Build:
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v4

            - name: Set up Docker Buildx
              uses: docker/setup-buildx-action@v3

            - id: auth_prod
              name: Log in to Google Cloud
              uses: google-github-actions/auth@v2
              with:
                project_id: 'xperience-prod'
                credentials_json: ${{ secrets.XPERIENCE_PROD_SERVICE_ACCOUNT }}

            - id: grc_login_prod
              name: Login to gcr.io
              uses: docker/login-action@v3
              with:
                registry: gcr.io
                username: _json_key
                password: ${{ secrets.XPERIENCE_PROD_SERVICE_ACCOUNT }}

            - name: Build Docker image
              run: |
                docker build -f Dockerfile.cloudrun -t gcr.io/xperience-prod/xperience-adbroker:${{ github.sha }} .

            - name: Push Docker image to GCR
              run: |
                docker push gcr.io/xperience-prod/xperience-adbroker:${{ github.sha }}

    Database-Migrate:
      needs: Build
      runs-on: ubuntu-latest

      steps:
        - uses: actions/checkout@v4

        - uses: mattes/gce-cloudsql-proxy-action@v1
          with:
            creds: ${{ secrets.XPERIENCE_PROD_SERVICE_ACCOUNT }}
            instance: xperience-prod:us-central1:data-hub
            port: 3306

        - name: Setup Node.js environment
          uses: actions/setup-node@v3
          with:
            node-version: 22

        - id: auth_prod
          name: Authenticate to Google Cloud
          uses: google-github-actions/auth@v2
          with:
            credentials_json: '${{ secrets.XPERIENCE_PROD_SERVICE_ACCOUNT }}'

        - id: 'secrets'
          uses: 'google-github-actions/get-secretmanager-secrets@v2'
          with:
            secrets: |-
              token:xperience-prod/xperience-data-hub-db-password

        - name: 'Migrate database'
          run: npx prisma migrate deploy
          env:
            DATABASE_URL: mysql://root:${{ steps.secrets.outputs.token }}@localhost:3306/adbroker

    Deploy:
        needs: Database-Migrate
        runs-on: ubuntu-latest
        steps:
            - id: auth_prod
              name: Log in to Google Cloud
              uses: google-github-actions/auth@v2
              with:
                project_id: 'xperience-prod'
                credentials_json: ${{ secrets.XPERIENCE_PROD_SERVICE_ACCOUNT }}

            - name: Deploy to Cloud Run
              uses: 'google-github-actions/deploy-cloudrun@v2'
              with:
                service: xperience-adbroker
                project_id: xperience-prod
                image: gcr.io/xperience-prod/xperience-adbroker:${{ github.sha }}

    Start-New-RC-Train:
        needs: Deploy
        runs-on: ubuntu-latest

        permissions:
            contents: write

        steps:
            - name: Checkout repository
              uses: actions/checkout@v4
              with:
                fetch-depth: 0
                token: ${{ secrets.CI_PAT }}

            - name: Determine if this is a hotfix release
              id: release_type
              run: |
                RELEASE_TAG="${{ github.event.release.tag_name }}"
                echo "Release tag: $RELEASE_TAG"

                # Get current version from package.json
                CURRENT_VERSION=$(node -p "require('./package.json').version")
                echo "Current package.json version: $CURRENT_VERSION"

                # Remove 'v' prefix from tag if present
                RELEASE_VERSION=${RELEASE_TAG#v}
                echo "Release version (cleaned): $RELEASE_VERSION"

                # Parse semantic versions (X.Y.Z)
                IFS='.' read -r CURRENT_MAJOR CURRENT_MINOR CURRENT_PATCH <<< "$CURRENT_VERSION"
                IFS='.' read -r RELEASE_MAJOR RELEASE_MINOR RELEASE_PATCH <<< "$RELEASE_VERSION"

                # Detect hotfix: same major.minor but patch is incremented
                if [[ "$RELEASE_MAJOR" == "$CURRENT_MAJOR" && "$RELEASE_MINOR" == "$CURRENT_MINOR" && "$RELEASE_PATCH" -gt "$CURRENT_PATCH" ]]; then
                  echo "is_hotfix=true" >> $GITHUB_OUTPUT
                  echo "🔧 Detected hotfix release - no RC train action needed"
                else
                  echo "is_hotfix=false" >> $GITHUB_OUTPUT
                  echo "🚀 Detected normal release - will start new RC train"
                fi

            - name: Download RC scripts
              if: steps.release_type.outputs.is_hotfix == 'false'
              run: |
                mkdir -p cicd_rc_scripts
                curl -sL https://raw.githubusercontent.com/adsupnow/cliq-rc-scripts/main/scripts/cut_rc.sh -o cicd_rc_scripts/cut_rc.sh
                curl -sL https://raw.githubusercontent.com/adsupnow/cliq-rc-scripts/main/scripts/status_rc.sh -o cicd_rc_scripts/status_rc.sh
                chmod +x cicd_rc_scripts/*.sh

            - name: Configure Git
              if: steps.release_type.outputs.is_hotfix == 'false'
              run: |
                git config user.name "github-actions[bot]"
                git config user.email "github-actions[bot]@users.noreply.github.com"

            - name: Setup Node.js
              if: steps.release_type.outputs.is_hotfix == 'false'
              uses: actions/setup-node@v4
              with:
                node-version: '22'

            - name: Update package.json on main and start new RC train (normal releases only)
              if: steps.release_type.outputs.is_hotfix == 'false'
              run: |
                echo "Updating package.json on main branch with minor version bump"

                # Checkout main branch (we're currently on detached HEAD from the release tag)
                echo "Checking out main branch..."
                git checkout main
                git pull origin main

                # Get current version and bump minor
                CURRENT_VERSION=$(node -p "require('./package.json').version")
                echo "Current version: $CURRENT_VERSION"

                # Bump minor version
                npm version minor --no-git-tag-version
                NEW_VERSION=$(node -p "require('./package.json').version")
                echo "New version: $NEW_VERSION"

                # Commit and push to main
                git add package.json
                git commit -m "chore: bump minor version to $NEW_VERSION after production release"
                git push origin main

                echo "✅ Version bump complete. Ready for new RC train."
                echo ""
                echo "🔧 Next step: Create new RC train manually:"
                echo "   ./cut_rc.sh --version $NEW_VERSION --replace"

            - name: Post summary
              if: success()
              run: |
                if [[ "${{ steps.release_type.outputs.is_hotfix }}" == "true" ]]; then
                  echo "## 🔧 Hotfix Release Deployed" >> $GITHUB_STEP_SUMMARY
                  echo "" >> $GITHUB_STEP_SUMMARY
                  echo "**Release Type:** Hotfix" >> $GITHUB_STEP_SUMMARY
                  echo "**Action:** Deploy only - no RC train changes" >> $GITHUB_STEP_SUMMARY
                  echo "" >> $GITHUB_STEP_SUMMARY
                  echo "ℹ️ **Next Step:** Release engineer should manually merge hotfix branch into main" >> $GITHUB_STEP_SUMMARY
                else
                  echo "## ✅ Production Release Complete" >> $GITHUB_STEP_SUMMARY
                  echo "" >> $GITHUB_STEP_SUMMARY
                  echo "**Release Type:** Normal" >> $GITHUB_STEP_SUMMARY
                  echo "**Action:** Version bumped to \`$(node -p "require('./package.json').version")\` on main" >> $GITHUB_STEP_SUMMARY
                  echo "" >> $GITHUB_STEP_SUMMARY
                  echo "### 🔧 Next Step: Create New RC Train" >> $GITHUB_STEP_SUMMARY
                  echo "" >> $GITHUB_STEP_SUMMARY
                  echo "Run this command to start the new development train:" >> $GITHUB_STEP_SUMMARY
                  echo "" >> $GITHUB_STEP_SUMMARY
                  echo "\`\`\`bash" >> $GITHUB_STEP_SUMMARY
                  echo "./cut_rc.sh --version $(node -p "require('./package.json').version") --replace" >> $GITHUB_STEP_SUMMARY
                  echo "\`\`\`" >> $GITHUB_STEP_SUMMARY
                fi
```

## Github Actions Staging Integration
### Example

This example shows a staging deployment workflow that automatically continues the RC train after successful deployment to staging.

Create `.github/workflows/deploy-staging.yml` in your target repository:

```yaml
name: Ad Broker API Staging Deployment

run-name: "${{ github.ref == 'refs/heads/main' && '🚀 Staging Deploy - auto rc++' || format('🚀 Staging Deploy - {0}', github.ref_name) }}"

on:
    push:
        branches:
            - main

jobs:
    Continue-RC-Train:
        runs-on: ubuntu-latest
        if: github.ref == 'refs/heads/main'

        permissions:
            contents: write

        outputs:
            rc_branch: ${{ steps.rc_train.outputs.branch }}

        steps:
            - name: Checkout repository
              uses: actions/checkout@v4
              with:
                fetch-depth: 0
                token: ${{ secrets.GITHUB_TOKEN }}

            - name: Configure Git
              run: |
                git config user.name "github-actions[bot]"
                git config user.email "github-actions[bot]@users.noreply.github.com"

            - name: Download RC scripts
              run: |
                mkdir -p cicd_rc_scripts
                curl -sL https://raw.githubusercontent.com/adsupnow/cliq-rc-scripts/main/scripts/cut_rc.sh -o cicd_rc_scripts/cut_rc.sh
                curl -sL https://raw.githubusercontent.com/adsupnow/cliq-rc-scripts/main/scripts/status_rc.sh -o cicd_rc_scripts/status_rc.sh
                chmod +x cicd_rc_scripts/*.sh

                # Patch the script to skip the working tree check in CI/CD
                sed -i 's/\[\[ -z "$(git status --porcelain)" \]\] || { echo "ERROR: working tree not clean" >&2; exit 1; }/# CI\/CD: Skip working tree check/' cicd_rc_scripts/cut_rc.sh

                # Fix the DRY_RUN bug if it exists in the public repo
                sed -i 's/\$DRY_RUN && echo "NOTE: run without --dry-run to apply changes\."/if \$DRY_RUN; then\n  echo "NOTE: run without --dry-run to apply changes\."\nfi/' cicd_rc_scripts/cut_rc.sh

            - name: Setup Node.js
              uses: actions/setup-node@v4
              with:
                node-version: '22'

            - name: Continue RC train
              id: rc_train
              run: |
                set +e  # Disable exit on error for this entire step
                echo "📦 Continuing existing RC train"
                OUTPUT=$(./cicd_rc_scripts/cut_rc.sh --replace 2>&1)
                EXIT_CODE=$?

                echo "$OUTPUT"

                if [ $EXIT_CODE -ne 0 ]; then
                  echo "ERROR: cut_rc.sh failed with exit code $EXIT_CODE"
                  exit $EXIT_CODE
                fi                # Extract the branch name from the output
                RC_BRANCH=$(echo "$OUTPUT" | grep "==> Done. RC branch is" | sed 's/.*RC branch is //' | xargs)

                if [ -z "$RC_BRANCH" ]; then
                  echo "ERROR: Could not determine RC branch from script output"
                  echo "Output was:"
                  echo "$OUTPUT"
                  exit 1
                fi

                echo "branch=$RC_BRANCH" >> $GITHUB_OUTPUT
                echo "Created RC branch: $RC_BRANCH"

                exit 0  # Explicitly exit with success

            - name: Post summary
              if: success()
              run: |
                echo "## ✅ RC Train Continued" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "**New RC branch created:** \`${{ steps.rc_train.outputs.branch }}\`" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "This RC branch will be built and deployed to staging." >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                ./cicd_rc_scripts/status_rc.sh >> $GITHUB_STEP_SUMMARY

    Build:
        needs: [Continue-RC-Train]
        if: always() && (needs.Continue-RC-Train.result == 'success' || needs.Continue-RC-Train.result == 'skipped')
        runs-on: ubuntu-latest

        outputs:
            image_sha: ${{ steps.get_sha.outputs.sha }}

        steps:
            - name: Determine branch to build
              id: branch
              run: |
                if [ "${{ github.ref }}" == "refs/heads/main" ]; then
                  echo "ref=${{ needs.Continue-RC-Train.outputs.rc_branch }}" >> $GITHUB_OUTPUT
                else
                  echo "ref=${{ github.ref_name }}" >> $GITHUB_OUTPUT
                fi

            - uses: actions/checkout@v4
              with:
                ref: ${{ steps.branch.outputs.ref }}

            - name: Get commit SHA
              id: get_sha
              run: |
                SHA=$(git rev-parse HEAD)
                BRANCH="${{ steps.branch.outputs.ref }}"
                echo "sha=$SHA" >> $GITHUB_OUTPUT
                echo "🔨 Building branch: $BRANCH"
                echo "📝 Commit SHA: $SHA"

            - name: Set up Docker Buildx
              uses: docker/setup-buildx-action@v3

            - id: auth_staging
              name: Log in to Google Cloud
              uses: google-github-actions/auth@v2
              with:
                project_id: 'xperience-staging'
                credentials_json: ${{ secrets.XPERIENCE_STAGING_SERVICE_ACCOUNT }}

            - id: grc_login_staging
              name: Login to gcr.io
              uses: docker/login-action@v3
              with:
                registry: gcr.io
                username: _json_key
                password: ${{ secrets.XPERIENCE_STAGING_SERVICE_ACCOUNT }}

            - name: Build Docker image
              run: |
                docker build -f Dockerfile.cloudrun -t gcr.io/xperience-staging/xperience-adbroker:${{ steps.get_sha.outputs.sha }} .

            - name: Push Docker image to GCR
              run: |
                docker push gcr.io/xperience-staging/xperience-adbroker:${{ steps.get_sha.outputs.sha }}

            - name: Post build summary
              if: success()
              run: |
                echo "## 🔨 Build Complete" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                if [ "${{ github.ref }}" == "refs/heads/main" ]; then
                  echo "**Branch Built:** \`${{ needs.Continue-RC-Train.outputs.rc_branch }}\`" >> $GITHUB_STEP_SUMMARY
                else
                  echo "**Branch Built:** \`${{ github.ref_name }}\`" >> $GITHUB_STEP_SUMMARY
                fi
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "**Commit SHA:** \`${{ steps.get_sha.outputs.sha }}\`" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "**Image:** \`gcr.io/xperience-staging/xperience-adbroker:${{ steps.get_sha.outputs.sha }}\`" >> $GITHUB_STEP_SUMMARY

    Database-Migrate:
      needs: [Continue-RC-Train, Build]
      if: always() && needs.Build.result == 'success'
      runs-on: ubuntu-latest

      steps:
        - name: Determine branch to checkout
          id: branch
          run: |
            if [ "${{ github.ref }}" == "refs/heads/main" ]; then
              echo "ref=${{ needs.Continue-RC-Train.outputs.rc_branch }}" >> $GITHUB_OUTPUT
            else
              echo "ref=${{ github.ref_name }}" >> $GITHUB_OUTPUT
            fi

        - uses: actions/checkout@v4
          with:
            ref: ${{ steps.branch.outputs.ref }}

        - uses: mattes/gce-cloudsql-proxy-action@v1
          with:
            creds: ${{ secrets.XPERIENCE_STAGING_SERVICE_ACCOUNT }}
            instance: xperience-staging:us-central1:data-hub
            port: 3306

        - name: Setup Node.js environment
          uses: actions/setup-node@v3
          with:
            node-version: 22

        - id: auth_prod
          name: Authenticate to Google Cloud
          uses: google-github-actions/auth@v2
          with:
            credentials_json: '${{ secrets.XPERIENCE_STAGING_SERVICE_ACCOUNT }}'

        - id: 'secrets'
          uses: 'google-github-actions/get-secretmanager-secrets@v2'
          with:
            secrets: |-
              token:xperience-staging/xperience-data-hub-db-password

        - name: 'Migrate database'
          run: npx prisma migrate deploy
          env:
            DATABASE_URL: mysql://root:${{ steps.secrets.outputs.token }}@localhost:3306/adbroker

    Deploy:
        needs: [Continue-RC-Train, Database-Migrate, Build]
        if: always() && needs.Database-Migrate.result == 'success'
        runs-on: ubuntu-latest
        steps:
            - name: Display deployment info
              run: |
                echo "🚀 Deploying to Staging"
                if [ "${{ github.ref }}" == "refs/heads/main" ]; then
                  echo "📦 Branch: ${{ needs.Continue-RC-Train.outputs.rc_branch }}"
                else
                  echo "📦 Branch: ${{ github.ref_name }}"
                fi
                echo "🏷️  Image SHA: ${{ needs.Build.outputs.image_sha }}"

            - id: auth_staging
              name: Log in to Google Cloud
              uses: google-github-actions/auth@v2
              with:
                project_id: 'xperience-staging'
                credentials_json: ${{ secrets.XPERIENCE_STAGING_SERVICE_ACCOUNT }}

            - name: Deploy to Cloud Run
              uses: 'google-github-actions/deploy-cloudrun@v2'
              with:
                service: xperience-adbroker
                project_id: xperience-staging
                image: gcr.io/xperience-staging/xperience-adbroker:${{ needs.Build.outputs.image_sha }}

            - name: Post deployment summary
              if: success()
              run: |
                echo "## 🚀 Deployment Successful" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                if [ "${{ github.ref }}" == "refs/heads/main" ]; then
                  echo "**Branch Deployed:** \`${{ needs.Continue-RC-Train.outputs.rc_branch }}\`" >> $GITHUB_STEP_SUMMARY
                else
                  echo "**Branch Deployed:** \`${{ github.ref_name }}\`" >> $GITHUB_STEP_SUMMARY
                fi
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "**Image SHA:** \`${{ needs.Build.outputs.image_sha }}\`" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "**Environment:** Staging (xperience-staging)" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "**Service:** xperience-adbroker" >> $GITHUB_STEP_SUMMARY
```
