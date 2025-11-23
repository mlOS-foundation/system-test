package report

import (
	"encoding/json"
	"html/template"
	"time"

	"github.com/mlOS-foundation/system-test/internal/config"
	"github.com/mlOS-foundation/system-test/internal/test"
)

// ReportData holds all data needed for the report template
type ReportData struct {
	// Summary metrics
	SuccessRate          float64
	SummaryCardClass     string
	TotalDuration        float64
	SuccessfulInferences int
	TotalInferences      int
	ModelsInstalled      int

	// Versions
	AxonVersion string
	CoreVersion string

	// Installation times
	AxonDownloadTime int64
	CoreDownloadTime int64
	CoreStartupTime  int64

	// Model metrics
	RegistrationMetrics []ModelMetric
	InferenceMetrics    []ModelMetric

	// Chart data
	InferenceLabelsJSON template.JS
	InferenceDataJSON   template.JS
	InferenceColorsJSON template.JS

	// Totals
	TotalInferenceTime int64
	TotalRegisterTime  int64

	// Hardware
	HardwareSpecs map[string]string

	// Resources
	ResourceUsage map[string]interface{}

	// Categories
	CategoryStatuses map[string]interface{}

	// Timestamp
	Timestamp string
}

// ModelMetric represents a single model metric
type ModelMetric struct {
	Name       string `json:"name"`
	Value      int64  `json:"value"`
	Status     string `json:"status"` // "success", "failed", "ready"
	StatusText string `json:"statusText"`
	Type       string `json:"type"` // "registration", "inference-small", "inference-large"
}

// PrepareData creates a ReportData structure from test results
func PrepareData(results *test.Results, cfg *config.Config) *ReportData {
	data := &ReportData{
		SuccessRate:          results.SuccessRate,
		TotalDuration:        results.Duration.Seconds(),
		SuccessfulInferences: results.Metrics.SuccessfulInferences,
		TotalInferences:      results.Metrics.TotalInferences,
		ModelsInstalled:      results.Metrics.ModelsInstalled,
		AxonVersion:          results.AxonVersion,
		CoreVersion:          results.CoreVersion,
		AxonDownloadTime:     results.Metrics.AxonDownloadTimeMs,
		CoreDownloadTime:     results.Metrics.CoreDownloadTimeMs,
		CoreStartupTime:      results.Metrics.CoreStartupTimeMs,
		HardwareSpecs:        formatHardwareSpecs(results.HardwareSpecs),
		ResourceUsage:        formatResourceUsage(results.ResourceUsage),
		Timestamp:            time.Now().Format("2006-01-02 15:04:05"),
	}

	// Determine summary card class
	if data.SuccessRate < 100.0 {
		data.SummaryCardClass = "warning"
	} else {
		data.SummaryCardClass = "success"
	}

	// Build model metrics
	testModels := getTestModels(cfg.TestAllModels)
	data.RegistrationMetrics = buildRegistrationMetrics(results, testModels)
	data.InferenceMetrics = buildInferenceMetrics(results, testModels)

	// Calculate totals
	for _, m := range data.RegistrationMetrics {
		data.TotalRegisterTime += m.Value
	}
	for _, m := range data.InferenceMetrics {
		data.TotalInferenceTime += m.Value
	}

	// Build chart data
	data.InferenceLabelsJSON, data.InferenceDataJSON, data.InferenceColorsJSON = buildChartData(data.InferenceMetrics)

	// Calculate category statuses
	data.CategoryStatuses = calculateCategoryStatuses(results, testModels)

	return data
}

func buildRegistrationMetrics(results *test.Results, models []test.ModelSpec) []ModelMetric {
	var metrics []ModelMetric
	for _, spec := range models {
		if spec.Category != "nlp" {
			continue
		}
		if regTime, ok := results.Metrics.ModelRegistrationTimes[spec.Name]; ok && regTime > 0 {
			metrics = append(metrics, ModelMetric{
				Name:       getDisplayName(spec.Name),
				Value:      regTime,
				Status:     "success",
				StatusText: "✅ Success",
				Type:       "registration",
			})
		}
	}
	return metrics
}

func buildInferenceMetrics(results *test.Results, models []test.ModelSpec) []ModelMetric {
	var metrics []ModelMetric
	for _, spec := range models {
		if spec.Category != "nlp" {
			continue
		}

		// Small inference
		if time, ok := results.Metrics.ModelInferenceTimes[spec.Name]; ok && time > 0 {
			status := results.Metrics.ModelInferenceStatus[spec.Name]
			statusText := "✅ Success"
			if status != "success" {
				statusText = "❌ Failed"
			}
			metrics = append(metrics, ModelMetric{
				Name:       getDisplayName(spec.Name),
				Value:      time,
				Status:     status,
				StatusText: statusText,
				Type:       "inference-small",
			})
		}

		// Large inference
		if time, ok := results.Metrics.ModelLargeInferenceTimes[spec.Name]; ok && time > 0 {
			status := results.Metrics.ModelLargeInferenceStatus[spec.Name]
			statusText := "✅ Success"
			if status != "success" {
				statusText = "❌ Failed"
			}
			metrics = append(metrics, ModelMetric{
				Name:       getDisplayName(spec.Name),
				Value:      time,
				Status:     status,
				StatusText: statusText,
				Type:       "inference-large",
			})
		}
	}
	return metrics
}

func buildChartData(metrics []ModelMetric) (template.JS, template.JS, template.JS) {
	labels := []string{}
	data := []int64{}
	colors := []string{}

	for _, m := range metrics {
		if m.Type == "inference-small" {
			labels = append(labels, m.Name+" (small)")
			data = append(data, m.Value)
			colors = append(colors, "rgba(102, 126, 234, 0.8)")
		} else if m.Type == "inference-large" {
			labels = append(labels, m.Name+" (large)")
			data = append(data, m.Value)
			colors = append(colors, "rgba(118, 75, 162, 0.8)")
		}
	}

	labelsJSON, _ := json.Marshal(labels)
	dataJSON, _ := json.Marshal(data)
	colorsJSON, _ := json.Marshal(colors)

	return template.JS(labelsJSON), template.JS(dataJSON), template.JS(colorsJSON)
}
