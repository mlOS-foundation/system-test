# Release and Local Testing Plan

## Overview

Once both PRs (#15 Core, #20 Axon) pass CI and are merged, this document outlines the steps to create releases and test the complete E2E workflow locally.

## Prerequisites

- ✅ Both PRs merged to `main`
- ✅ All CI checks passing
- ✅ No blocking issues

## Step 1: Create Core Release

### 1.1 Tag the Release

```bash
cd core
git checkout main
git pull origin main

# Determine version (e.g., v1.0.1 for E2E feature release)
VERSION="v1.0.1"
git tag -a "$VERSION" -m "Release $VERSION: E2E Install → Publish → Inference workflow

Features:
- Model repository scanning and auto-discovery
- Setup script for /var/lib/mlos/models/
- E2E demo script
- Comprehensive architecture documentation

Breaking Changes: None
Dependencies: Requires Axon v1.0.1+ for publish command"

git push origin "$VERSION"
```

### 1.2 Create GitHub Release

1. Go to: https://github.com/mlOS-foundation/core/releases/new
2. Select tag: `v1.0.1`
3. Title: `v1.0.1 - E2E Workflow Release`
4. Description:
   ```markdown
   ## E2E Workflow Release
   
   This release implements the complete end-to-end workflow: Install → Publish → Inference.
   
   ### Features
   - ✅ Model repository scanning on startup
   - ✅ Auto-discovery of published models
   - ✅ Setup script for production repository
   - ✅ E2E demo script
   - ✅ Comprehensive architecture documentation
   
   ### Installation
   
   Download the binary for your platform from the assets below.
   
   ### Usage
   
   ```bash
   # Setup repository
   sudo ./scripts/setup-model-repository.sh
   
   # Start MLOS Core
   ./mlos_core
   
   # Run E2E demo
   ./scripts/demo-e2e.sh
   ```
   
   ### Documentation
   
   See `docs/E2E_IMPLEMENTATION_PLAN.md` for complete implementation details.
   ```
5. Publish release (triggers artifact build workflow)

### 1.3 Verify Artifacts

The `publish-artifacts.yml` workflow should automatically:
- Build binaries for Linux (amd64, arm64)
- Build binaries for macOS (amd64, arm64)
- Create release artifacts
- Attach to GitHub release

## Step 2: Create Axon Release

### 2.1 Tag the Release

```bash
cd axon
git checkout main
git pull origin main

# Determine version (e.g., v1.0.1 for E2E feature release)
VERSION="v1.0.1"
git tag -a "$VERSION" -m "Release $VERSION: E2E Publish Command

Features:
- axon publish command
- Enhanced register command (checks published models first)
- Production repository support

Breaking Changes: None
Dependencies: Works with MLOS Core v1.0.1+"

git push origin "$VERSION"
```

### 2.2 Create GitHub Release

1. Go to: https://github.com/mlOS-foundation/axon/releases/new
2. Select tag: `v1.0.1`
3. Title: `v1.0.1 - E2E Publish Command Release`
4. Description:
   ```markdown
   ## E2E Publish Command Release
   
   This release adds the `axon publish` command and enhances the `register` command for the complete E2E workflow.
   
   ### Features
   - ✅ `axon publish` command
   - ✅ Enhanced `register` command (checks published models first)
   - ✅ Production repository support
   
   ### Installation
   
   Download the binary for your platform from the assets below.
   
   ### Usage
   
   ```bash
   # Install model (development)
   axon install hf/bert-base-uncased@latest
   
   # Publish model (production)
   axon publish hf/bert-base-uncased@latest --target localhost
   
   # Register model
   axon register hf/bert-base-uncased@latest
   ```
   ```
5. Publish release (triggers artifact build workflow)

### 2.3 Verify Artifacts

The release workflow should automatically:
- Build binaries for Linux (amd64, arm64)
- Build binaries for macOS (amd64, arm64)
- Create release artifacts
- Attach to GitHub release

## Step 3: Local Testing with Released Binaries

### 3.1 Download Released Binaries

```bash
# Create test directory
mkdir -p ~/mlos-test
cd ~/mlos-test

# Download Core release
CORE_VERSION="v1.0.1"
ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

# Download MLOS Core
curl -L "https://github.com/mlOS-foundation/core/releases/download/${CORE_VERSION}/mlos_core-${OS}-${ARCH}" -o mlos_core
chmod +x mlos_core

# Download Axon
curl -L "https://github.com/mlOS-foundation/axon/releases/download/${CORE_VERSION}/axon-${OS}-${ARCH}" -o axon
chmod +x axon
```

### 3.2 Setup Environment

```bash
# Setup model repository
sudo ./core/scripts/setup-model-repository.sh

# Or for local testing without sudo
mkdir -p /tmp/mlos-test/models
export MLOS_REPO="/tmp/mlos-test/models"
```

### 3.3 Test E2E Workflow

```bash
# 1. Start MLOS Core (in background or separate terminal)
./mlos_core &
MLOS_PID=$!

# Wait for MLOS Core to start
sleep 2

# 2. Install model
./axon install hf/bert-base-uncased@latest

# 3. Publish model
./axon publish hf/bert-base-uncased@latest --target localhost

# 4. Verify model is discovered (check MLOS Core logs)
# MLOS Core should auto-discover on startup or next scan

# 5. Register model (if needed)
./axon register hf/bert-base-uncased@latest

# 6. Test inference
curl -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{
    "model_id": "hf/bert-base-uncased@latest",
    "input": "Hello, MLOS!",
    "input_format": "text"
  }'

# 7. Cleanup
kill $MLOS_PID
```

### 3.4 Run E2E Demo Script

```bash
# If demo script is included in release
./core/scripts/demo-e2e.sh
```

## Step 4: Verification Checklist

### Core Release Verification

- [ ] Release tag created and pushed
- [ ] GitHub release created
- [ ] Artifacts built for all platforms
- [ ] Artifacts attached to release
- [ ] Release notes complete
- [ ] Binary downloads work

### Axon Release Verification

- [ ] Release tag created and pushed
- [ ] GitHub release created
- [ ] Artifacts built for all platforms
- [ ] Artifacts attached to release
- [ ] Release notes complete
- [ ] Binary downloads work

### Local Testing Verification

- [ ] MLOS Core starts successfully
- [ ] Model repository scanning works
- [ ] `axon install` works
- [ ] `axon publish` works
- [ ] `axon register` works (checks published first)
- [ ] MLOS Core auto-discovers published models
- [ ] Inference API works
- [ ] E2E demo script completes successfully

## Step 5: Post-Release

### 5.1 Update Documentation

- [ ] Update main README with release notes
- [ ] Update installation instructions
- [ ] Update E2E workflow documentation

### 5.2 Announce Release

- [ ] Update changelog
- [ ] Announce on relevant channels
- [ ] Update version numbers in docs

## Troubleshooting

### Release Artifacts Not Building

1. Check GitHub Actions workflow status
2. Verify workflow triggers on tag push
3. Check build logs for errors
4. Ensure all dependencies are available

### Local Testing Issues

1. Verify binary permissions (`chmod +x`)
2. Check MLOS Core logs for errors
3. Verify model repository permissions
4. Check network connectivity for model downloads
5. Verify MLOS Core API is accessible

### Model Discovery Issues

1. Verify model repository path (`/var/lib/mlos/models/`)
2. Check manifest.yaml exists in model directory
3. Verify MLOS Core has read permissions
4. Check MLOS Core startup logs for scan results

## Success Criteria

✅ Both releases created and published  
✅ All artifacts built and attached  
✅ Local E2E workflow completes successfully  
✅ All verification checklists passed  
✅ Documentation updated  

---

**Once all steps are complete, the E2E workflow is production-ready!**

