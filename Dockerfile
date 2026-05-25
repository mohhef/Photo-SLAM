# Photo-SLAM Podman image
# Built and run by SAL's runtime-stress framework via PhotoSLAMAlgorithm
# at src/algorithms/photoslam.py. See docs/PHOTO_SLAM_PODMAN.md for the
# operator-side build / run / troubleshooting guide.
#
# Notes for future maintainers:
# - Photo-SLAM is a C++ project built by CMake (NOT a Python pip install).
#   The deliverables are the C++ binaries in bin/ (tum_mono, tum_rgbd,
#   euroc_stereo, replica_mono, replica_rgbd).
# - It depends on LibTorch 2.0.1+cu118 cxx11 ABI (the C++ ABI of PyTorch,
#   not the Python package). We download the prebuilt zip from
#   download.pytorch.org/libtorch — same pin Photo-SLAM tests against.
# - It also requires OpenCV 4 with CUDA support, which is NOT available
#   from any apt repo. We build OpenCV 4.8 + opencv_contrib from source
#   with CUDA on — this is the long step of the build (~25-30 min).
# - Custom CUDA kernels (cuda_rasterizer, simple_knn) are compiled by
#   CMake during the Photo-SLAM build, so we need a -devel base image
#   with nvcc.
# - Build time: ~45 minutes on a 20-core host; one-time per host.
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    MAKEFLAGS=-j8

# ---------------------------------------------------------------------------
# Step 1: System packages.
#   - python3.10 + dev headers (CMake needs them for OpenCV's python bindings,
#     though we don't ship python bindings out of the image).
#   - eigen, boost, jsoncpp, openssl: Photo-SLAM / ORB-SLAM3 deps.
#   - opengl, glfw, glm: ImGui viewer (we run no_viewer, but the libs link).
#   - opencv build deps: ffmpeg, gtk, jpeg/png/tiff, openexr, lapack, atlas.
#   - cmake >= 3.20 (Photo-SLAM requires it). Ubuntu 22.04 ships 3.22 — OK.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.10 python3.10-venv python3.10-dev python3-pip python3-numpy \
        git build-essential cmake ninja-build pkg-config wget unzip ca-certificates \
        libeigen3-dev libboost-all-dev libjsoncpp-dev libssl-dev \
        libopengl-dev mesa-utils libglfw3-dev libglm-dev libgl1-mesa-glx \
        libglu1-mesa-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev \
        libsuitesparse-dev libceres-dev \
        ffmpeg libavcodec-dev libavformat-dev libswscale-dev libavutil-dev \
        libgtk-3-dev libtbb-dev libjpeg-dev libpng-dev libtiff-dev libopenexr-dev \
        liblapack-dev libatlas-base-dev gfortran \
        libgflags-dev libgoogle-glog-dev \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.10 /usr/bin/python && \
    ln -sf /usr/bin/python3.10 /usr/bin/python3

# ---------------------------------------------------------------------------
# Step 2: LibTorch 2.0.1+cu118 cxx11 ABI.
# This is the exact pin Photo-SLAM's install_all.sh downloads. Cached as a
# dedicated layer so a Photo-SLAM source edit doesn't invalidate it.
# ---------------------------------------------------------------------------
WORKDIR /opt
RUN wget -q https://download.pytorch.org/libtorch/cu118/libtorch-cxx11-abi-shared-with-deps-2.0.1%2Bcu118.zip -O libtorch.zip \
    && unzip -q libtorch.zip \
    && rm libtorch.zip
ENV Torch_DIR=/opt/libtorch/share/cmake/Torch \
    LD_LIBRARY_PATH=/opt/libtorch/lib:${LD_LIBRARY_PATH}

# ---------------------------------------------------------------------------
# Step 3: OpenCV 4.8.0 + opencv_contrib with CUDA support.
# Photo-SLAM's CMakeLists asks for find_package(OpenCV 4 REQUIRED), and at
# runtime calls cv::cuda functions, so we need CUDA-enabled OpenCV.
# CUDA arches 7.5 (T4/2080), 8.6 (A6000/3090) — adjust if you target Hopper.
# This is the longest step (~25-30 min on a 20-core host).
# ---------------------------------------------------------------------------
WORKDIR /opt
RUN wget -q https://github.com/opencv/opencv/archive/refs/tags/4.8.0.tar.gz -O opencv.tar.gz \
    && wget -q https://github.com/opencv/opencv_contrib/archive/refs/tags/4.8.0.tar.gz -O opencv_contrib.tar.gz \
    && tar -xzf opencv.tar.gz \
    && tar -xzf opencv_contrib.tar.gz \
    && rm opencv.tar.gz opencv_contrib.tar.gz

RUN mkdir -p /opt/opencv-4.8.0/build \
    && cd /opt/opencv-4.8.0/build \
    && cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DOPENCV_EXTRA_MODULES_PATH=/opt/opencv_contrib-4.8.0/modules \
        -DWITH_CUDA=ON \
        -DWITH_CUDNN=ON \
        -DOPENCV_DNN_CUDA=OFF \
        -DCUDA_FAST_MATH=ON \
        -DENABLE_FAST_MATH=ON \
        -DCUDA_ARCH_BIN="7.5;8.6" \
        -DCUDA_ARCH_PTX="" \
        -DWITH_TBB=ON \
        -DBUILD_opencv_python2=OFF \
        -DBUILD_opencv_python3=ON \
        -DBUILD_TESTS=OFF \
        -DBUILD_PERF_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_DOCS=OFF \
        -DOPENCV_ENABLE_NONFREE=ON \
        -DOPENCV_GENERATE_PKGCONFIG=ON \
        .. \
    && ninja \
    && ninja install \
    && ldconfig \
    && cd / && rm -rf /opt/opencv-4.8.0 /opt/opencv_contrib-4.8.0

# ---------------------------------------------------------------------------
# Step 4: Copy Photo-SLAM source. .dockerignore strips libtorch/, build/,
# lib/ — those will be rebuilt in-container.
# ---------------------------------------------------------------------------
WORKDIR /photo-slam
COPY . /photo-slam

# Strip any prebuilt host artifacts that survived .dockerignore (defensive).
RUN rm -rf build lib \
    && rm -rf ORB-SLAM3/Thirdparty/DBoW2/build ORB-SLAM3/Thirdparty/DBoW2/lib \
    && rm -rf ORB-SLAM3/Thirdparty/g2o/build ORB-SLAM3/Thirdparty/g2o/lib \
    && rm -rf ORB-SLAM3/Thirdparty/Sophus/build \
    && rm -rf ORB-SLAM3/build ORB-SLAM3/lib

# ---------------------------------------------------------------------------
# Step 5: Build the ORB-SLAM3 thirdparty stack (DBoW2, g2o, Sophus) and
# ORB-SLAM3 itself. Mirrors install_all.sh but without sudo or apt prompts.
# ---------------------------------------------------------------------------
RUN cd /photo-slam/ORB-SLAM3/Thirdparty/DBoW2 \
    && mkdir -p build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

RUN cd /photo-slam/ORB-SLAM3/Thirdparty/g2o \
    && mkdir -p build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

RUN cd /photo-slam/ORB-SLAM3/Thirdparty/Sophus \
    && mkdir -p build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

# ORB-SLAM3 ships the vocabulary as a tar.gz. Extract it (Photo-SLAM
# expects ORBvoc.txt on disk at runtime).
RUN cd /photo-slam/ORB-SLAM3/Vocabulary \
    && if [ ! -f ORBvoc.txt ]; then tar -xf ORBvoc.txt.tar.gz; fi

RUN cd /photo-slam/ORB-SLAM3 \
    && mkdir -p build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

# ---------------------------------------------------------------------------
# Step 6: Build Photo-SLAM itself (cuda_rasterizer, simple_knn, gaussian_*
# libs, and the per-dataset binaries). Torch_DIR is set above.
# ---------------------------------------------------------------------------
RUN cd /photo-slam \
    && mkdir -p build && cd build \
    && cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DTorch_DIR=${Torch_DIR} \
    && make -j$(nproc)

# Make Photo-SLAM's own libraries (gaussian_mapper, cuda_rasterizer,
# simple_knn, imgui) discoverable to the binaries at runtime. The lib/
# dir is populated by the CMake build (CMAKE_LIBRARY_OUTPUT_DIRECTORY).
ENV LD_LIBRARY_PATH=/photo-slam/lib:/photo-slam/ORB-SLAM3/lib:/photo-slam/ORB-SLAM3/Thirdparty/DBoW2/lib:/photo-slam/ORB-SLAM3/Thirdparty/g2o/lib:${LD_LIBRARY_PATH}

# Sanity: list the binaries built. If any are missing the image build
# should fail loudly rather than silently shipping an incomplete image.
RUN ls -la /photo-slam/bin/tum_mono /photo-slam/bin/tum_rgbd /photo-slam/bin/euroc_stereo

# Create mount points to match the wrapper's expectations.
RUN mkdir -p /dataset /output /dataset_meta /root/.cache/torch/hub

CMD ["/photo-slam/bin/tum_mono"]
