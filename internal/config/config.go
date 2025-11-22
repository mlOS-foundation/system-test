package config

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Config holds all configuration for E2E tests
type Config struct {
	AxonVersion   string
	CoreVersion   string
	OutputDir     string
	TestAllModels bool
	SkipInstall   bool
	Verbose       bool
	
	// Derived paths
	TestDir       string
	ReportPath    string
	LogPath       string
	MetricsPath   string
}

// New creates a new configuration
func New(axonVersion, coreVersion, outputDir string, testAllModels, skipInstall, verbose bool) (*Config, error) {
	cfg := &Config{
		AxonVersion:   axonVersion,
		CoreVersion:   coreVersion,
		TestAllModels: testAllModels,
		SkipInstall:   skipInstall,
		Verbose:       verbose,
	}

	// Set output directory
	if outputDir == "" {
		timestamp := time.Now().Unix()
		outputDir = fmt.Sprintf("e2e-results-%d", timestamp)
	}
	cfg.OutputDir = outputDir

	// Create output directory
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create output directory: %w", err)
	}

	// Set derived paths
	cfg.TestDir = outputDir
	cfg.ReportPath = filepath.Join(outputDir, "release-validation-report.html")
	cfg.LogPath = filepath.Join(outputDir, "test.log")
	cfg.MetricsPath = filepath.Join(outputDir, "metrics.json")

	return cfg, nil
}

// Validate checks if the configuration is valid
func (c *Config) Validate() error {
	if c.AxonVersion == "" {
		return fmt.Errorf("axon version is required")
	}
	if c.CoreVersion == "" {
		return fmt.Errorf("core version is required")
	}
	return nil
}

