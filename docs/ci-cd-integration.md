# CI/CD Integration Guide

This guide explains how to integrate the RC branching scripts into your CI/CD pipelines across multiple repositories using the download-on-demand approach.

## Table of Contents
- [Overview](#overview)
- [GitHub Actions Integration](#github-actions-integration)
- [Workflow Summary](#workflow-summary)
- [Testing Your Integration](#testing-your-integration)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

---

## Overview

The RC scripts (`cut_rc.sh`, `promote_rc.sh`, `status_rc.sh`) are integrated into CI/CD pipelines by downloading them on-demand during workflow execution. This ensures you always use the latest version while keeping repositories clean.

**Implementation:**
- Scripts are downloaded from the xperience repo during GitHub Actions workflows
- Production deployment automatically starts new RC trains with minor version bumps
- Staging deployment automatically continues existing RC trains

---

## GitHub Actions Integration

### Script Download Method

The workflows download scripts directly from the xperience repository during execution:

**Pros:**
- ✅ Always gets latest version
- ✅ No local copies needed
- ✅ Easy to set up
- ✅ Consistent across all repos

**Cons:**
- ❌ Requires network access during CI
- ❌ External dependency

**Implementation:**
```yaml
- name: Download RC scripts
  run: |
    mkdir -p scripts
    curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
      https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/cut_rc.sh -o scripts/cut_rc.sh
    curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
      https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/status_rc.sh -o scripts/status_rc.sh
    chmod +x scripts/*.sh
```

> **Note**: If the xperience repository is private, you must include the `Authorization` header with a GitHub token that has access to the repository.

---

### Example: Production Deployment with RC Automation

This example shows a production deployment workflow that automatically starts a new RC train after successful deployment.

Create `.github/workflows/deploy-prod.yml` in your target repository:

```yaml
name: Ad Broker API Production Deployment

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
                token: ${{ secrets.GITHUB_TOKEN }}
            
            - name: Download RC scripts
              run: |
                mkdir -p scripts
                curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
                  https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/cut_rc.sh -o scripts/cut_rc.sh
                curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
                  https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/status_rc.sh -o scripts/status_rc.sh
                chmod +x scripts/*.sh
            
            - name: Configure Git
              run: |
                git config user.name "github-actions[bot]"
                git config user.email "github-actions[bot]@users.noreply.github.com"
            
            - name: Setup Node.js
              uses: actions/setup-node@v4
              with:
                node-version: '22'
            
            - name: Start new RC train
              run: |
                echo "Starting new RC train with minor version bump"
                ./scripts/cut_rc.sh --bump minor --replace
            
            - name: Post summary
              if: success()
              run: |
                echo "## ✅ New RC Train Started" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "A new release candidate train has been created with a minor version bump." >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                ./scripts/status_rc.sh >> $GITHUB_STEP_SUMMARY
```

### Example: Staging Deployment with RC Continuation

This example shows a staging deployment workflow that automatically continues the RC train after successful deployment to staging.

Create `.github/workflows/deploy-staging.yml` in your target repository:

```yaml
name: Ad Broker API Staging Deployment

on:
    push:
        branches:
            - main
            - 'release/**'

jobs:
    Build:
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v4

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
                docker build -f Dockerfile.cloudrun -t gcr.io/xperience-staging/xperience-adbroker:${{ github.sha }} .

            - name: Push Docker image to GCR
              run: |
                docker push gcr.io/xperience-staging/xperience-adbroker:${{ github.sha }}

    Database-Migrate:
      needs: Build
      runs-on: ubuntu-latest

      steps:
        - uses: actions/checkout@v4

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
        needs: Database-Migrate
        runs-on: ubuntu-latest
        steps:
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
                image: gcr.io/xperience-staging/xperience-adbroker:${{ github.sha }}

    Continue-RC-Train:
        needs: Deploy
        runs-on: ubuntu-latest
        
        permissions:
            contents: write
        
        steps:
            - name: Checkout repository
              uses: actions/checkout@v4
              with:
                fetch-depth: 0
                token: ${{ secrets.GITHUB_TOKEN }}
            
            - name: Download RC scripts
              run: |
                mkdir -p scripts
                curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
                  https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/cut_rc.sh -o scripts/cut_rc.sh
                curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
                  https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/status_rc.sh -o scripts/status_rc.sh
                chmod +x scripts/*.sh
            
            - name: Configure Git
              run: |
                git config user.name "github-actions[bot]"
                git config user.email "github-actions[bot]@users.noreply.github.com"
            
            - name: Setup Node.js
              uses: actions/setup-node@v4
              with:
                node-version: '22'
            
            - name: Continue RC train
              run: |
                echo "Continuing existing RC train"
                ./scripts/cut_rc.sh --replace
            
            - name: Post summary
              if: success()
              run: |
                echo "## ✅ RC Train Continued" >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                echo "The release candidate has been incremented after successful staging deployment." >> $GITHUB_STEP_SUMMARY
                echo "" >> $GITHUB_STEP_SUMMARY
                ./scripts/status_rc.sh >> $GITHUB_STEP_SUMMARY
```

### Workflow Summary

**Production Workflow (deploy-prod.yml)**:
- **Trigger**: Release published
- **RC Action**: Starts new train with `--bump minor --replace`
- **Result**: Creates `release/X.Y.0-rc.0` for next version

**Staging Workflow (deploy-staging.yml)**:
- **Trigger**: Push to `main` branch or `release/**` branches
- **RC Action**: Continues train with `--replace`
- **Result**: Increments to `release/X.Y.Z-rc.1`, `rc.2`, etc.
- **Use Cases**: 
  - Normal: Merge to main → auto-deploy → auto-continue RC
  - Manual: Push directly to release branch for hotfixes/cherry-picks

**Future Enhancement**: PR labels could be used to control version bumping in production (major/minor/patch). Currently, production always bumps minor.

---

## Testing Your Integration

### Manual Test
```bash
# Test scripts locally before CI/CD integration
./scripts/status_rc.sh --verbose
./scripts/cut_rc.sh --bump minor --replace --dry-run
```

### CI Test - Production Workflow
1. Create a GitHub release and publish it
2. Check GitHub Actions logs for the `Start-New-RC-Train` job
3. Verify new RC branch created: `git fetch && git branch -r | grep release/`
4. Confirm it starts with `rc.0`

### CI Test - Staging Workflow
1. **Normal flow**: Push changes to `main` branch (or merge a PR)
2. **Manual flow**: Push directly to a `release/**` branch (for hotfixes)
3. Check GitHub Actions logs for the `Continue-RC-Train` job
4. Verify RC was incremented (e.g., `rc.0` → `rc.1`)
5. Check GitHub Actions summary for status

---

## Troubleshooting

### Script Download Issues

**Problem:** Script not found
```
Error: ./scripts/cut_rc.sh: No such file or directory
```

**Solution:** Verify the download step completed successfully and scripts directory was created:
```yaml
- name: Download RC scripts
  run: |
    mkdir -p scripts
    curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
      https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/cut_rc.sh -o scripts/cut_rc.sh
    curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
      https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/status_rc.sh -o scripts/status_rc.sh
    chmod +x scripts/*.sh
```

**Problem:** Permission denied
```
Error: Permission denied: ./scripts/cut_rc.sh
```

**Solution:** Ensure scripts are made executable after download:
```yaml
chmod +x scripts/*.sh
```

**Problem:** curl fails to download
```
Error: Failed to connect to raw.githubusercontent.com
```
OR
```
./scripts/cut_rc.sh: line 1: 404:: command not found
```

**Solution:** This happens when the xperience repository is private. Add authentication to the curl command:
```yaml
- name: Download RC scripts
  run: |
    mkdir -p scripts
    for i in {1..3}; do
      curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
        https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/cut_rc.sh -o scripts/cut_rc.sh && \
      curl -sL -H "Authorization: token ${{ secrets.GITHUB_TOKEN }}" \
        https://raw.githubusercontent.com/adsupnow/xperience/main/scripts/status_rc.sh -o scripts/status_rc.sh && \
      break
      sleep 2
    done
    chmod +x scripts/*.sh
```

**Alternative:** Make the xperience repository public if the scripts contain no sensitive information.

### Git Push Issues
```
Error: failed to push some refs
```

**Solution:** Check token permissions and configure Git:
```yaml
- uses: actions/checkout@v4
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    fetch-depth: 0
```

### Node.js Issues

**Problem:** Node not found
```
Error: Missing required command: node
```

**Solution:** Ensure Node.js setup step is included:
```yaml
- name: Setup Node.js
  uses: actions/setup-node@v4
  with:
    node-version: '22'
```

**Problem:** package.json not found
```
Error: package.json not found
```

**Solution:** Ensure you're running from repository root and package.json exists.

---

## Best Practices

1. **Version Pinning**: Consider pinning to specific script versions or commits for production stability
2. **Testing**: Always test with `--dry-run` first when setting up new repositories
3. **Monitoring**: Set up GitHub Actions notifications for workflow failures
4. **Documentation**: Document any repo-specific customizations in the README
5. **Rollback Plan**: Know how to manually cut RC if automation fails (run scripts locally)
6. **Security**: Use secrets for tokens, never hardcode credentials
7. **Idempotency**: Scripts are designed to be safely re-run if workflows fail

---

## Next Steps

1. Copy the production and staging workflow examples to your repository
2. Update the workflow files with your specific configuration (project IDs, service names, etc.)
3. Test manually with `--dry-run` flag before enabling automation
4. Monitor the first few automated runs to ensure everything works as expected
5. Document any repo-specific customizations in your README
6. Set up GitHub Actions notifications for workflow failures

For more details on the scripts themselves, refer to the [RC Branching Scripts Documentation](./rc-branching-scripts.md).
