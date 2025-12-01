# Docker-Based Build System

MLOS Core uses a robust Docker-based build system that enables:
- ✅ **Multi-architecture builds** (amd64, arm64)
- ✅ **Consistent Linux environment** for validation
- ✅ **Portable builds** that work the same locally and in CI
- ✅ **Cross-platform development** (develop on macOS, test on Linux)

## Quick Start

### Build for Local Platform

```bash
# Build Docker image for your current platform
make docker-build

# Or use the script directly
./scripts/docker-build-all.sh
```

### Build for All Architectures

```bash
# Build and push to registry (for CI/releases)
PUSH=true ./scripts/docker-build-all.sh

# Or set environment variables
export PUSH=true
export PLATFORMS="linux/amd64,linux/arm64"
./scripts/docker-build-all.sh
```

### Run Validation in Docker

```bash
# Run all CI checks in Docker (Linux environment)
make docker-validate

# Or use the script directly
./scripts/docker-validate.sh
```

## Architecture

### Multi-Stage Build

The Dockerfile uses a multi-stage build:

1. **Builder Stage**: Compiles MLOS Core with all dependencies
2. **Production Stage**: Minimal runtime image with only the binary and ONNX Runtime

### Platform Support

- **linux/amd64**: Intel/AMD 64-bit
- **linux/arm64**: ARM 64-bit (Apple Silicon, AWS Graviton, etc.)

### Build Arguments

- `VERSION`: Version tag for the build (default: 1.0.0)
- `TARGETPLATFORM`: Target platform (set automatically by buildx)
- `TARGETARCH`: Target architecture (set automatically by buildx)

## Usage

### Local Development

```bash
# Build and run locally
make docker-build
make docker-run

# Or use docker-compose
docker-compose up
```

### CI/CD Integration

The Docker build system is integrated into CI workflows:

```yaml
# .github/workflows/ci.yml
- name: Build Docker image
  run: make docker-build

- name: Test Docker image
  run: make docker-test
```

### Validation Before PR

The `create-pr.sh` script automatically uses Docker validation if available:

```bash
# Automatically uses Docker if available
./scripts/create-pr.sh --title "Fix bug" --body "Description"
```

## Benefits

### 1. Consistent Environment

- Same build environment locally and in CI
- No "works on my machine" issues
- Linux-specific issues caught before PR

### 2. Multi-Architecture Support

- Build for multiple architectures from single machine
- Test ARM64 builds on x86_64 machines
- Single command builds all platforms

### 3. Portable Development

- Develop on macOS, test on Linux
- No need for Linux VM or dual-boot
- Same Docker image works everywhere

### 4. CI/CD Integration

- Same Docker build in CI and locally
- Faster CI (can cache Docker layers)
- Reproducible builds

## Scripts

### `scripts/docker-build-all.sh`

Builds MLOS Core for multiple architectures using Docker Buildx.

**Usage:**
```bash
# Build for local platform only
./scripts/docker-build-all.sh

# Build for all platforms and push
PUSH=true ./scripts/docker-build-all.sh

# Custom platforms
PLATFORMS="linux/amd64,linux/arm64" ./scripts/docker-build-all.sh
```

### `scripts/docker-validate.sh`

Runs all CI validation checks in Docker containers.

**Tests:**
- Linux amd64 with gcc
- Linux amd64 with clang
- Linux arm64 with gcc (if supported)

**Usage:**
```bash
./scripts/docker-validate.sh
```

## Makefile Targets

- `make docker-build`: Build for local platform
- `make docker-build-all`: Build for all architectures
- `make docker-run`: Run container locally
- `make docker-test`: Test Docker image
- `make docker-validate`: Run validation in Docker

## Troubleshooting

### Buildx Not Available

```bash
# Install buildx
docker buildx install

# Create builder
docker buildx create --name mlos-builder --use
```

### Platform Not Supported

If ARM64 builds fail, ensure your Docker installation supports multi-platform builds:

```bash
# Check available platforms
docker buildx inspect mlos-builder
```

### Build Fails in Docker

Check the build logs:

```bash
# Build with verbose output
docker build --progress=plain -t mlos-core:test .
```

## Future Enhancements

- [ ] Add Windows container support
- [ ] Optimize image size (use distroless/alpine)
- [ ] Add build caching for faster CI
- [ ] Support for more architectures (ppc64le, s390x)

