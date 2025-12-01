# MLOS Core Distribution Strategy

Since the MLOS Core repository is private, we need a strategy to provide open access to the full layer functionality. This document outlines the recommended approach.

## Recommendation: **Docker-First with Binary Releases**

### Primary: Docker Image Distribution

**Why Docker is Best for Most Users:**
- ✅ **Self-contained**: Includes all dependencies (libc, pthread, curl, etc.)
- ✅ **Cross-platform**: Works on Linux, macOS, Windows (via Docker)
- ✅ **Zero setup**: No compilation, no dependency management
- ✅ **Consistent**: Same behavior across all environments
- ✅ **Easy deployment**: Single command to run
- ✅ **Version control**: Tagged images (v1.0.0, latest)
- ✅ **Private repo friendly**: Can publish images without exposing source code

**Distribution:**
- **GitHub Container Registry (GHCR)**: `ghcr.io/mlOS-foundation/mlos-core`
- **Docker Hub** (optional): `mlosfoundation/mlos-core`
- **Tags**: `v1.0.0`, `v1.0.1`, `latest`

**Usage:**
```bash
# Pull and run
docker pull ghcr.io/mlOS-foundation/mlos-core:latest
docker run -p 8080:8080 -p 8081:8081 ghcr.io/mlOS-foundation/mlos-core:latest

# Or with docker-compose
docker-compose up mlos-core
```

### Secondary: Binary Releases

**Why Binaries for Advanced Users:**
- ✅ **No Docker required**: Direct execution
- ✅ **Smaller size**: Just the binary (~5-10MB vs ~100MB+ image)
- ✅ **Faster startup**: No container overhead
- ✅ **Native performance**: Direct kernel access
- ✅ **Embeddable**: Can be integrated into other tools

**Distribution:**
- **GitHub Releases**: Platform-specific binaries
- **Platforms**: Linux (amd64, arm64), macOS (amd64, arm64), Windows (amd64)
- **Format**: `mlos-core_${VERSION}_${GOOS}_${GOARCH}.tar.gz`
- **Includes**: Binary, README, LICENSE, checksums

**Usage:**
```bash
# Download and extract
curl -L https://github.com/mlOS-foundation/core/releases/download/v1.0.0/mlos-core_1.0.0_linux_amd64.tar.gz | tar -xz
./mlos-core
```

## Implementation Plan

### Phase 1: Docker Image (Primary)

1. **Build Docker Image**
   - Multi-stage build (already implemented)
   - Optimize for size (use alpine or distroless base)
   - Include health checks

2. **Publish to GHCR**
   - GitHub Actions workflow
   - Automated on release tags
   - Public access (no authentication needed for pull)

3. **Documentation**
   - Update README with Docker instructions
   - Add docker-compose example
   - Include in website/docs

### Phase 2: Binary Releases (Secondary)

1. **Build Binaries**
   - Cross-compile for all platforms
   - Include in GitHub Releases
   - Generate checksums

2. **Package Management** (Optional)
   - Homebrew formula (macOS)
   - APT repository (Linux)
   - Chocolatey (Windows)

## Comparison Matrix

| Feature | Docker | Binary |
|---------|--------|--------|
| **Ease of Use** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Setup Time** | < 1 min | 2-5 min |
| **Dependencies** | None (included) | System libs required |
| **Cross-Platform** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ (need separate builds) |
| **Size** | ~100MB+ | ~5-10MB |
| **Startup Time** | ~1-2s | < 0.1s |
| **Performance** | Native (with overhead) | Native |
| **Distribution** | Single image | Multiple binaries |
| **Maintenance** | Lower | Higher |

## Recommended Approach

**For 90% of Users: Docker**
- Primary distribution method
- Featured in all documentation
- Easiest onboarding experience

**For 10% of Users: Binaries**
- Advanced users
- Embedded systems
- Performance-critical deployments
- Systems without Docker

## Next Steps

1. ✅ Docker image already builds (see `Dockerfile`)
2. ⏳ Create GitHub Actions workflow for Docker publishing
3. ⏳ Create GitHub Actions workflow for binary releases
4. ⏳ Update documentation with both options
5. ⏳ Add to website with installation instructions

## Example Workflows

### Docker Workflow
```yaml
name: Build and Publish Docker Image

on:
  release:
    types: [published]

jobs:
  docker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build Docker image
        run: docker build -t mlos-core:${{ github.ref_name }} .
      - name: Publish to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Push image
        run: |
          docker tag mlos-core:${{ github.ref_name }} ghcr.io/mlOS-foundation/mlos-core:${{ github.ref_name }}
          docker tag mlos-core:${{ github.ref_name }} ghcr.io/mlOS-foundation/mlos-core:latest
          docker push ghcr.io/mlOS-foundation/mlos-core:${{ github.ref_name }}
          docker push ghcr.io/mlOS-foundation/mlos-core:latest
```

### Binary Release Workflow
```yaml
name: Build and Release Binaries

on:
  release:
    types: [published]

jobs:
  build:
    strategy:
      matrix:
        goos: [linux, darwin, windows]
        goarch: [amd64, arm64]
        exclude:
          - goos: windows
            goarch: arm64
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build binary
        env:
          GOOS: ${{ matrix.goos }}
          GOARCH: ${{ matrix.goarch }}
        run: make release
      - name: Upload artifact
        uses: actions/upload-release-asset@v1
        with:
          asset_path: ./build/mlos-core
          asset_name: mlos-core_${{ github.ref_name }}_${{ matrix.goos }}_${{ matrix.goarch }}.tar.gz
          asset_content_type: application/gzip
```

---

**Recommendation: Start with Docker, add binaries later if needed.**

