package report

import (
	"encoding/json"
	"fmt"
	"html/template"
	"os"
	"strings"
	"time"

	"github.com/mlOS-foundation/system-test/internal/config"
	"github.com/mlOS-foundation/system-test/internal/test"
)

// Generator generates HTML reports
type Generator struct {
	cfg *config.Config
}

// NewGenerator creates a new report generator
func NewGenerator(cfg *config.Config) *Generator {
	return &Generator{cfg: cfg}
}

// Generate generates an HTML report from test results
func (g *Generator) Generate(results *test.Results) (string, error) {
	// Load HTML template
	tmpl, err := template.New("report").Parse(reportTemplate)
	if err != nil {
		return "", fmt.Errorf("failed to parse template: %w", err)
	}

	// Prepare template data
	data := prepareTemplateData(results, g.cfg)

	// Generate report
	reportPath := g.cfg.ReportPath
	file, err := os.Create(reportPath)
	if err != nil {
		return "", fmt.Errorf("failed to create report file: %w", err)
	}
	defer file.Close()

	if err := tmpl.Execute(file, data); err != nil {
		return "", fmt.Errorf("failed to execute template: %w", err)
	}

	return reportPath, nil
}

func prepareTemplateData(results *test.Results, cfg *config.Config) map[string]interface{} {
	// Build inference data for charts
	inferenceLabels := []string{}
	inferenceData := []int64{}
	inferenceColors := []string{}

	metricsHTML := ""
	totalInferenceTime := int64(0)
	totalRegisterTime := int64(0)

	// Process each model
	testModels := getTestModels(cfg.TestAllModels)
	for _, spec := range testModels {
		if spec.Category != "nlp" {
			continue // Skip non-NLP for inference display
		}

		// Small inference
		if time, ok := results.Metrics.ModelInferenceTimes[spec.Name]; ok && time > 0 {
			displayName := getDisplayName(spec.Name)
			inferenceLabels = append(inferenceLabels, fmt.Sprintf("%s (small)", displayName))
			inferenceData = append(inferenceData, time)
			inferenceColors = append(inferenceColors, "rgba(102, 126, 234, 0.8)")

			status := results.Metrics.ModelInferenceStatus[spec.Name]
			statusClass := "success"
			statusText := "✅ Success"
			if status != "success" {
				statusClass = "failed"
				statusText = "❌ Failed"
			}

			metricsHTML += fmt.Sprintf(`
				<div class="metric-card %s">
					<h4>%s (small)</h4>
					<div class="metric-value">%d ms</div>
					<span class="status-badge %s">%s</span>
				</div>`, statusClass, displayName, time, statusClass, statusText)

			totalInferenceTime += time
		}

		// Large inference
		if time, ok := results.Metrics.ModelLargeInferenceTimes[spec.Name]; ok && time > 0 {
			displayName := getDisplayName(spec.Name)
			inferenceLabels = append(inferenceLabels, fmt.Sprintf("%s (large)", displayName))
			inferenceData = append(inferenceData, time)
			inferenceColors = append(inferenceColors, "rgba(118, 75, 162, 0.8)")

			status := results.Metrics.ModelLargeInferenceStatus[spec.Name]
			statusClass := "success"
			statusText := "✅ Success"
			if status != "success" {
				statusClass = "failed"
				statusText = "❌ Failed"
			}

			metricsHTML += fmt.Sprintf(`
				<div class="metric-card %s">
					<h4>%s (large)</h4>
					<div class="metric-value">%d ms</div>
					<span class="status-badge %s">%s</span>
				</div>`, statusClass, displayName, time, statusClass, statusText)

			totalInferenceTime += time
		}

		// Registration time
		if time, ok := results.Metrics.ModelRegistrationTimes[spec.Name]; ok {
			totalRegisterTime += time
		}
	}

	// Calculate category statuses
	categoryStatuses := calculateCategoryStatuses(results, testModels)

	// Format inference data as JSON for JavaScript
	inferenceLabelsJSON, _ := json.Marshal(inferenceLabels)
	inferenceDataJSON, _ := json.Marshal(inferenceData)
	inferenceColorsJSON, _ := json.Marshal(inferenceColors)

	// Determine summary card class
	summaryCardClass := "success"
	if results.SuccessRate < 100.0 {
		summaryCardClass = "warning"
	}

	// Format hardware specs
	hardwareSpecs := formatHardwareSpecs(results.HardwareSpecs)
	
	// Format resource usage
	resourceUsage := formatResourceUsage(results.ResourceUsage)

	return map[string]interface{}{
		"SuccessRate":           results.SuccessRate,
		"SummaryCardClass":      summaryCardClass,
		"TotalDuration":         results.Duration.Seconds(),
		"SuccessfulInferences":  results.Metrics.SuccessfulInferences,
		"TotalInferences":       results.Metrics.TotalInferences,
		"ModelsInstalled":       results.Metrics.ModelsInstalled,
		"AxonVersion":           results.AxonVersion,
		"CoreVersion":           results.CoreVersion,
		"AxonDownloadTime":      results.Metrics.AxonDownloadTimeMs,
		"CoreDownloadTime":      results.Metrics.CoreDownloadTimeMs,
		"CoreStartupTime":       results.Metrics.CoreStartupTimeMs,
		"InferenceLabelsJSON":   string(inferenceLabelsJSON),
		"InferenceDataJSON":     string(inferenceDataJSON),
		"InferenceColorsJSON":   string(inferenceColorsJSON),
		"InferenceMetricsHTML":  template.HTML(metricsHTML),
		"TotalInferenceTime":    totalInferenceTime,
		"TotalRegisterTime":     totalRegisterTime,
		"HardwareSpecs":         hardwareSpecs,
		"ResourceUsage":         resourceUsage,
		"CategoryStatuses":      categoryStatuses,
		"Timestamp":             time.Now().Format("2006-01-02 15:04:05"),
	}
}

func formatHardwareSpecs(specs map[string]string) map[string]string {
	if specs == nil {
		return nil
	}
	return specs
}

func formatResourceUsage(usage map[string]interface{}) map[string]interface{} {
	if usage == nil {
		return nil
	}
	
	formatted := make(map[string]interface{})
	
	// Handle idle resource usage
	if idleRaw, ok := usage["idle"]; ok {
		if idleMap, ok := idleRaw.(map[string]interface{}); ok {
			cpu, _ := idleMap["CPUPercent"].(float64)
			mem, _ := idleMap["MemoryMB"].(float64)
			formatted["Idle"] = map[string]float64{
				"CPU":    cpu,
				"Memory": mem,
			}
		}
	}
	
	// Handle under_load resource usage
	if loadRaw, ok := usage["under_load"]; ok {
		if loadMap, ok := loadRaw.(map[string]interface{}); ok {
			cpu, _ := loadMap["CPUPercent"].(float64)
			mem, _ := loadMap["MemoryMB"].(float64)
			formatted["UnderLoad"] = map[string]float64{
				"CPU":    cpu,
				"Memory": mem,
			}
		}
	}
	
	return formatted
}

func getDisplayName(modelName string) string {
	names := map[string]string{
		"gpt2":    "GPT-2",
		"bert":    "BERT",
		"roberta": "RoBERTa",
		"t5":      "T5",
		"resnet":  "ResNet",
		"vgg":     "VGG",
		"clip":    "CLIP",
	}
	if name, ok := names[modelName]; ok {
		return name
	}
	return strings.ToUpper(modelName)
}

func calculateCategoryStatuses(results *test.Results, models []test.ModelSpec) map[string]interface{} {
	categories := map[string]int{"nlp": 0, "vision": 0, "multimodal": 0}
	categoryPassed := map[string]int{"nlp": 0, "vision": 0, "multimodal": 0}

	for _, spec := range models {
		categories[spec.Category]++
		status := results.Metrics.ModelInferenceStatus[spec.Name]
		if status == "success" {
			categoryPassed[spec.Category]++
		}
	}

	statuses := make(map[string]interface{})
	
	for cat := range categories {
		var status, statusClass string
		total := categories[cat]
		passed := categoryPassed[cat]
		
		if total == 0 {
			status = "✅ Ready (not tested)"
			statusClass = "ready"
		} else if passed == total {
			status = "✅ Passing"
			statusClass = "success"
		} else {
			status = "❌ Failed"
			statusClass = "failed"
		}
		
		switch cat {
		case "nlp":
			statuses["NLPStatus"] = status
			statuses["NLPClass"] = statusClass
		case "vision":
			statuses["VisionStatus"] = status
			statuses["VisionClass"] = statusClass
		case "multimodal":
			statuses["MultimodalStatus"] = status
			statuses["MultimodalClass"] = statusClass
		}
	}

	return statuses
}

func getTestModels(testAllModels bool) []test.ModelSpec {
	models := []test.ModelSpec{
		{ID: "hf/distilgpt2@latest", Name: "gpt2", Type: "single", Category: "nlp"},
		{ID: "hf/bert-base-uncased@latest", Name: "bert", Type: "multi", Category: "nlp"},
	}

	if testAllModels {
		models = append(models,
			test.ModelSpec{ID: "hf/roberta-base@latest", Name: "roberta", Type: "multi", Category: "nlp"},
			test.ModelSpec{ID: "hf/t5-small@latest", Name: "t5", Type: "multi", Category: "nlp"},
			test.ModelSpec{ID: "hf/microsoft/resnet-50@latest", Name: "resnet", Type: "single", Category: "vision"},
			test.ModelSpec{ID: "hf/timm/vgg16@latest", Name: "vgg", Type: "single", Category: "vision"},
			test.ModelSpec{ID: "hf/openai/clip-vit-base-patch32@latest", Name: "clip", Type: "multi", Category: "multimodal"},
		)
	}

	return models
}

