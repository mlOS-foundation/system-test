.PHONY: build install test clean run check vet lint fmt ci

# Build the E2E test tool
build:
	@echo "Building e2e-test..."
	@go build -o bin/e2e-test ./cmd/e2e-test

# Install the tool
install: build
	@echo "Installing e2e-test..."
	@cp bin/e2e-test ~/.local/bin/e2e-test
	@echo "✅ Installed to ~/.local/bin/e2e-test"

# Run tests
test:
	@echo "Running tests..."
	@go test ./...

# Run E2E test (default versions)
run: build
	@echo "Running E2E test..."
	@sudo ./bin/e2e-test

# Run E2E test with all models
run-all: build
	@echo "Running E2E test with all models..."
	@sudo ./bin/e2e-test -all-models

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@rm -rf bin/
	@rm -rf e2e-results-*/

# Format code
fmt:
	@echo "Formatting code..."
	@go fmt ./...
	@echo "✅ Code formatted"

# Run go vet
vet:
	@echo "Running go vet..."
	@go vet ./...
	@echo "✅ go vet passed"

# Lint code
lint:
	@echo "Running golangci-lint..."
	@golangci-lint run --timeout=5m ./...
	@echo "✅ golangci-lint passed"

# Run all checks
check: vet lint fmt build
	@echo "✅ All checks passed!"

# Run full CI checks
ci: check
	@echo "✅ CI checks complete!"

# Show version
version: build
	@./bin/e2e-test -version

