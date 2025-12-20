#!/bin/bash
# Download Golden Test Images for Vision Model Semantic Validation
# ===============================================================================
#
# This script downloads curated test images from Wikimedia Commons for
# vision model semantic validation. All images are CC0/Public Domain licensed.
#
# Usage:
#   ./scripts/download-golden-images.sh
#
# The images are stored in test-data/golden-images/imagenet/
#
# ===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GOLDEN_DIR="$PROJECT_DIR/test-data/golden-images/imagenet"

# Create directory if it doesn't exist
mkdir -p "$GOLDEN_DIR"

echo "=== Downloading Golden Test Images ==="
echo "Target directory: $GOLDEN_DIR"
echo ""

# Image URLs from Wikimedia Commons (public domain/CC licensed)
# Using arrays compatible with bash 3.x (no associative arrays)
FILENAMES="cat_tabby.jpg dog_golden_retriever.jpg coffee_mug.jpg clock_analog.jpg sports_car.jpg"

# Download each image
SUCCESS=0
FAILED=0

download_image() {
    local filename="$1"
    local url="$2"
    local target="$GOLDEN_DIR/$filename"

    if [[ -f "$target" ]]; then
        echo "[SKIP] $filename already exists"
        return 0
    fi

    echo -n "[DOWNLOADING] $filename... "

    if curl -s -L -o "$target" "$url" 2>/dev/null; then
        # Verify the file is not empty and is a valid image
        if [[ -s "$target" ]]; then
            # Check if file has valid image magic bytes
            file_type=$(file -b "$target" 2>/dev/null | head -c 20)
            if [[ "$file_type" == *"image"* ]] || [[ "$file_type" == *"JPEG"* ]] || [[ "$file_type" == *"PNG"* ]] || [[ "$file_type" == *"GIF"* ]]; then
                echo "OK ($(du -h "$target" | cut -f1))"
                return 0
            else
                echo "INVALID (not an image)"
                rm -f "$target"
                return 1
            fi
        else
            echo "EMPTY"
            rm -f "$target"
            return 1
        fi
    else
        echo "FAILED"
        rm -f "$target"
        return 1
    fi
}

# Download cat image
if download_image "cat_tabby.jpg" "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/320px-Cat_November_2010-1a.jpg"; then
    SUCCESS=$((SUCCESS + 1))
else
    FAILED=$((FAILED + 1))
fi

# Download dog image - Using a golden retriever image
if download_image "dog_golden_retriever.jpg" "https://upload.wikimedia.org/wikipedia/commons/thumb/2/26/YellowLabradorLooking_new.jpg/320px-YellowLabradorLooking_new.jpg"; then
    SUCCESS=$((SUCCESS + 1))
else
    FAILED=$((FAILED + 1))
fi

# Download coffee mug image - Using a clear coffee cup image
if download_image "coffee_mug.jpg" "https://upload.wikimedia.org/wikipedia/commons/thumb/4/45/A_small_cup_of_coffee.JPG/320px-A_small_cup_of_coffee.JPG"; then
    SUCCESS=$((SUCCESS + 1))
else
    FAILED=$((FAILED + 1))
fi

# Download clock image - analog wall clock
if download_image "clock_analog.jpg" "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4a/Brodjonegoro_DPRD_Clock.jpg/320px-Brodjonegoro_DPRD_Clock.jpg"; then
    SUCCESS=$((SUCCESS + 1))
else
    FAILED=$((FAILED + 1))
fi

# Download sports car image - Ferrari
if download_image "sports_car.jpg" "https://upload.wikimedia.org/wikipedia/commons/thumb/6/6e/Ferrari_575M_Maranello_2002.jpg/320px-Ferrari_575M_Maranello_2002.jpg"; then
    SUCCESS=$((SUCCESS + 1))
else
    FAILED=$((FAILED + 1))
fi

echo ""
echo "=== Download Summary ==="
echo "  Success: $SUCCESS"
echo "  Failed:  $FAILED"
echo "  Target:  $GOLDEN_DIR"
echo ""

# List downloaded images
echo "=== Downloaded Images ==="
ls -la "$GOLDEN_DIR"/*.jpg 2>/dev/null || echo "No images found"
echo ""

# Verify minimum requirements
if [[ $SUCCESS -lt 3 ]]; then
    echo "WARNING: Less than 3 images downloaded. Semantic validation may not work correctly."
    exit 1
fi

echo "Golden images are ready for semantic validation testing."
exit 0
