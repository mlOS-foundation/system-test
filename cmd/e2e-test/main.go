package main

import (
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/mlOS-foundation/system-test/internal/config"
	"github.com/mlOS-foundation/system-test/internal/report"
	"github.com/mlOS-foundation/system-test/internal/test"
)

var (
	version = "dev"
	commit  = "unknown"
	date    = "unknown"
)

func main() {
	var (
		axonVersion   = flag.String("axon-version", "v3.0.0", "Axon release version to test")
		coreVersion   = flag.String("core-version", "v2.3.0-alpha", "MLOS Core release version to test")
		outputDir     = flag.String("output", "", "Output directory for reports (default: ./e2e-results-<timestamp>)")
		testAllModels = flag.Bool("all-models", false, "Test all models including vision and multimodal")
		minimalTest   = flag.Bool("minimal", false, "Minimal test: only one small model (for CI smoke tests)")
		skipInstall   = flag.Bool("skip-install", false, "Skip downloading and installing releases")
		showVersion   = flag.Bool("version", false, "Show version information")
		verbose       = flag.Bool("verbose", false, "Enable verbose logging")
	)
	flag.Parse()

	if *showVersion {
		fmt.Printf("MLOS System Test v%s\n", version)
		fmt.Printf("Commit: %s\n", commit)
		fmt.Printf("Build Date: %s\n", date)
		os.Exit(0)
	}

	// Initialize configuration
	cfg, err := config.New(*axonVersion, *coreVersion, *outputDir, *testAllModels, *minimalTest, *skipInstall, *verbose)
	if err != nil {
		log.Fatalf("Failed to initialize configuration: %v", err)
	}

	// Create test runner
	runner := test.NewRunner(cfg)

	// Run E2E tests
	log.Printf("🚀 Starting MLOS Release E2E Validation")
	log.Printf("   Axon: %s", cfg.AxonVersion)
	log.Printf("   Core: %s", cfg.CoreVersion)
	log.Printf("   Output: %s", cfg.OutputDir)

	results, err := runner.Run()
	if err != nil {
		log.Fatalf("E2E test failed: %v", err)
	}

	// Generate HTML report
	log.Printf("📊 Generating HTML report...")
	reportGen := report.NewGenerator(cfg)
	reportPath, err := reportGen.Generate(results)
	if err != nil {
		log.Fatalf("Failed to generate report: %v", err)
	}

	// Print summary
	printSummary(results, reportPath)

	if results.SuccessRate < 100.0 {
		os.Exit(1)
	}
}

func printSummary(results *test.Results, reportPath string) {
	fmt.Println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Println("📊 Test Summary")
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Printf("Test completed in %.1fs\n", results.Duration.Seconds())
	fmt.Println()
	fmt.Println("Release Versions:")
	fmt.Printf("  - Axon: %s\n", results.AxonVersion)
	fmt.Printf("  - Core: %s\n", results.CoreVersion)
	fmt.Println()
	fmt.Println("Installation:")
	fmt.Printf("  - Axon download: %dms\n", results.Metrics.AxonDownloadTimeMs)
	fmt.Printf("  - Core download: %dms\n", results.Metrics.CoreDownloadTimeMs)
	fmt.Printf("  - Core startup: %dms\n", results.Metrics.CoreStartupTimeMs)
	fmt.Printf("  - Models installed: %d\n", results.Metrics.ModelsInstalled)
	fmt.Println()
	fmt.Println("Inference:")
	fmt.Printf("  - Total tests: %d\n", results.Metrics.TotalInferences)
	fmt.Printf("  - Successful: %d\n", results.Metrics.SuccessfulInferences)
	fmt.Printf("  - Success rate: %.1f%%\n", results.SuccessRate)
	fmt.Println()
	fmt.Printf("📄 Report: %s\n", reportPath)
	fmt.Println()

	if results.SuccessRate == 100.0 {
		fmt.Println("✅ ALL TESTS PASSED!")
	} else {
		fmt.Println("❌ SOME TESTS FAILED")
	}
	fmt.Println()
}
