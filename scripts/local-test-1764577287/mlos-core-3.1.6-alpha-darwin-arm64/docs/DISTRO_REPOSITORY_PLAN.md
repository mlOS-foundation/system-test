# MLOS Distribution Repository Plan

## Overview

Create a new repository `mlos-distro` (or `mlos`) that serves as the official distribution point for the complete MLOS stack, bundling Axon, MLOS Core, and future components.

## Repository Structure

```
mlos-distro/
├── README.md                    # Main documentation
├── CHANGELOG.md                 # Combined changelog
├── VERSIONS.md                  # Component version compatibility matrix
├── install.sh                   # Unified installer
├── docker-compose.yml           # Complete stack deployment
├── Dockerfile                   # Multi-component Docker image
├── .github/
│   └── workflows/
│       ├── release.yml          # Automated release workflow
│       └── test-compatibility.yml # Test component compatibility
├── dist/
│   ├── docker/                  # Docker images
│   ├── binaries/                # Platform-specific binaries
│   └── packages/                # Package manager packages
├── config/
│   ├── mlos.yaml                # MLOS configuration
│   └── axon.yaml                # Axon configuration
├── examples/
│   ├── quickstart.sh            # Quick start guide
│   └── e2e-demo.sh              # Complete E2E demo
└── docs/
    ├── INSTALLATION.md          # Installation guide
    ├── COMPONENTS.md            # Component overview
    └── VERSIONING.md            # Version strategy
```

## Component Versioning Strategy

### Version Format
```
mlos-distro-v1.2.3
├── axon: v1.5.0
├── core: v1.0.0
└── smi-spec: v1.0.0 (future)
```

### Compatibility Matrix

| MLOS Distro | Axon | MLOS Core | SMI Spec | Status |
|-------------|------|-----------|----------|--------|
| v1.0.0      | v1.5.0 | v1.0.0 | - | ✅ Stable |
| v1.1.0      | v1.6.0 | v1.0.0 | - | 🔄 Planned |
| v1.2.0      | v1.6.0 | v1.1.0 | v1.0.0 | 🔮 Future |

## Distribution Methods

### 1. Docker Image (Primary)
```dockerfile
# Multi-stage build pulling from component repos
FROM ghcr.io/mlOS-foundation/core:v1.0.0 AS core
FROM ghcr.io/mlOS-foundation/axon:v1.5.0 AS axon

# Combine into single image
FROM ubuntu:22.04
COPY --from=core /opt/mlos /opt/mlos
COPY --from=axon /usr/local/bin/axon /usr/local/bin/
# ... configuration, scripts, etc.
```

**Usage:**
```bash
docker pull ghcr.io/mlOS-foundation/mlos:v1.0.0
docker run -p 8080:8080 ghcr.io/mlOS-foundation/mlos:v1.0.0
```

### 2. Binary Bundle (Secondary)
```bash
# Single archive containing both binaries
mlos-v1.0.0_linux_amd64.tar.gz
├── bin/
│   ├── mlos-core
│   └── axon
├── config/
│   ├── mlos.yaml
│   └── axon.yaml
└── README.md
```

### 3. Package Managers (Future)
- **Homebrew**: `brew install mlos`
- **APT**: `apt install mlos`
- **Snap**: `snap install mlos`

## Installation Script

### Unified Installer (`install.sh`)
```bash
#!/bin/bash
# MLOS Distribution Installer

VERSION="${MLOS_VERSION:-latest}"
INSTALL_METHOD="${MLOS_INSTALL_METHOD:-docker}"

case "$INSTALL_METHOD" in
  docker)
    docker pull ghcr.io/mlOS-foundation/mlos:$VERSION
    ;;
  binary)
    # Download and extract binary bundle
    curl -L https://github.com/mlOS-foundation/mlos-distro/releases/download/v$VERSION/mlos-$VERSION.tar.gz | tar -xz
    ;;
  *)
    echo "Unknown install method: $INSTALL_METHOD"
    exit 1
    ;;
esac
```

**Usage:**
```bash
# Install latest
curl -sSL https://mlosfoundation.org/install | sh

# Install specific version
MLOS_VERSION=v1.0.0 curl -sSL https://mlosfoundation.org/install | sh

# Install binary (not Docker)
MLOS_INSTALL_METHOD=binary curl -sSL https://mlosfoundation.org/install | sh
```

## Release Workflow

### Automated Release Process

1. **Component Releases Trigger Distro Release**
   - When `axon` releases v1.6.0 → Check if compatible with current `core`
   - When `core` releases v1.1.0 → Check if compatible with current `axon`
   - If compatible → Auto-create `mlos-distro` patch release (v1.0.1)
   - If breaking → Create new minor/major distro release

2. **Manual Release Process**
   ```bash
   # Create release with specific component versions
   gh release create v1.0.0 \
     --title "MLOS v1.0.0" \
     --notes "Includes Axon v1.5.0 + MLOS Core v1.0.0" \
     --attach dist/mlos-v1.0.0_linux_amd64.tar.gz \
     --attach dist/mlos-v1.0.0_darwin_amd64.tar.gz
   ```

3. **GitHub Actions Workflow**
   ```yaml
   name: Release MLOS Distro
   
   on:
     workflow_dispatch:
       inputs:
         axon_version:
           required: true
         core_version:
           required: true
     repository_dispatch:
       types: [component-release]
   
   jobs:
     build:
       steps:
         - name: Download Axon
           run: |
             gh release download ${{ inputs.axon_version }} \
               --repo mlOS-foundation/axon \
               --pattern "axon_*_linux_amd64.tar.gz"
         
         - name: Download MLOS Core
           run: |
             gh release download ${{ inputs.core_version }} \
               --repo mlOS-foundation/core \
               --pattern "mlos-core_*_linux_amd64.tar.gz"
         
         - name: Build Docker image
           run: |
             docker build -t mlos:${{ github.ref_name }} .
         
         - name: Build binary bundle
           run: |
             tar -czf mlos-${{ github.ref_name }}_linux_amd64.tar.gz \
               bin/ config/ README.md
         
         - name: Create release
           run: |
             gh release create ${{ github.ref_name }} \
               --title "MLOS ${{ github.ref_name }}" \
               --notes "Includes Axon ${{ inputs.axon_version }} + Core ${{ inputs.core_version }}"
   ```

## Version Management

### VERSIONS.md
```markdown
# MLOS Distribution Versions

## Current Stable: v1.0.0

**Components:**
- Axon: v1.5.0
- MLOS Core: v1.0.0

**Compatibility:**
- ✅ Axon v1.5.0 works with Core v1.0.0
- ✅ E2E integration tested and verified
- ✅ All adapters functional

## Upcoming: v1.1.0

**Planned Components:**
- Axon: v1.6.0 (or latest)
- MLOS Core: v1.0.0 (or v1.1.0 if available)

**Status:** 🔄 Testing compatibility
```

## Benefits

### For Users
- ✅ **Single Installation**: One command to get everything
- ✅ **Guaranteed Compatibility**: Tested component combinations
- ✅ **Unified Experience**: Consistent configuration and usage
- ✅ **Clear Versioning**: Know exactly what you're getting

### For Maintainers
- ✅ **Version Control**: Centralized version management
- ✅ **Testing**: Can test component combinations before release
- ✅ **Documentation**: Single source of truth for installation
- ✅ **Distribution**: One place to publish complete stack

### For Ecosystem
- ✅ **Standardization**: Official "MLOS" distribution
- ✅ **Easier Onboarding**: New users don't need to understand components
- ✅ **Future Expansion**: Easy to add SMI spec, plugins, tools

## Implementation Plan

### Phase 1: Repository Setup
1. Create `mlos-distro` repository
2. Set up basic structure
3. Create `VERSIONS.md` with compatibility matrix
4. Add unified `install.sh`

### Phase 2: Docker Distribution
1. Create `Dockerfile` that combines components
2. Set up GitHub Actions to build Docker images
3. Publish to GHCR: `ghcr.io/mlOS-foundation/mlos`
4. Test Docker image with E2E demo

### Phase 3: Binary Distribution
1. Create binary bundling script
2. Set up cross-platform builds
3. Create GitHub Releases with binary bundles
4. Add checksums and verification

### Phase 4: Automation
1. Set up automated release workflow
2. Component release webhooks → auto-build distro
3. Compatibility testing automation
4. Version bump automation

### Phase 5: Package Managers (Future)
1. Homebrew formula
2. APT repository
3. Snap package
4. Chocolatey (Windows)

## Example Usage

### Quick Start
```bash
# Install MLOS (includes Axon + Core)
curl -sSL https://mlosfoundation.org/install | sh

# Or with Docker
docker run -p 8080:8080 ghcr.io/mlOS-foundation/mlos:latest

# Use Axon
axon install hf/bert-base-uncased@latest

# Register with MLOS Core
axon register hf/bert-base-uncased@latest

# Run inference
curl -X POST http://localhost:8080/models/hf/bert-base-uncased@latest/inference \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello, MLOS!"}'
```

### Version-Specific Installation
```bash
# Install specific MLOS version
MLOS_VERSION=v1.0.0 curl -sSL https://mlosfoundation.org/install | sh

# Check installed versions
mlos --version
# MLOS Distribution v1.0.0
#   Axon: v1.5.0
#   MLOS Core: v1.0.0
```

## Repository Naming

**Options:**
1. `mlos-distro` - Clear, descriptive
2. `mlos` - Simple, but might conflict with org name
3. `mlos-stack` - Indicates it's a stack
4. `mlos-platform` - Indicates it's a platform

**Recommendation:** `mlos-distro` - Clear that it's the distribution repository.

## Next Steps

1. ✅ Create repository structure document (this file)
2. ⏳ Create `mlos-distro` repository
3. ⏳ Set up basic structure and documentation
4. ⏳ Create unified installer script
5. ⏳ Set up Docker image build
6. ⏳ Create GitHub Actions workflows
7. ⏳ Test with current Axon v1.5.0 + Core v1.0.0
8. ⏳ Create first MLOS distro release (v1.0.0)

---

**This repository becomes the official "MLOS" distribution, making it easy for users to get the complete stack with guaranteed compatibility.**

