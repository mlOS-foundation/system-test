package hardware

import (
	"fmt"
	"os/exec"
	"runtime"
	"strings"
)

// Collect gathers hardware specifications
func Collect() (map[string]string, error) {
	specs := make(map[string]string)

	// OS and Architecture
	specs["os"] = runtime.GOOS
	specs["arch"] = runtime.GOARCH

	// CPU Info
	if cpuInfo, err := getCPUInfo(); err == nil {
		specs["cpu"] = cpuInfo
	} else {
		specs["cpu"] = "Unknown"
	}

	// Memory Info
	if memInfo, err := getMemoryInfo(); err == nil {
		specs["memory"] = memInfo
	} else {
		specs["memory"] = "Unknown"
	}

	// GPU Info (if available)
	if gpuInfo, err := getGPUInfo(); err == nil {
		specs["gpu"] = gpuInfo
	} else {
		specs["gpu"] = "None detected"
	}

	return specs, nil
}

func getCPUInfo() (string, error) {
	switch runtime.GOOS {
	case "darwin":
		cmd := exec.Command("sysctl", "-n", "machdep.cpu.brand_string")
		output, err := cmd.Output()
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(output)), nil
	case "linux":
		cmd := exec.Command("lscpu")
		output, err := cmd.Output()
		if err != nil {
			return "", err
		}
		// Extract model name
		lines := strings.Split(string(output), "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "Model name:") {
				return strings.TrimSpace(strings.TrimPrefix(line, "Model name:")), nil
			}
		}
		return "Unknown", nil
	default:
		return runtime.GOARCH, nil
	}
}

func getMemoryInfo() (string, error) {
	switch runtime.GOOS {
	case "darwin":
		cmd := exec.Command("sysctl", "-n", "hw.memsize")
		output, err := cmd.Output()
		if err != nil {
			return "", err
		}
		memBytes := strings.TrimSpace(string(output))
		// Convert to GB (simplified)
		return fmt.Sprintf("%s bytes", memBytes), nil
	case "linux":
		cmd := exec.Command("free", "-h")
		output, err := cmd.Output()
		if err != nil {
			return "", err
		}
		lines := strings.Split(string(output), "\n")
		if len(lines) > 1 {
			return strings.TrimSpace(lines[1]), nil
		}
		return "Unknown", nil
	default:
		return "Unknown", nil
	}
}

func getGPUInfo() (string, error) {
	// Try nvidia-smi first
	cmd := exec.Command("nvidia-smi", "--query-gpu=name", "--format=csv,noheader")
	output, err := cmd.Output()
	if err == nil {
		return strings.TrimSpace(string(output)), nil
	}

	// Try system_profiler on macOS
	if runtime.GOOS == "darwin" {
		cmd := exec.Command("system_profiler", "SPDisplaysDataType")
		output, err := cmd.Output()
		if err == nil {
			// Parse output for GPU name
			lines := strings.Split(string(output), "\n")
			for _, line := range lines {
				if strings.Contains(line, "Chipset Model:") {
					return strings.TrimSpace(strings.TrimPrefix(line, "Chipset Model:")), nil
				}
			}
		}
	}

	return "", fmt.Errorf("no GPU detected")
}
