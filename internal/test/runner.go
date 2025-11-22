package test

import (
	"fmt"
	"log"
	"time"

	"github.com/mlOS-foundation/system-test/internal/config"
	"github.com/mlOS-foundation/system-test/internal/hardware"
	"github.com/mlOS-foundation/system-test/internal/model"
	"github.com/mlOS-foundation/system-test/internal/monitor"
	"github.com/mlOS-foundation/system-test/internal/release"
)

// Runner executes E2E tests
type Runner struct {
	cfg *config.Config
}

// NewRunner creates a new test runner
func NewRunner(cfg *config.Config) *Runner {
	return &Runner{cfg: cfg}
}

// Run executes all E2E tests and returns results
func (r *Runner) Run() (*Results, error) {
	results := NewResults(r.cfg.AxonVersion, r.cfg.CoreVersion)
	results.StartTime = time.Now()

	log.Printf("🚀 Starting MLOS Release E2E Validation")
	log.Printf("   Axon: %s", r.cfg.AxonVersion)
	log.Printf("   Core: %s", r.cfg.CoreVersion)

	// Step 1: Download releases
	if !r.cfg.SkipInstall {
		if err := r.downloadReleases(results); err != nil {
			return nil, fmt.Errorf("failed to download releases: %w", err)
		}
	}

	// Step 2: Install models
	if err := r.installModels(results); err != nil {
		return nil, fmt.Errorf("failed to install models: %w", err)
	}

	// Step 3: Start MLOS Core
	coreProcess, err := r.startCore(results)
	if err != nil {
		return nil, fmt.Errorf("failed to start Core: %w", err)
	}
	defer func() {
		if coreProcess != nil {
			log.Printf("WARN: Cleaning up...")
			if err := monitor.StopProcess(coreProcess); err != nil {
				log.Printf("WARN: Failed to stop Core process: %v", err)
			}
		}
	}()

	// Step 4: Collect hardware specs
	if err := r.collectHardwareSpecs(results); err != nil {
		log.Printf("WARN: Failed to collect hardware specs: %v", err)
	}

	// Step 5: Monitor resources (idle)
	if err := r.monitorResources(results, coreProcess, false); err != nil {
		log.Printf("WARN: Failed to monitor idle resources: %v", err)
	}

	// Step 6: Register models
	if err := r.registerModels(results); err != nil {
		return nil, fmt.Errorf("failed to register models: %w", err)
	}

	// Step 7: Run inference tests
	if err := r.runInferenceTests(results); err != nil {
		return nil, fmt.Errorf("failed to run inference tests: %w", err)
	}

	// Step 8: Monitor resources (under load)
	if err := r.monitorResources(results, coreProcess, true); err != nil {
		log.Printf("WARN: Failed to monitor resources under load: %v", err)
	}

	// Calculate final metrics
	results.EndTime = time.Now()
	results.Duration = results.EndTime.Sub(results.StartTime)
	results.SuccessRate = r.calculateSuccessRate(results)

	return results, nil
}

func (r *Runner) downloadReleases(results *Results) error {
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Printf("📦 Downloading Releases")
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	// Download Axon
	start := time.Now()
	if err := release.DownloadAxon(r.cfg.AxonVersion, r.cfg.OutputDir); err != nil {
		return fmt.Errorf("failed to download Axon: %w", err)
	}
	results.Metrics.AxonDownloadTimeMs = time.Since(start).Milliseconds()
	log.Printf("✅ Axon downloaded (%dms)", results.Metrics.AxonDownloadTimeMs)

	// Download Core
	start = time.Now()
	if err := release.DownloadCore(r.cfg.CoreVersion, r.cfg.OutputDir); err != nil {
		return fmt.Errorf("failed to download Core: %w", err)
	}
	results.Metrics.CoreDownloadTimeMs = time.Since(start).Milliseconds()
	log.Printf("✅ Core downloaded (%dms)", results.Metrics.CoreDownloadTimeMs)

	return nil
}

func (r *Runner) installModels(results *Results) error {
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Printf("📥 Installing Test Models with Axon")
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	testModels := r.getTestModels()

	for _, spec := range testModels {
		installed, err := model.Install(spec.ID, r.cfg.TestAllModels)
		if err != nil {
			log.Printf("WARN: Failed to install %s: %v", spec.ID, err)
			continue
		}
		// Count model if it was just installed OR if it was already installed
		// (Install returns false if already installed, but we still want to count it)
		if installed {
			results.Metrics.ModelsInstalled++
			log.Printf("✅ Installed %s", spec.ID)
		} else {
			// Check if model exists (was already installed)
			if modelPath, err := model.GetPath(spec.ID); err == nil {
				results.Metrics.ModelsInstalled++
				log.Printf("✅ Model already installed: %s at %s", spec.ID, modelPath)
			}
		}
	}

	log.Printf("✅ Installed %d models", results.Metrics.ModelsInstalled)
	return nil
}

func (r *Runner) startCore(results *Results) (*monitor.Process, error) {
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Printf("🚀 Starting MLOS Core Server")
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Printf("Using port %d (non-privileged, no sudo required)", r.cfg.CorePort)

	start := time.Now()
	process, err := release.StartCore(r.cfg.CoreVersion, r.cfg.OutputDir, r.cfg.CorePort)
	if err != nil {
		return nil, err
	}

	results.Metrics.CoreStartupTimeMs = time.Since(start).Milliseconds()
	log.Printf("✅ MLOS Core ready on port %d (%dms)", r.cfg.CorePort, results.Metrics.CoreStartupTimeMs)

	return process, nil
}

func (r *Runner) registerModels(results *Results) error {
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Printf("📝 Registering Models with MLOS Core")
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	testModels := r.getTestModels()
	for _, spec := range testModels {
		start := time.Now()
		modelPath, err := model.GetPath(spec.ID)
		if err != nil {
			log.Printf("WARN: Model %s not found, skipping registration", spec.ID)
			continue
		}

		if err := model.Register(spec.Name, modelPath, r.cfg.CorePort); err != nil {
			log.Printf("ERROR: Failed to register %s: %v", spec.Name, err)
			continue
		}

		results.Metrics.ModelRegistrationTimes[spec.Name] = time.Since(start).Milliseconds()
		log.Printf("✅ Registered %s (%dms)", spec.Name, results.Metrics.ModelRegistrationTimes[spec.Name])
	}

	log.Printf("✅ Registered %d models", len(results.Metrics.ModelRegistrationTimes))
	return nil
}

func (r *Runner) runInferenceTests(results *Results) error {
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Printf("🧪 Running Inference Tests")
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	testModels := r.getTestModels()
	for _, spec := range testModels {
		// Skip vision and multimodal for now (can be enabled later)
		if spec.Category != "nlp" {
			continue
		}

		// Small inference test
		start := time.Now()
		err := model.RunInference(spec.Name, spec.Type, false, r.cfg.CorePort)
		elapsed := time.Since(start).Milliseconds()
		results.Metrics.TotalInferences++

		if err != nil {
			results.Metrics.FailedInferences++
			results.Metrics.ModelInferenceStatus[spec.Name] = "failed"
			log.Printf("ERROR: %s inference failed: %v", spec.Name, err)
		} else {
			results.Metrics.SuccessfulInferences++
			results.Metrics.ModelInferenceTimes[spec.Name] = elapsed
			results.Metrics.ModelInferenceStatus[spec.Name] = "success"
			log.Printf("✅ %s inference succeeded (%dms)", spec.Name, elapsed)
		}

		// Large inference test
		start = time.Now()
		err = model.RunInference(spec.Name, spec.Type, true, r.cfg.CorePort)
		elapsed = time.Since(start).Milliseconds()
		results.Metrics.TotalInferences++

		if err != nil {
			results.Metrics.FailedInferences++
			results.Metrics.ModelLargeInferenceStatus[spec.Name] = "failed"
			log.Printf("ERROR: %s large inference failed: %v", spec.Name, err)
		} else {
			results.Metrics.SuccessfulInferences++
			results.Metrics.ModelLargeInferenceTimes[spec.Name] = elapsed
			results.Metrics.ModelLargeInferenceStatus[spec.Name] = "success"
			log.Printf("✅ %s large inference succeeded (%dms)", spec.Name, elapsed)
		}
	}

	log.Printf("✅ Completed %d/%d inference tests", 
		results.Metrics.SuccessfulInferences, results.Metrics.TotalInferences)
	return nil
}

func (r *Runner) collectHardwareSpecs(results *Results) error {
	specs, err := hardware.Collect()
	if err != nil {
		return err
	}
	results.HardwareSpecs = specs
	return nil
}

func (r *Runner) monitorResources(results *Results, process *monitor.Process, underLoad bool) error {
	usage, err := monitor.MonitorProcess(process, 5*time.Second)
	if err != nil {
		return err
	}

	key := "idle"
	if underLoad {
		key = "under_load"
	}
	// Store as map for JSON serialization
	results.ResourceUsage[key] = map[string]interface{}{
		"CPUPercent":    usage.CPUPercent,
		"MemoryMB":      usage.MemoryMB,
		"MemoryPercent": usage.MemoryPercent,
	}
	return nil
}

func (r *Runner) calculateSuccessRate(results *Results) float64 {
	if results.Metrics.TotalInferences == 0 {
		return 0.0
	}
	return float64(results.Metrics.SuccessfulInferences) / float64(results.Metrics.TotalInferences) * 100.0
}

func (r *Runner) getTestModels() []ModelSpec {
	// Essential NLP models (always tested)
	models := []ModelSpec{
		{ID: "hf/distilgpt2@latest", Name: "gpt2", Type: "single", Category: "nlp"},
		{ID: "hf/bert-base-uncased@latest", Name: "bert", Type: "multi", Category: "nlp"},
	}

	// Additional models if enabled
	if r.cfg.TestAllModels {
		models = append(models,
			ModelSpec{ID: "hf/roberta-base@latest", Name: "roberta", Type: "multi", Category: "nlp"},
			ModelSpec{ID: "hf/t5-small@latest", Name: "t5", Type: "multi", Category: "nlp"},
			ModelSpec{ID: "hf/microsoft/resnet-50@latest", Name: "resnet", Type: "single", Category: "vision"},
			ModelSpec{ID: "hf/timm/vgg16@latest", Name: "vgg", Type: "single", Category: "vision"},
			ModelSpec{ID: "hf/openai/clip-vit-base-patch32@latest", Name: "clip", Type: "multi", Category: "multimodal"},
		)
	}

	return models
}

