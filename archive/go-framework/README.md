# Archived Go E2E Framework

This directory contains the original Go-based E2E testing framework that was 
developed but never fully utilized. The project now uses Bash scripts and 
Python for E2E testing.

## Why Archived?

1. **Not Used**: The main E2E workflow uses `scripts/test-release-e2e.sh.bash`
2. **Performance**: Go CI checks (vet, lint) added ~2-3 min to every workflow run
3. **Simplicity**: Bash + Python is sufficient for current needs

## Contents

- `cmd/e2e-test/` - Main Go binary (unused)
- `internal/` - Go modules for config, model, report, etc. (unused)
- `go.mod`, `go.sum` - Go module files

## Restoration

If needed in the future, move these files back to the repo root:
```bash
mv archive/go-framework/* .
```

Archived: December 2024
