.PHONY: build install test clean run

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
	@go fmt ./...

# Lint code
lint:
	@golangci-lint run ./...

# Show version
version: build
	@./bin/e2e-test -version

