package monitor

import (
	"fmt"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Process represents a running process to monitor
type Process struct {
	PID    int
	Cmd    *exec.Cmd
	Binary string
}

// ResourceUsage contains resource usage metrics
type ResourceUsage struct {
	CPUPercent    float64
	MemoryMB      float64
	MemoryPercent float64
}

// MonitorProcess monitors resource usage of a process
func MonitorProcess(process *Process, duration time.Duration) (*ResourceUsage, error) {
	if process == nil {
		return nil, fmt.Errorf("process is nil")
	}

	// Sample multiple times over the duration
	samples := 5
	interval := duration / time.Duration(samples)

	var totalCPU float64
	var totalMemory float64
	sampleCount := 0

	for i := 0; i < samples; i++ {
		cpu, mem, err := getProcessStats(process.PID)
		if err == nil {
			totalCPU += cpu
			totalMemory += mem
			sampleCount++
		}
		time.Sleep(interval)
	}

	if sampleCount == 0 {
		return nil, fmt.Errorf("failed to collect process stats")
	}

	avgCPU := totalCPU / float64(sampleCount)
	avgMemory := totalMemory / float64(sampleCount)

	// Get total system memory for percentage
	totalMem, err := getTotalMemory()
	if err != nil {
		totalMem = 0
	}

	memPercent := 0.0
	if totalMem > 0 {
		memPercent = (avgMemory / totalMem) * 100.0
	}

	return &ResourceUsage{
		CPUPercent:    avgCPU,
		MemoryMB:      avgMemory,
		MemoryPercent: memPercent,
	}, nil
}

// StopProcess stops a process
func StopProcess(process *Process) error {
	if process == nil {
		return nil
	}
	if process.Cmd != nil && process.Cmd.Process != nil {
		return process.Cmd.Process.Kill()
	}
	return nil
}

func getProcessStats(pid int) (cpuPercent, memoryMB float64, err error) {
	switch runtime.GOOS {
	case "darwin":
		return getProcessStatsDarwin(pid)
	case "linux":
		return getProcessStatsLinux(pid)
	default:
		return 0, 0, fmt.Errorf("unsupported OS")
	}
}

func getProcessStatsDarwin(pid int) (cpuPercent, memoryMB float64, err error) {
	// Use ps command
	cmd := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "pcpu,rss")
	output, err := cmd.Output()
	if err != nil {
		return 0, 0, err
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) < 2 {
		return 0, 0, fmt.Errorf("invalid ps output")
	}

	fields := strings.Fields(lines[1])
	if len(fields) < 2 {
		return 0, 0, fmt.Errorf("invalid ps output format")
	}

	cpu, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, 0, err
	}

	memKB, err := strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return 0, 0, err
	}

	memMB := memKB / 1024.0
	return cpu, memMB, nil
}

func getProcessStatsLinux(pid int) (float64, float64, error) {
	// Use ps command (similar to Darwin)
	cmd := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "pcpu,rss")
	output, err := cmd.Output()
	if err != nil {
		return 0, 0, err
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) < 2 {
		return 0, 0, fmt.Errorf("invalid ps output")
	}

	fields := strings.Fields(lines[1])
	if len(fields) < 2 {
		return 0, 0, fmt.Errorf("invalid ps output format")
	}

	cpu, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, 0, err
	}

	memKB, err := strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return 0, 0, err
	}

	memMB := memKB / 1024.0
	return cpu, memMB, nil
}

func getTotalMemory() (float64, error) {
	switch runtime.GOOS {
	case "darwin":
		cmd := exec.Command("sysctl", "-n", "hw.memsize")
		output, err := cmd.Output()
		if err != nil {
			return 0, err
		}
		memBytes, err := strconv.ParseFloat(strings.TrimSpace(string(output)), 64)
		if err != nil {
			return 0, err
		}
		return memBytes / (1024 * 1024), nil // Convert to MB
	case "linux":
		cmd := exec.Command("free", "-m")
		output, err := cmd.Output()
		if err != nil {
			return 0, err
		}
		lines := strings.Split(string(output), "\n")
		if len(lines) > 1 {
			fields := strings.Fields(lines[1])
			if len(fields) > 1 {
				total, err := strconv.ParseFloat(fields[1], 64)
				if err != nil {
					return 0, err
				}
				return total, nil
			}
		}
		return 0, fmt.Errorf("failed to parse free output")
	default:
		return 0, fmt.Errorf("unsupported OS")
	}
}
