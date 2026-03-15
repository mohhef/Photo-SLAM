#!/bin/bash
# Installation script for Photo-SLAM
# Photo-SLAM: Real-time Simultaneous Localization and Photorealistic Mapping (CVPR 2024)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Installing Photo-SLAM ==="

# Install system dependencies
echo "Installing system dependencies..."
echo "NOTE: If this fails, run manually:"
echo "  sudo apt-get install -y libeigen3-dev libboost-all-dev libjsoncpp-dev libopengl-dev mesa-utils libglfw3-dev libglm-dev"
sudo apt-get update && sudo apt-get install -y libeigen3-dev libboost-all-dev libjsoncpp-dev libopengl-dev mesa-utils libglfw3-dev libglm-dev || true

# Check for LibTorch
LIBTORCH_DIR=""
if [ -d "/usr/local/libtorch" ]; then
    LIBTORCH_DIR="/usr/local/libtorch"
elif [ -d "$HOME/libtorch" ]; then
    LIBTORCH_DIR="$HOME/libtorch"
elif [ -d "$SCRIPT_DIR/libtorch" ]; then
    LIBTORCH_DIR="$SCRIPT_DIR/libtorch"
fi

if [ -z "$LIBTORCH_DIR" ]; then
    echo "LibTorch not found. Downloading LibTorch 2.0.1+cu118..."
    wget -q https://download.pytorch.org/libtorch/cu118/libtorch-cxx11-abi-shared-with-deps-2.0.1%2Bcu118.zip -O libtorch.zip
    unzip -q libtorch.zip
    rm libtorch.zip
    LIBTORCH_DIR="$SCRIPT_DIR/libtorch"
    echo "LibTorch extracted to: $LIBTORCH_DIR"
fi

echo "Using LibTorch at: $LIBTORCH_DIR"

# Check for OpenCV with CUDA
OPENCV_CUDA_CHECK=$(python3 -c "import cv2; print('YES' if cv2.cuda.getCudaEnabledDeviceCount() > 0 else 'NO')" 2>/dev/null || echo "NO")
if [ "$OPENCV_CUDA_CHECK" != "YES" ]; then
    echo "WARNING: OpenCV with CUDA not detected!"
    echo "Photo-SLAM requires OpenCV built with CUDA support."
    echo "Please follow the README instructions to build OpenCV with CUDA."
    echo "Continuing anyway (build may fail)..."
fi

# Build DBoW2
echo "Building DBoW2..."
cd "$SCRIPT_DIR/ORB-SLAM3/Thirdparty/DBoW2"
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Build g2o
echo "Building g2o..."
cd "$SCRIPT_DIR/ORB-SLAM3/Thirdparty/g2o"
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Build Sophus
echo "Building Sophus..."
cd "$SCRIPT_DIR/ORB-SLAM3/Thirdparty/Sophus"
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Extract ORB vocabulary
echo "Extracting ORB vocabulary..."
cd "$SCRIPT_DIR/ORB-SLAM3/Vocabulary"
if [ ! -f "ORBvoc.txt" ]; then
    tar -xf ORBvoc.txt.tar.gz
fi

# Build ORB-SLAM3
echo "Building ORB-SLAM3..."
cd "$SCRIPT_DIR/ORB-SLAM3"
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Build Photo-SLAM
echo "Building Photo-SLAM..."
cd "$SCRIPT_DIR"
mkdir -p build && cd build
cmake .. -DTorch_DIR="$LIBTORCH_DIR/share/cmake/Torch"
make -j$(nproc)

# Verify build
echo ""
echo "Verifying build..."
if [ -f "$SCRIPT_DIR/bin/tum_mono" ] && [ -f "$SCRIPT_DIR/bin/tum_rgbd" ] && [ -f "$SCRIPT_DIR/bin/euroc_stereo" ]; then
    echo "Build successful! Executables found:"
    ls -la "$SCRIPT_DIR/bin/"
else
    echo "ERROR: Some executables not found. Build may have failed."
    exit 1
fi

echo ""
echo "=== Photo-SLAM installation complete ==="
echo ""
echo "Supported datasets:"
echo "  - TUM RGB-D (mono, rgbd)"
echo "  - EuRoC (stereo)"
echo "  - Replica (mono, rgbd)"
echo ""
echo "Usage examples:"
echo "  ./bin/tum_mono ./ORB-SLAM3/Vocabulary/ORBvoc.txt ./cfg/ORB_SLAM3/Monocular/TUM/tum_freiburg1_desk.yaml ./cfg/gaussian_mapper/Monocular/TUM/tum_mono.yaml /path/to/dataset /path/to/output no_viewer"
