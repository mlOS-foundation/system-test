package report

import (
	_ "embed"
)

//go:embed report_template.html
var reportTemplate string

//go:embed report_app.js
var reportAppJS []byte
