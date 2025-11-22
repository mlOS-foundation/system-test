package model

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// RunInference runs an inference test for a model
func RunInference(modelID, modelType string, large bool) error {
	// Generate test input based on model type
	input, err := generateTestInput(modelID, modelType, large)
	if err != nil {
		return fmt.Errorf("failed to generate test input: %w", err)
	}

	// Prepare JSON payload
	payload, err := json.Marshal(input)
	if err != nil {
		return fmt.Errorf("failed to marshal input: %w", err)
	}

	// Make HTTP request
	url := fmt.Sprintf("http://localhost:8080/models/%s/inference", modelID)
	req, err := http.NewRequest("POST", url, strings.NewReader(string(payload)))
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{
		Timeout: 30 * time.Second,
	}

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("inference failed with status %d", resp.StatusCode)
	}

	// Parse response to check for errors
	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("failed to parse response: %w", err)
	}

	if status, ok := result["status"].(string); ok && status == "error" {
		return fmt.Errorf("inference error: %v", result["message"])
	}

	return nil
}

func generateTestInput(modelID, modelType string, large bool) (map[string]interface{}, error) {
	// Base token sequences for different models
	var inputIDs []int

	switch modelID {
	case "gpt2":
		if large {
			inputIDs = []int{15496, 11, 337, 43, 48, 2640, 0, 15496, 11, 337, 43, 48, 2640, 0, 15496, 11}
		} else {
			inputIDs = []int{15496, 11, 337, 43, 48, 2640, 0}
		}
		return map[string]interface{}{
			"input_ids": inputIDs,
		}, nil

	case "bert":
		if large {
			inputIDs = []int{101, 7592, 2088, 102, 101, 7592, 2088, 102, 101, 7592, 2088, 102, 101, 7592, 2088, 102}
		} else {
			inputIDs = []int{101, 7592, 2088, 102}
		}
		attentionMask := make([]int, len(inputIDs))
		for i := range attentionMask {
			attentionMask[i] = 1
		}
		tokenTypeIDs := make([]int, len(inputIDs))
		return map[string]interface{}{
			"input_ids":      inputIDs,
			"attention_mask": attentionMask,
			"token_type_ids": tokenTypeIDs,
		}, nil

	case "roberta":
		if large {
			inputIDs = []int{0, 31414, 232, 328, 2, 0, 31414, 232, 328, 2, 0, 31414, 232, 328, 2, 0}
		} else {
			inputIDs = []int{0, 31414, 232, 328, 2}
		}
		return map[string]interface{}{
			"input_ids": inputIDs,
		}, nil

	case "t5":
		if large {
			inputIDs = []int{37, 1962, 10, 37, 1962, 10, 37, 1962, 10, 37, 1962, 10, 37, 1962, 10, 37}
		} else {
			inputIDs = []int{37, 1962, 10}
		}
		return map[string]interface{}{
			"input_ids": inputIDs,
		}, nil

	default:
		// Default: single input with small sequence
		if large {
			inputIDs = []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
		} else {
			inputIDs = []int{1, 2, 3}
		}
		return map[string]interface{}{
			"input_ids": inputIDs,
		}, nil
	}
}

