#!/bin/bash
# Build universal (arm64 + x86_64) resize2fs and e2fsck for macOS bundling.
# Output: CloneTool/Binaries/resize2fs, CloneTool/Binaries/e2fsck
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${E2FSPROGS_VERSION:-1.47.2}"
SRC_URL="https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v${VERSION}/e2fsprogs-${VERSION}.tar.gz"

WORK="${ROOT}/build/e2fsprogs"
SRC="${WORK}/e2fsprogs-${VERSION}"
OUT="${ROOT}/CloneTool/Binaries"

mkdir -p "${WORK}" "${OUT}"

if [ ! -d "${SRC}" ]; then
    echo "==> Downloading e2fsprogs ${VERSION}"
    curl -fL "${SRC_URL}" -o "${WORK}/src.tar.gz"
    tar -xzf "${WORK}/src.tar.gz" -C "${WORK}"
fi

build_for_arch() {
    local arch="$1"
    local host
    if [ "${arch}" = "arm64" ]; then host="aarch64-apple-darwin"; else host="x86_64-apple-darwin"; fi

    local build_dir="${WORK}/build-${arch}"
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    echo "==> Configuring ${arch}"
    (
        cd "${build_dir}"
        CC="clang -arch ${arch}" \
        CFLAGS="-arch ${arch} -O2" \
        LDFLAGS="-arch ${arch}" \
        "${SRC}/configure" \
            --host="${host}" \
            --disable-shared \
            --enable-static \
            --disable-nls \
            --disable-tls \
            --disable-uuidd \
            --disable-fuse2fs \
            ac_cv_func_getpwuid_r=yes \
            > "${WORK}/configure-${arch}.log" 2>&1
    ) || { echo "configure failed for ${arch}"; tail -80 "${WORK}/configure-${arch}.log"; return 1; }

    echo "==> Building ${arch}"
    (
        cd "${build_dir}"
        make -j"$(sysctl -n hw.ncpu)" > "${WORK}/build-${arch}.log" 2>&1
    ) || { echo "build failed for ${arch}"; tail -80 "${WORK}/build-${arch}.log"; return 1; }
}

build_for_arch arm64
build_for_arch x86_64

lipo_tool() {
    local tool="$1"
    local subdir="$2"
    echo "==> lipo ${tool}"
    lipo -create \
        "${WORK}/build-arm64/${subdir}/${tool}" \
        "${WORK}/build-x86_64/${subdir}/${tool}" \
        -output "${OUT}/${tool}"
    chmod +x "${OUT}/${tool}"
    file "${OUT}/${tool}"
}

lipo_tool resize2fs resize
lipo_tool e2fsck e2fsck

echo "==> Done. Binaries in ${OUT}"
