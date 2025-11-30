# MLOS System Test Makefile
# Commands for running E2E tests and generating reports

.PHONY: all test render serve clean lint help

# Default target
all: help

# =============================================================================
# E2E Testing
# =============================================================================

## test: Run full E2E test suite (generates metrics.json)
test:
	@echo "🧪 Running E2E tests..."
	@chmod +x scripts/test-release-e2e.sh.bash
	@cd scripts && ./test-release-e2e.sh.bash
	@python3 scripts/generate-metrics.py
	@echo "✅ Tests complete. Metrics saved to scripts/metrics/latest.json"

## test-quick: Run tests with only GPT-2 (fast validation)
test-quick:
	@echo "⚡ Running quick E2E test (GPT-2 only)..."
	@cd scripts && QUICK_TEST=1 ./test-release-e2e.sh.bash
	@python3 scripts/generate-metrics.py
	@echo "✅ Quick test complete."

# =============================================================================
# Report Generation
# =============================================================================

## render: Render HTML report from existing metrics
render:
	@echo "🎨 Rendering report..."
	@python3 report/render.py \
		--metrics scripts/metrics/latest.json \
		--template report/template.html \
		--output output/index.html
	@cp report/styles.css output/
	@echo "✅ Report generated at output/index.html"

## render-example: Render report using example metrics (for testing)
render-example:
	@echo "🎨 Rendering example report..."
	@python3 report/render.py \
		--metrics scripts/metrics/example.json \
		--template report/template.html \
		--output output/index.html
	@cp report/styles.css output/
	@echo "✅ Example report generated at output/index.html"

# =============================================================================
# Local Development
# =============================================================================

## serve: Start local HTTP server for report preview
serve:
	@echo "🌐 Starting local server at http://localhost:8080"
	@echo "   Press Ctrl+C to stop"
	@cd output && python3 -m http.server 8080

## watch: Auto-render on file changes (requires entr)
watch:
	@echo "👀 Watching for changes..."
	@ls report/*.py report/*.html report/*.css scripts/metrics/*.json | entr -c make render

# =============================================================================
# Configuration
# =============================================================================

## config: Show current model configuration
config:
	@python3 scripts/load-config.py

## config-list: List enabled models
config-list:
	@python3 scripts/load-config.py --list

## config-all: Show all model details (JSON)
config-all:
	@python3 scripts/load-config.py --all

## config-edit: Open models.yaml in editor
config-edit:
	@$${EDITOR:-nano} config/models.yaml

# =============================================================================
# Maintenance
# =============================================================================

## clean: Remove generated files
clean:
	@echo "🧹 Cleaning generated files..."
	@rm -rf output/*
	@rm -f scripts/metrics/latest.json
	@echo "✅ Clean complete"

## lint: Lint Python and bash scripts
lint:
	@echo "🔍 Linting..."
	@python3 -m py_compile report/render.py && echo "  ✓ Python OK"
	@bash -n scripts/test-release-e2e.sh.bash 2>/dev/null && echo "  ✓ Bash OK" || echo "  ✗ Bash has issues"
	@echo "✅ Lint complete"

## check: Verify metrics JSON is valid
check:
	@echo "🔎 Checking metrics..."
	@python3 -c "import json; json.load(open('scripts/metrics/latest.json')); print('  ✓ JSON valid')" 2>/dev/null || echo "  ✗ No metrics file or invalid JSON"

# =============================================================================
# CI/CD Helpers
# =============================================================================

## ci-test: Full CI pipeline (test + render)
ci-test: test render
	@echo "✅ CI pipeline complete"

## ci-render: CI render only (uses existing metrics)
ci-render: render
	@echo "✅ CI render complete"

# =============================================================================
# Go Build (legacy)
# =============================================================================

## build: Build Go test binary (legacy)
build:
	@echo "🔨 Building Go binary..."
	@go build -o bin/e2e-test ./cmd/e2e-test
	@echo "✅ Build complete"

# =============================================================================
# Help
# =============================================================================

## help: Show this help message
help:
	@echo ""
	@echo "MLOS System Test - E2E Validation Framework"
	@echo "============================================"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Testing:"
	@echo "  test          Run full E2E test suite"
	@echo "  test-quick    Quick test (GPT-2 only)"
	@echo ""
	@echo "Report Generation:"
	@echo "  render        Render HTML from metrics.json"
	@echo "  render-example  Render using example data"
	@echo "  serve         Start local preview server"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean         Remove generated files"
	@echo "  lint          Check Python/Bash syntax"
	@echo "  check         Validate metrics JSON"
	@echo ""
	@echo "CI/CD:"
	@echo "  ci-test       Full pipeline (test + render)"
	@echo "  ci-render     Render only (existing metrics)"
	@echo ""
