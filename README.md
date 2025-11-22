# MLOS System Test

End-to-end integration testing framework for MLOS Foundation releases (Axon + Core).

## Overview

This repository contains a Go-based E2E testing framework that validates MLOS Foundation releases by:
- Downloading and installing Axon and MLOS Core release binaries
- Installing test models using Axon
- Starting MLOS Core server
- Running inference tests across multiple models
- Collecting hardware specifications and resource usage metrics
- Generating comprehensive HTML reports

## Structure

```
system-test/
├── cmd/
│   └── e2e-test/          # Main CLI application
├── internal/
│   ├── config/            # Configuration management
│   ├── test/              # Test runner and types
│   ├── release/           # Release download and management
│   ├── model/             # Model installation and inference
│   ├── hardware/          # Hardware specification collection
│   ├── monitor/           # Resource usage monitoring
│   └── report/            # HTML report generation
├── scripts/
│   └── test-release-e2e.sh.bash  # Original bash script (reference)
└── README.md
```

## Usage

### Basic Usage

```bash
# Test latest releases
go run ./cmd/e2e-test

# Test specific versions
go run ./cmd/e2e-test -axon-version v3.0.0 -core-version v2.3.0-alpha

# Test all models (including vision and multimodal)
go run ./cmd/e2e-test -all-models

# Skip installation (use existing binaries)
go run ./cmd/e2e-test -skip-install
```

### Build and Install

```bash
# Build binary
go build -o bin/e2e-test ./cmd/e2e-test

# Install
go install ./cmd/e2e-test
```

### Command Line Options

- `-axon-version`: Axon release version to test (default: v3.0.0)
- `-core-version`: MLOS Core release version to test (default: v2.3.0-alpha)
- `-output`: Output directory for reports (default: ./e2e-results-<timestamp>)
- `-all-models`: Test all models including vision and multimodal
- `-skip-install`: Skip downloading and installing releases
- `-verbose`: Enable verbose logging
- `-version`: Show version information

## Test Models

### Essential NLP Models (Always Tested)
- GPT-2 (`hf/distilgpt2@latest`)
- BERT (`hf/bert-base-uncased@latest`)

### Additional Models (Tested with `-all-models`)
- RoBERTa (`hf/roberta-base@latest`)
- T5 (`hf/t5-small@latest`)
- ResNet (`hf/microsoft/resnet-50@latest`)
- VGG (`hf/timm/vgg16@latest`)
- CLIP (`hf/openai/clip-vit-base-patch32@latest`)

## Output

The test generates:
- **HTML Report**: Comprehensive validation report with metrics, charts, and status indicators
- **Log File**: Detailed test execution log
- **Metrics JSON**: Structured metrics data (future)

## GitHub Actions Integration

This framework is designed to be integrated with GitHub Actions to automatically test releases. See `.github/workflows/` for workflow definitions.

## Requirements

- Go 1.21+
- `gh` CLI (for downloading releases)
- `curl` (for HTTP requests)
- `sudo` access (for starting MLOS Core server)
- Network access to download releases and models

## Development

### Adding New Test Models

Edit `internal/test/runner.go` and add model specs to the `getTestModels()` function.

### Extending Report Generation

Modify `internal/report/generator.go` to add new sections or metrics to the HTML report.

### Adding New Metrics

Extend `internal/test/types.go` to add new metric fields, then update the runner to collect them.

## License

See LICENSE file.

