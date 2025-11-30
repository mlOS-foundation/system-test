# Vision Model Support Plan

## Current Status
- ❌ ResNet-50 ONNX conversion fails in Axon
- Root cause: Converter doesn't specify `--task image-classification`

## Issues Identified

### 1. Axon Converter (Priority: High)
- **Problem**: Optimum export requires `--task` parameter for local models
- **Error**: `Cannot infer the task from a local directory yet`
- **Fix**: Detect model type from config class and pass appropriate task

```python
# Task mapping needed in convert_huggingface.py
TASK_MAPPING = {
    'ResNetConfig': 'image-classification',
    'ViTConfig': 'image-classification', 
    'VGGConfig': 'image-classification',
    'ConvNextConfig': 'image-classification',
    'SwinConfig': 'image-classification',
    'DeiTConfig': 'image-classification',
    'BeitConfig': 'image-classification',
    'CLIPConfig': 'zero-shot-image-classification',
}
```

### 2. SafeTensors Compatibility
- **Problem**: Some models have UTF-8 encoding issues in headers
- **Fix**: Add error handling, try loading with `from_pretrained(..., use_safetensors=False)`

### 3. Input Shape Handling
- Vision models need specific input shapes:
  - Standard: `[batch, 3, 224, 224]` (ResNet, VGG, ViT)
  - Some models: `[batch, 3, 384, 384]` (Swin-L)

## Vision Models to Support

### Tier 1 (Image Classification)
| Model | HuggingFace ID | Pre-ONNX Available |
|-------|----------------|-------------------|
| ResNet-50 | microsoft/resnet-50 | ❌ |
| ViT | google/vit-base-patch16-224 | ❌ |
| ConvNeXT | facebook/convnext-base-224 | ❌ |

### Tier 2 (Object Detection)  
| Model | HuggingFace ID | Notes |
|-------|----------------|-------|
| DETR | facebook/detr-resnet-50 | Complex output |
| YOLOS | hustvl/yolos-tiny | Easier to integrate |

### Tier 3 (Multi-Modal)
| Model | HuggingFace ID | Notes |
|-------|----------------|-------|
| CLIP | openai/clip-vit-base-patch32 | Text + Image |

## Implementation Roadmap

### Phase 1: Axon Fixes (1-2 days)
1. Add task detection to `convert_huggingface.py`
2. Add safetensors fallback
3. Test with ResNet, ViT, ConvNeXT

### Phase 2: System-Test Updates (1 day)
1. Add vision-specific test input generation
2. Add proper input shape handling
3. Validate inference outputs

### Phase 3: Core Validation (1 day)
1. Ensure ONNX Runtime handles 4D image tensors
2. Add vision model inference examples
3. Document input/output formats

## Quick Workaround (system-test)
Use models with pre-converted ONNX or skip vision until Axon is fixed.
