# Go Tool vs Bash Script Parity Check

## Current Status

### Metrics Collected

#### Go Tool (`internal/test/runner.go`)
- ✅ Axon download time
- ✅ Core download time  
- ✅ Core startup time
- ✅ Models installed count
- ✅ Model registration times (per model)
- ✅ Model inference times (small, per model)
- ✅ Model large inference times (per model)
- ✅ Model inference status (success/failed)
- ✅ Hardware specs
- ✅ Resource usage
- ✅ Category statuses (nlp/vision/multimodal)

#### Bash Script (`scripts/test-release-e2e.sh.bash`)
- ✅ Axon download time
- ✅ Core download time
- ✅ Core startup time
- ✅ Models installed count
- ✅ Model registration times (per model)
- ✅ Model inference times (small, per model)
- ✅ Model large inference times (per model)
- ✅ Model inference status (success/failed)
- ✅ Hardware specs
- ✅ Resource usage
- ✅ Category statuses (nlp/vision/multimodal)

**Status: ✅ Metrics are aligned**

### Report Generation

#### Go Tool
- Uses React-based template (`report_template.html`)
- Uses `report_app.js` (React app)
- Generates `window.reportData` with structured JSON
- Template uses Go template syntax `[[.Field]]`

#### Bash Script
- Uses vanilla JS template (embedded in script)
- No React
- Different HTML structure
- Uses sed replacements for placeholders

**Status: ❌ Reports are NOT aligned**

## Required Changes

1. **Update bash script to use React template**
   - Use `internal/report/report_template.html`
   - Copy `internal/report/report_app.js` to report directory
   - Generate `window.reportData` in same format

2. **Ensure data structure matches**
   - Registration metrics array format
   - Inference metrics array format
   - Chart data (labels, data, colors) format
   - Hardware specs format
   - Resource usage format
   - Category statuses format

3. **Test both generate identical reports**
   - Same visual appearance
   - Same data displayed
   - Same charts rendered

## Implementation Plan

1. Create helper function to generate JSON data matching Go tool format
2. Update `generate_html_report()` to use React template
3. Copy `report_app.js` to report directory
4. Replace Go template placeholders with bash-generated JSON
5. Test both tools generate same report

