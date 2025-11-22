package report

import (
	"fmt"
	"html/template"
	"os"
	"strings"

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
	tmpl, err := loadTemplate()
	if err != nil {
		return "", fmt.Errorf("failed to load template: %w", err)
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

	return map[string]interface{}{
		"SuccessRate":           results.SuccessRate,
		"TotalDuration":        results.Duration.Seconds(),
		"SuccessfulInferences": results.Metrics.SuccessfulInferences,
		"TotalInferences":      results.Metrics.TotalInferences,
		"ModelsInstalled":      results.Metrics.ModelsInstalled,
		"AxonVersion":          results.AxonVersion,
		"CoreVersion":          results.CoreVersion,
		"AxonDownloadTime":     results.Metrics.AxonDownloadTimeMs,
		"CoreDownloadTime":     results.Metrics.CoreDownloadTimeMs,
		"CoreStartupTime":      results.Metrics.CoreStartupTimeMs,
		"InferenceLabels":      inferenceLabels,
		"InferenceData":        inferenceData,
		"InferenceColors":      inferenceColors,
		"InferenceMetricsHTML": template.HTML(metricsHTML),
		"TotalInferenceTime":   totalInferenceTime,
		"TotalRegisterTime":    totalRegisterTime,
		"HardwareSpecs":        results.HardwareSpecs,
		"ResourceUsage":        results.ResourceUsage,
		"CategoryStatuses":    categoryStatuses,
	}
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

func calculateCategoryStatuses(results *test.Results, models []test.ModelSpec) map[string]string {
	statuses := make(map[string]string)
	categories := map[string]int{"nlp": 0, "vision": 0, "multimodal": 0}
	categoryPassed := map[string]int{"nlp": 0, "vision": 0, "multimodal": 0}

	for _, spec := range models {
		categories[spec.Category]++
		status := results.Metrics.ModelInferenceStatus[spec.Name]
		if status == "success" {
			categoryPassed[spec.Category]++
		}
	}

	for cat, total := range categories {
		if total == 0 {
			statuses[cat] = "ready" // Ready but not tested
		} else if categoryPassed[cat] == total {
			statuses[cat] = "passing"
		} else {
			statuses[cat] = "failed"
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

func loadTemplate() (*template.Template, error) {
	// For now, return a simple template
	// In production, this should load from an embedded file or external template
	tmplStr := `<!DOCTYPE html>
<html>
<head>
	<title>MLOS Release Validation Report</title>
	<style>
		body { font-family: Arial, sans-serif; margin: 20px; }
		.metric-card { border: 1px solid #ddd; padding: 15px; margin: 10px; display: inline-block; }
		.success { background-color: #d4edda; }
		.failed { background-color: #f8d7da; }
	</style>
</head>
<body>
	<h1>MLOS Release Validation Report</h1>
	<p>Success Rate: {{.SuccessRate}}%</p>
	<p>Duration: {{.TotalDuration}}s</p>
	<p>Axon: {{.AxonVersion}}</p>
	<p>Core: {{.CoreVersion}}</p>
	<div>{{.InferenceMetricsHTML}}</div>
</body>
</html>`

	return template.New("report").Parse(tmplStr)
}

