package test

import (
	"time"
)

// ModelSpec represents a test model specification
type ModelSpec struct {
	ID       string // e.g., "hf/distilgpt2@latest"
	Name     string // e.g., "gpt2"
	Type     string // "single" or "multi"
	Category string // "nlp", "vision", "multimodal"
}

// Metrics holds all collected metrics
type Metrics struct {
	// Installation metrics
	AxonDownloadTimeMs int64
	CoreDownloadTimeMs int64
	CoreStartupTimeMs  int64
	ModelsInstalled    int

	// Inference metrics
	TotalInferences      int
	SuccessfulInferences int
	FailedInferences     int

	// Per-model inference metrics
	ModelInferenceTimes  map[string]int64  // model_name -> time_ms
	ModelInferenceStatus map[string]string // model_name -> "success" or "failed"

	// Large inference metrics
	ModelLargeInferenceTimes  map[string]int64
	ModelLargeInferenceStatus map[string]string

	// Registration metrics
	ModelRegistrationTimes map[string]int64 // model_name -> time_ms
}

// Results holds the complete test results
type Results struct {
	AxonVersion   string
	CoreVersion   string
	Duration      time.Duration
	SuccessRate   float64
	Metrics       *Metrics
	HardwareSpecs map[string]string
	ResourceUsage map[string]interface{}
	StartTime     time.Time
	EndTime       time.Time
}

// NewMetrics creates a new Metrics instance
func NewMetrics() *Metrics {
	return &Metrics{
		ModelInferenceTimes:       make(map[string]int64),
		ModelInferenceStatus:      make(map[string]string),
		ModelLargeInferenceTimes:  make(map[string]int64),
		ModelLargeInferenceStatus: make(map[string]string),
		ModelRegistrationTimes:    make(map[string]int64),
	}
}

// NewResults creates a new Results instance
func NewResults(axonVersion, coreVersion string) *Results {
	return &Results{
		AxonVersion:   axonVersion,
		CoreVersion:   coreVersion,
		Metrics:       NewMetrics(),
		HardwareSpecs: make(map[string]string),
		ResourceUsage: make(map[string]interface{}),
	}
}
