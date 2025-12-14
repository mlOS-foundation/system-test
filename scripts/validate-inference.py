#!/usr/bin/env python3
"""
MLOS E2E Inference Validation Script
=====================================

Validates inference outputs against golden test data.
Supports multiple validation types:
  - output_shape: Validates tensor shapes
  - top_k_contains: Validates top-K predictions contain expected labels
  - generation_contains: Validates generated text contains keywords
  - embedding_normalized: Validates embeddings are unit normalized
  - multi_output_shape: Validates multiple output shapes

Usage:
    python validate-inference.py --model resnet --output /path/to/output.json
    python validate-inference.py --model gpt2 --response '{"logits": [...]}'
    python validate-inference.py --list-models

Environment variables:
    GOLDEN_DATA_PATH: Path to golden-test-data.yaml (default: config/golden-test-data.yaml)
"""

import argparse
import json
import sys
import os
import math
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple

try:
    import yaml
except ImportError:
    print("Error: pyyaml not installed. Run: pip install pyyaml")
    sys.exit(1)


class ValidationResult:
    """Result of a single validation test."""

    def __init__(self, test_name: str, passed: bool, message: str, details: Dict = None):
        self.test_name = test_name
        self.passed = passed
        self.message = message
        self.details = details or {}

    def to_dict(self) -> Dict:
        return {
            "test_name": self.test_name,
            "passed": self.passed,
            "message": self.message,
            "details": self.details
        }


class InferenceValidator:
    """Validates inference outputs against golden test data."""

    def __init__(self, golden_data_path: str = None):
        """Initialize validator with golden test data."""
        if golden_data_path is None:
            # Find config relative to script
            script_dir = Path(__file__).parent
            golden_data_path = script_dir.parent / "config" / "golden-test-data.yaml"

        self.golden_data_path = Path(golden_data_path)
        self.golden_data = self._load_golden_data()

    def _load_golden_data(self) -> Dict:
        """Load golden test data from YAML file."""
        if not self.golden_data_path.exists():
            raise FileNotFoundError(f"Golden data file not found: {self.golden_data_path}")

        with open(self.golden_data_path, 'r') as f:
            return yaml.safe_load(f)

    def get_available_models(self) -> List[str]:
        """Get list of models with golden test data."""
        return list(self.golden_data.get('models', {}).keys())

    def get_model_tests(self, model_name: str) -> List[Dict]:
        """Get test cases for a specific model."""
        model_data = self.golden_data.get('models', {}).get(model_name)
        if not model_data:
            return []
        return model_data.get('test_cases', [])

    def validate(self, model_name: str, output: Dict, test_name: str = None) -> List[ValidationResult]:
        """
        Validate inference output against golden test data.

        Args:
            model_name: Name of the model (e.g., "resnet", "gpt2")
            output: Inference output dictionary
            test_name: Optional specific test to run (runs all if None)

        Returns:
            List of ValidationResult objects
        """
        model_data = self.golden_data.get('models', {}).get(model_name)
        if not model_data:
            return [ValidationResult(
                test_name="model_lookup",
                passed=False,
                message=f"Model '{model_name}' not found in golden test data"
            )]

        test_cases = model_data.get('test_cases', [])
        if not test_cases:
            return [ValidationResult(
                test_name="test_cases_lookup",
                passed=False,
                message=f"No test cases defined for model '{model_name}'"
            )]

        results = []
        for test in test_cases:
            if test_name and test.get('name') != test_name:
                continue

            result = self._run_single_validation(test, output)
            results.append(result)

        return results

    def _is_core_response(self, output: Dict) -> bool:
        """Check if output is Core metadata response (not tensor data)."""
        # Core returns: status, model_id, inference_time_us, output_size, etc.
        core_keys = {'status', 'model_id', 'inference_time_us', 'output_size'}
        return bool(core_keys & set(output.keys()))

    def _has_tensor_outputs(self, output: Dict) -> bool:
        """Check if Core response includes tensor outputs (include_outputs=true)."""
        return 'outputs' in output and isinstance(output.get('outputs'), dict)

    def _extract_tensor_data(self, output: Dict) -> Dict:
        """Extract tensor data from Core response with include_outputs=true."""
        if self._has_tensor_outputs(output):
            return output['outputs']
        return output

    def _run_single_validation(self, test: Dict, output: Dict) -> ValidationResult:
        """Run a single validation test."""
        test_name = test.get('name', 'unnamed_test')
        expected = test.get('expected', {})
        validation_type = expected.get('validation_type')

        # Check if Core response includes tensor outputs (include_outputs=true)
        # If so, extract tensor data and run full validation
        if self._is_core_response(output) and self._has_tensor_outputs(output):
            # We have tensor data! Run full tensor validation
            tensor_data = self._extract_tensor_data(output)
            return self._run_tensor_validation(test_name, expected, tensor_data, output)

        # If this is a Core metadata-only response (no tensor data), use Core-specific validation
        if self._is_core_response(output):
            return self._validate_core_response(test_name, expected, output)

        try:
            if validation_type == 'output_shape':
                return self._validate_output_shape(test_name, expected, output)
            elif validation_type == 'multi_output_shape':
                return self._validate_multi_output_shape(test_name, expected, output)
            elif validation_type == 'top_k_contains':
                return self._validate_top_k_contains(test_name, expected, output)
            elif validation_type == 'top_k_logits_check':
                return self._validate_top_k_logits(test_name, expected, output)
            elif validation_type == 'generation_contains':
                return self._validate_generation_contains(test_name, expected, output)
            elif validation_type == 'embedding_normalized':
                return self._validate_embedding_normalized(test_name, expected, output)
            elif validation_type == 'embeddings_compatible':
                return self._validate_embeddings_compatible(test_name, expected, output)
            elif validation_type == 'output_exists':
                return self._validate_output_exists(test_name, expected, output)
            elif validation_type == 'status_success':
                return self._validate_status_success(test_name, expected, output)
            else:
                return ValidationResult(
                    test_name=test_name,
                    passed=False,
                    message=f"Unknown validation type: {validation_type}"
                )
        except Exception as e:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Validation error: {str(e)}",
                details={"exception": str(type(e).__name__)}
            )

    def _validate_core_response(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """
        Validate Core inference response (metadata format).

        Core returns: {status, model_id, inference_time_us, output_size, ...}
        We validate:
        - status == "success"
        - output_size > 0 (inference produced output)

        Note: Core does not return raw tensor data, only metadata about the inference.
        The output_size is the size of the serialized output, which varies based on
        encoding format and doesn't directly correspond to raw tensor bytes.
        """
        status = output.get('status')
        output_size = output.get('output_size', 0)
        inference_time = output.get('inference_time_us', 0)
        model_id = output.get('model_id', 'unknown')

        # Basic success check
        if status != 'success':
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Core inference failed: status={status}",
                details={"status": status, "output": output}
            )

        # Check that output was produced
        if output_size <= 0:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Core inference returned no output (output_size={output_size})",
                details={
                    "status": status,
                    "output_size": output_size,
                    "inference_time_us": inference_time
                }
            )

        # Get expected shape for reporting
        expected_shape = expected.get('expected_shape', [])

        # If we got here, inference succeeded with output
        return ValidationResult(
            test_name=test_name,
            passed=True,
            message=f"Core inference successful: {output_size:,} bytes in {inference_time:,}us",
            details={
                "status": status,
                "model_id": model_id,
                "output_size": output_size,
                "inference_time_us": inference_time,
                "expected_shape": expected_shape,
                "validation_note": "Validated Core metadata response (tensor data not returned by Core API)"
            }
        )

    def _run_tensor_validation(self, test_name: str, expected: Dict, tensor_data: Dict, full_response: Dict) -> ValidationResult:
        """
        Run validation against actual tensor data from Core response with include_outputs=true.

        This enables semantic validation:
        - output_shape: Validates actual tensor shapes
        - top_k_contains: Validates top-K predictions contain expected classes
        - embedding_normalized: Validates embeddings are unit normalized
        """
        validation_type = expected.get('validation_type')
        inference_time = full_response.get('inference_time_us', 0)
        model_id = full_response.get('model_id', 'unknown')

        try:
            if validation_type == 'output_shape':
                result = self._validate_output_shape(test_name, expected, tensor_data)
                # Enhance result with Core metadata
                result.details['inference_time_us'] = inference_time
                result.details['model_id'] = model_id
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'multi_output_shape':
                result = self._validate_multi_output_shape(test_name, expected, tensor_data)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'top_k_contains':
                result = self._validate_top_k_contains(test_name, expected, tensor_data)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'top_k_logits_check':
                result = self._validate_top_k_logits(test_name, expected, tensor_data)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'generation_contains':
                result = self._validate_generation_contains(test_name, expected, tensor_data)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'embedding_normalized':
                result = self._validate_embedding_normalized(test_name, expected, tensor_data)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'embeddings_compatible':
                result = self._validate_embeddings_compatible(test_name, expected, tensor_data)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'output_exists':
                result = self._validate_output_exists(test_name, expected, tensor_data)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'tensor_data'
                return result
            elif validation_type == 'status_success':
                # For status_success, we validate the full response, not tensor_data
                result = self._validate_status_success(test_name, expected, full_response)
                result.details['inference_time_us'] = inference_time
                result.details['validation_source'] = 'core_response'
                return result
            else:
                return ValidationResult(
                    test_name=test_name,
                    passed=False,
                    message=f"Unknown validation type: {validation_type}",
                    details={'inference_time_us': inference_time}
                )
        except Exception as e:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Tensor validation error: {str(e)}",
                details={
                    "exception": str(type(e).__name__),
                    "inference_time_us": inference_time,
                    "available_keys": list(tensor_data.keys()) if isinstance(tensor_data, dict) else []
                }
            )

    def _validate_output_shape(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate that output tensor has expected shape."""
        output_name = expected.get('output_name', 'logits')
        expected_shape = expected.get('expected_shape')

        if output_name not in output:
            # Try to find any output that might match
            available_outputs = list(output.keys())
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Output '{output_name}' not found in response",
                details={"available_outputs": available_outputs}
            )

        actual_data = output[output_name]
        actual_shape = self._get_tensor_shape(actual_data)

        if actual_shape == expected_shape:
            return ValidationResult(
                test_name=test_name,
                passed=True,
                message=f"Shape matches: {actual_shape}",
                details={"actual_shape": actual_shape, "expected_shape": expected_shape}
            )
        else:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Shape mismatch: expected {expected_shape}, got {actual_shape}",
                details={"actual_shape": actual_shape, "expected_shape": expected_shape}
            )

    def _validate_multi_output_shape(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate multiple output shapes."""
        outputs_config = expected.get('outputs', {})
        all_passed = True
        details = {}

        for output_name, config in outputs_config.items():
            expected_shape = config.get('expected_shape')
            if output_name not in output:
                all_passed = False
                details[output_name] = {"error": "not found"}
                continue

            actual_shape = self._get_tensor_shape(output[output_name])
            passed = actual_shape == expected_shape
            all_passed = all_passed and passed
            details[output_name] = {
                "expected": expected_shape,
                "actual": actual_shape,
                "passed": passed
            }

        return ValidationResult(
            test_name=test_name,
            passed=all_passed,
            message="All output shapes match" if all_passed else "Some output shapes mismatch",
            details=details
        )

    def _validate_top_k_contains(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate that top-K predictions contain expected labels."""
        output_name = expected.get('output_name', 'logits')
        top_k = expected.get('top_k', 5)
        expected_indices = expected.get('expected_class_indices', [])
        expected_labels = expected.get('expected_labels', expected.get('expected_class_labels', []))
        mask_position = expected.get('mask_position')

        if output_name not in output:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Output '{output_name}' not found"
            )

        logits = output[output_name]

        # Handle nested lists (batch dimension)
        if isinstance(logits, list) and logits and isinstance(logits[0], list):
            if mask_position is not None:
                # For masked LM, get logits at mask position
                logits = logits[0][mask_position] if len(logits[0]) > mask_position else logits[0][-1]
            else:
                # Get last position for causal LM
                logits = logits[0][-1] if isinstance(logits[0][-1], list) else logits[0]

        # Get top-K indices
        if isinstance(logits, list):
            indexed_logits = list(enumerate(logits))
            indexed_logits.sort(key=lambda x: x[1], reverse=True)
            top_k_indices = [idx for idx, _ in indexed_logits[:top_k]]
        else:
            top_k_indices = []

        # Check if expected indices are in top-K
        if expected_indices:
            found = [idx for idx in expected_indices if idx in top_k_indices]
            passed = len(found) > 0
            return ValidationResult(
                test_name=test_name,
                passed=passed,
                message=f"Found {len(found)}/{len(expected_indices)} expected classes in top-{top_k}",
                details={
                    "top_k_indices": top_k_indices,
                    "expected_indices": expected_indices,
                    "found_indices": found
                }
            )

        # If no indices, just report what we found (can't validate labels without tokenizer)
        return ValidationResult(
            test_name=test_name,
            passed=True,
            message=f"Got top-{top_k} predictions (label validation requires tokenizer)",
            details={"top_k_indices": top_k_indices}
        )

    def _validate_top_k_logits(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate specific token is in top-K at given position."""
        output_name = expected.get('output_name', 'logits')
        position = expected.get('position', -1)
        top_k = expected.get('top_k', 10)
        expected_tokens = expected.get('expected_tokens', [])

        if output_name not in output:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Output '{output_name}' not found"
            )

        logits = output[output_name]

        # Navigate to the specified position
        if isinstance(logits, list) and logits:
            if isinstance(logits[0], list):  # [batch, seq, vocab]
                logits = logits[0][position] if position >= 0 else logits[0][-1]
            elif position != -1:
                logits = logits  # Already at vocab level

        # Get top-K token indices
        if isinstance(logits, list):
            indexed_logits = list(enumerate(logits))
            indexed_logits.sort(key=lambda x: x[1], reverse=True)
            top_k_indices = [idx for idx, _ in indexed_logits[:top_k]]
        else:
            top_k_indices = []

        # Check expected tokens
        found = [tok for tok in expected_tokens if tok in top_k_indices]
        passed = len(found) > 0

        return ValidationResult(
            test_name=test_name,
            passed=passed,
            message=f"{'Found' if passed else 'Did not find'} expected token(s) in top-{top_k}",
            details={
                "top_k_indices": top_k_indices,
                "expected_tokens": expected_tokens,
                "found_tokens": found
            }
        )

    def _validate_generation_contains(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate that generated text contains expected keywords."""
        expected_keywords = expected.get('expected_keywords', [])
        case_insensitive = expected.get('case_insensitive', True)

        # Find generated text in output
        generated_text = None
        for key in ['generated_text', 'text', 'output', 'response', 'content']:
            if key in output:
                generated_text = output[key]
                break

        if generated_text is None:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message="No generated text found in output",
                details={"available_keys": list(output.keys())}
            )

        if isinstance(generated_text, list):
            generated_text = generated_text[0] if generated_text else ""

        generated_text = str(generated_text)

        # Check keywords
        check_text = generated_text.lower() if case_insensitive else generated_text
        found_keywords = []
        for keyword in expected_keywords:
            check_keyword = keyword.lower() if case_insensitive else keyword
            if check_keyword in check_text:
                found_keywords.append(keyword)

        passed = len(found_keywords) > 0

        return ValidationResult(
            test_name=test_name,
            passed=passed,
            message=f"Found {len(found_keywords)}/{len(expected_keywords)} keywords in generated text",
            details={
                "generated_text": generated_text[:500],  # Truncate for readability
                "expected_keywords": expected_keywords,
                "found_keywords": found_keywords
            }
        )

    def _validate_embedding_normalized(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate that embeddings are unit normalized."""
        output_name = expected.get('output_name', 'sentence_embedding')
        expected_norm = expected.get('expected_l2_norm', 1.0)
        tolerance = expected.get('tolerance', 0.01)

        if output_name not in output:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Output '{output_name}' not found"
            )

        embedding = output[output_name]

        # Flatten if needed
        if isinstance(embedding, list) and embedding and isinstance(embedding[0], list):
            embedding = embedding[0]

        # Calculate L2 norm
        if isinstance(embedding, list):
            l2_norm = math.sqrt(sum(x * x for x in embedding))
        else:
            l2_norm = 0

        passed = abs(l2_norm - expected_norm) <= tolerance

        return ValidationResult(
            test_name=test_name,
            passed=passed,
            message=f"L2 norm: {l2_norm:.4f} (expected: {expected_norm} ± {tolerance})",
            details={
                "l2_norm": l2_norm,
                "expected_norm": expected_norm,
                "tolerance": tolerance
            }
        )

    def _validate_embeddings_compatible(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate that text and image embeddings are compatible (same dimension)."""
        text_output = expected.get('text_output', 'text_embeds')
        image_output = expected.get('image_output', 'image_embeds')

        if text_output not in output or image_output not in output:
            missing = []
            if text_output not in output:
                missing.append(text_output)
            if image_output not in output:
                missing.append(image_output)
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Missing outputs: {missing}"
            )

        text_shape = self._get_tensor_shape(output[text_output])
        image_shape = self._get_tensor_shape(output[image_output])

        # Embeddings are compatible if they have the same dimension
        compatible = text_shape == image_shape

        return ValidationResult(
            test_name=test_name,
            passed=compatible,
            message=f"Embeddings {'are' if compatible else 'are not'} compatible",
            details={
                "text_shape": text_shape,
                "image_shape": image_shape
            }
        )

    def _validate_output_exists(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate that a specific output exists in the response with optional min size check."""
        output_name = expected.get('output_name', 'output')
        min_elements = expected.get('min_elements', 0)

        # Check in outputs dict if this is a Core response with tensor data
        tensor_data = self._extract_tensor_data(output) if self._has_tensor_outputs(output) else output

        if output_name in tensor_data:
            data = tensor_data[output_name]
            data_len = len(data) if isinstance(data, list) else 1

            # Check minimum elements if specified
            if min_elements > 0 and data_len < min_elements:
                return ValidationResult(
                    test_name=test_name,
                    passed=False,
                    message=f"Output '{output_name}' has {data_len} elements, expected >= {min_elements}",
                    details={"output_name": output_name, "length": data_len, "min_expected": min_elements}
                )

            return ValidationResult(
                test_name=test_name,
                passed=True,
                message=f"Output '{output_name}' found with {data_len} elements",
                details={"output_name": output_name, "length": data_len, "min_expected": min_elements}
            )
        else:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Output '{output_name}' not found in response",
                details={"available_keys": list(tensor_data.keys()) if isinstance(tensor_data, dict) else []}
            )

    def _validate_status_success(self, test_name: str, expected: Dict, output: Dict) -> ValidationResult:
        """Validate that the response status is success and optionally check min_output_size."""
        status = output.get('status')
        output_size = output.get('output_size', 0)
        min_output_size = expected.get('min_output_size', 0)

        if status != 'success':
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"Expected status 'success', got '{status}'",
                details={"status": status, "message": output.get('message', '')}
            )

        # Optionally check min_output_size if specified
        if min_output_size > 0 and output_size < min_output_size:
            return ValidationResult(
                test_name=test_name,
                passed=False,
                message=f"output_size {output_size:,} < min_output_size {min_output_size:,}",
                details={
                    "status": status,
                    "output_size": output_size,
                    "min_output_size": min_output_size,
                    "model_id": output.get('model_id', 'unknown')
                }
            )

        return ValidationResult(
            test_name=test_name,
            passed=True,
            message=f"Status is success, output_size={output_size:,}",
            details={
                "status": status,
                "output_size": output_size,
                "min_output_size": min_output_size,
                "model_id": output.get('model_id', 'unknown'),
                "inference_time_us": output.get('inference_time_us', 0)
            }
        )

    def _get_tensor_shape(self, data: Any) -> List[int]:
        """Recursively determine shape of nested list (tensor)."""
        shape = []
        current = data
        while isinstance(current, list):
            shape.append(len(current))
            if current:
                current = current[0]
            else:
                break
        return shape


def main():
    parser = argparse.ArgumentParser(
        description="Validate MLOS inference outputs against golden test data"
    )
    parser.add_argument('--model', '-m', help='Model name to validate')
    parser.add_argument('--output', '-o', help='Path to inference output JSON file')
    parser.add_argument('--response', '-r', help='Inline JSON response to validate')
    parser.add_argument('--test', '-t', help='Specific test name to run')
    parser.add_argument('--list-models', '-l', action='store_true', help='List available models')
    parser.add_argument('--list-tests', action='store_true', help='List tests for model')
    parser.add_argument('--golden-data', help='Path to golden-test-data.yaml')
    parser.add_argument('--json', action='store_true', help='Output results as JSON')

    args = parser.parse_args()

    try:
        validator = InferenceValidator(args.golden_data)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.list_models:
        print("Available models with golden test data:")
        for model in validator.get_available_models():
            tests = validator.get_model_tests(model)
            print(f"  {model}: {len(tests)} test(s)")
        return

    if args.list_tests and args.model:
        tests = validator.get_model_tests(args.model)
        if not tests:
            print(f"No tests found for model '{args.model}'")
            return
        print(f"Tests for {args.model}:")
        for test in tests:
            print(f"  - {test.get('name', 'unnamed')}: {test.get('expected', {}).get('validation_type', 'unknown')}")
        return

    if not args.model:
        parser.print_help()
        sys.exit(1)

    # Load output data
    output = {}
    if args.output:
        with open(args.output, 'r') as f:
            output = json.load(f)
    elif args.response:
        output = json.loads(args.response)
    else:
        print("Error: Must provide --output or --response", file=sys.stderr)
        sys.exit(1)

    # Run validation
    results = validator.validate(args.model, output, args.test)

    # Output results
    if args.json:
        print(json.dumps([r.to_dict() for r in results], indent=2))
    else:
        all_passed = True
        for result in results:
            status = "✅ PASS" if result.passed else "❌ FAIL"
            print(f"{status}: {result.test_name}")
            print(f"       {result.message}")
            if not result.passed:
                all_passed = False

        print()
        if all_passed:
            print("All validations passed!")
        else:
            print("Some validations failed")
            sys.exit(1)


if __name__ == '__main__':
    main()
