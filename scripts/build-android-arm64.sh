#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_latest_curl_version() {
  local release_table
  release_table="$(curl -fsSL https://curl.se/docs/releases.html)"
  perl -0ne 'if (/\b(\d+)\s*(8\.\d+\.\d+)\s*[A-Z][a-z]{2}/s) { print $2; exit 0 } exit 1' <<<"${release_table}"
}

CURL_VERSION="${CURL_VERSION:-latest}"
if [[ "${CURL_VERSION}" == "latest" ]]; then
  CURL_VERSION="$(resolve_latest_curl_version)"
fi

ANDROID_API="${ANDROID_API:-30}"
TARGET_HOST="aarch64-linux-android"
ABI="arm64-v8a"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"
BROTLI_VERSION="${BROTLI_VERSION:-1.2.0}"
ZSTD_VERSION="${ZSTD_VERSION:-1.5.7}"
NGHTTP2_VERSION="${NGHTTP2_VERSION:-1.68.1}"
NGHTTP3_VERSION="${NGHTTP3_VERSION:-1.15.0}"
NGTCP2_VERSION="${NGTCP2_VERSION:-1.22.0}"
BORINGSSL_REF="${BORINGSSL_REF:-main}"
DEFAULT_CA_PATH="${DEFAULT_CA_PATH:-/system/etc/security/cacerts}"

NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "${NDK_ROOT}" ]]; then
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must be set" >&2
  exit 1
fi

HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${HOST_OS}" in
  linux*) HOST_TAG="linux-x86_64" ;;
  darwin*) HOST_TAG="darwin-x86_64" ;;
  *)
    echo "Unsupported host OS: ${HOST_OS}" >&2
    exit 1
    ;;
esac

TOOLCHAIN="${NDK_ROOT}/toolchains/llvm/prebuilt/${HOST_TAG}"
if [[ ! -d "${TOOLCHAIN}" ]]; then
  echo "NDK toolchain not found: ${TOOLCHAIN}" >&2
  exit 1
fi

DOWNLOAD_DIR="${ROOT_DIR}/downloads"
SRC_DIR="${ROOT_DIR}/src"
BUILD_ROOT="${ROOT_DIR}/build/android-${ABI}"
DIST_DIR="${ROOT_DIR}/dist/curl-${CURL_VERSION}-android-${ABI}"
DEPS_PREFIX="${BUILD_ROOT}/deps-prefix"
PKG_CONFIG_DIR="${DEPS_PREFIX}/lib/pkgconfig"
WORK_DIR="${BUILD_ROOT}/work"
CXX_RUNTIME_DIR="${TOOLCHAIN}/sysroot/usr/lib/${TARGET_HOST}"
if [[ ! -d "${CXX_RUNTIME_DIR}" ]]; then
  CXX_RUNTIME_DIR="${TOOLCHAIN}/sysroot/usr/lib/${TARGET_HOST}/${ANDROID_API}"
fi
LIBCXX_STATIC="${CXX_RUNTIME_DIR}/libc++_static.a"
LIBCXXABI_STATIC="${CXX_RUNTIME_DIR}/libc++abi.a"
LIBUNWIND_STATIC="${CXX_RUNTIME_DIR}/libunwind.a"
CPP_RUNTIME_LIBS="-lc++_static -lc++abi -lunwind"
MERGE_RUNTIME_LIBS=()
if [[ -f "${LIBCXX_STATIC}" ]]; then
  MERGE_RUNTIME_LIBS+=("${LIBCXX_STATIC}")
fi
if [[ -f "${LIBCXXABI_STATIC}" ]]; then
  MERGE_RUNTIME_LIBS+=("${LIBCXXABI_STATIC}")
fi
if [[ -f "${LIBUNWIND_STATIC}" ]]; then
  MERGE_RUNTIME_LIBS+=("${LIBUNWIND_STATIC}")
fi

mkdir -p "${DOWNLOAD_DIR}" "${SRC_DIR}" "${BUILD_ROOT}" "${DEPS_PREFIX}" "${PKG_CONFIG_DIR}" "${WORK_DIR}"

export PATH="${TOOLCHAIN}/bin:${PATH}"
export AR="${TOOLCHAIN}/bin/llvm-ar"
export AS="${TOOLCHAIN}/bin/${TARGET_HOST}${ANDROID_API}-clang"
export CC="${TOOLCHAIN}/bin/${TARGET_HOST}${ANDROID_API}-clang"
export CXX="${TOOLCHAIN}/bin/${TARGET_HOST}${ANDROID_API}-clang++"
export LD="${TOOLCHAIN}/bin/ld.lld"
export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
export STRIP="${TOOLCHAIN}/bin/llvm-strip"
export NM="${TOOLCHAIN}/bin/llvm-nm"
export PKG_CONFIG="pkg-config"
export PKG_CONFIG_PATH="${PKG_CONFIG_DIR}"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_DIR}"
export CPPFLAGS="-I${DEPS_PREFIX}/include ${CPPFLAGS:-}"
export CFLAGS="-fPIC ${CFLAGS:-}"
export CXXFLAGS="-fPIC ${CXXFLAGS:-}"
export LDFLAGS="-L${DEPS_PREFIX}/lib -L${CXX_RUNTIME_DIR} ${LDFLAGS:-}"

makefile_list_var() {
  local makefile_path="$1"
  local variable_name="$2"
  python - "$makefile_path" "$variable_name" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
text = path.read_text()
logical_lines = []
current = ""
for raw_line in text.splitlines():
    line = raw_line.rstrip()
    if not line:
        if current:
            logical_lines.append(current)
            current = ""
        continue
    if current:
        current += line.lstrip()
    else:
        current = line
    if current.endswith("\\"):
        current = current[:-1] + " "
        continue
    logical_lines.append(current)
    current = ""
if current:
    logical_lines.append(current)

vars_map = {}
for line in logical_lines:
    match = re.match(r'^([A-Za-z0-9_]+)\s*=\s*(.*)$', line)
    if match:
        vars_map[match.group(1)] = match.group(2).strip()

pattern = re.compile(r'\$\(([^)]+)\)')

def expand(value, seen=None):
    if seen is None:
        seen = set()
    def repl(match):
        name = match.group(1)
        if name in seen:
            return ""
        if name not in vars_map:
            return ""
        return expand(vars_map[name], seen | {name})
    return pattern.sub(repl, value)

expanded = expand(vars_map.get(target, ""))
for item in expanded.split():
    print(item)
PY
}

merge_static_libraries() {
  local output_archive="$1"
  shift
  local merge_dir="${BUILD_ROOT}/merge-libcurl"
  local archive
  local archive_name
  local extracted_dir
  local object_file

  rm -rf "${merge_dir}"
  mkdir -p "${merge_dir}"

  for archive in "$@"; do
    if [[ ! -f "${archive}" ]]; then
      echo "Static archive missing: ${archive}" >&2
      exit 1
    fi

    archive_name="$(basename "${archive}" .a)"
    extracted_dir="${merge_dir}/${archive_name}"
    mkdir -p "${extracted_dir}"
    pushd "${extracted_dir}" >/dev/null
      "${AR}" x "${archive}"
    popd >/dev/null
  done

  rm -f "${output_archive}"
  for extracted_dir in "${merge_dir}"/*; do
    [[ -d "${extracted_dir}" ]] || continue
    for object_file in "${extracted_dir}"/*; do
      [[ -f "${object_file}" ]] || continue
      "${AR}" q "${output_archive}" "${object_file}"
    done
  done
  "${RANLIB}" "${output_archive}"
}

cmake_configure() {
  local src_dir="$1"
  local build_dir="$2"
  shift 2
  cmake -S "${src_dir}" -B "${build_dir}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Android \
    -DCMAKE_ANDROID_NDK="${NDK_ROOT}" \
    -DCMAKE_ANDROID_ARCH_ABI="${ABI}" \
    -DCMAKE_ANDROID_API="${ANDROID_API}" \
    -DANDROID_PLATFORM_LEVEL="${ANDROID_API}" \
    -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_AR="${AR}" \
    -DCMAKE_RANLIB="${RANLIB}" \
    -DCMAKE_STRIP="${STRIP}" \
    -DCMAKE_PREFIX_PATH="${DEPS_PREFIX}" \
    -DOPENSSL_ROOT_DIR="${DEPS_PREFIX}" \
    "$@"
}

fetch_archive() {
  local url="$1"
  local archive_path="$2"
  if [[ ! -f "${archive_path}" ]]; then
    echo "Downloading $(basename "${archive_path}")"
    curl -L --fail --retry 3 -o "${archive_path}" "${url}"
  fi
}

extract_archive() {
  local archive_path="$1"
  local out_dir="$2"
  if [[ ! -d "${out_dir}" ]]; then
    mkdir -p "$(dirname "${out_dir}")"
    tar -xf "${archive_path}" -C "$(dirname "${out_dir}")"
  fi
}

git_clone_or_update() {
  local repo_url="$1"
  local ref="$2"
  local out_dir="$3"
  if [[ ! -d "${out_dir}/.git" ]]; then
    git clone --depth 1 --branch "${ref}" "${repo_url}" "${out_dir}"
  else
    git -C "${out_dir}" fetch --depth 1 origin "${ref}"
    git -C "${out_dir}" checkout FETCH_HEAD
  fi
}

build_zlib() {
  local version="${ZLIB_VERSION}"
  local archive="${DOWNLOAD_DIR}/zlib-${version}.tar.gz"
  local source_dir="${SRC_DIR}/zlib-${version}"
  local build_dir="${WORK_DIR}/zlib"
  fetch_archive "https://github.com/madler/zlib/archive/refs/tags/v${version}.tar.gz" "${archive}"
  extract_archive "${archive}" "${source_dir}"
  rm -rf "${build_dir}"
  cp -R "${source_dir}" "${build_dir}"
  pushd "${build_dir}" >/dev/null
    CHOST="${TARGET_HOST}" ./configure --prefix="${DEPS_PREFIX}" --static
    make -j"${JOBS}"
    make install
  popd >/dev/null
}

build_brotli() {
  local version="${BROTLI_VERSION}"
  local archive="${DOWNLOAD_DIR}/brotli-v${version}.tar.gz"
  local source_dir="${SRC_DIR}/brotli-${version}"
  local build_dir="${WORK_DIR}/brotli"
  fetch_archive "https://github.com/google/brotli/archive/refs/tags/v${version}.tar.gz" "${archive}"
  extract_archive "${archive}" "${source_dir}"
  rm -rf "${build_dir}"
  cmake_configure "${source_dir}" "${build_dir}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBROTLI_DISABLE_TESTS=ON
  cmake --build "${build_dir}" --parallel "${JOBS}"
  cmake --install "${build_dir}"
}

build_zstd() {
  local version="${ZSTD_VERSION}"
  local archive="${DOWNLOAD_DIR}/zstd-v${version}.tar.gz"
  local source_dir="${SRC_DIR}/zstd-${version}"
  local build_dir="${WORK_DIR}/zstd"
  fetch_archive "https://github.com/facebook/zstd/archive/refs/tags/v${version}.tar.gz" "${archive}"
  extract_archive "${archive}" "${source_dir}"
  rm -rf "${build_dir}"
  cmake_configure "${source_dir}/build/cmake" "${build_dir}" \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_BUILD_TESTS=OFF
  cmake --build "${build_dir}" --parallel "${JOBS}"
  cmake --install "${build_dir}"
}

build_boringssl() {
  local source_dir="${SRC_DIR}/boringssl"
  local build_dir="${WORK_DIR}/boringssl"
  local ssl_archive
  local crypto_archive
  git_clone_or_update "https://github.com/google/boringssl.git" "${BORINGSSL_REF}" "${source_dir}"
  rm -rf "${build_dir}" "${DEPS_PREFIX}/include/openssl"
  cmake_configure "${source_dir}" "${build_dir}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF
  cmake --build "${build_dir}" --parallel "${JOBS}" --target ssl crypto
  ssl_archive="${build_dir}/libssl.a"
  crypto_archive="${build_dir}/libcrypto.a"
  if [[ ! -f "${ssl_archive}" ]]; then
    ssl_archive="${build_dir}/ssl/libssl.a"
  fi
  if [[ ! -f "${crypto_archive}" ]]; then
    crypto_archive="${build_dir}/crypto/libcrypto.a"
  fi
  mkdir -p "${DEPS_PREFIX}/include" "${DEPS_PREFIX}/lib"
  cp -R "${source_dir}/include/openssl" "${DEPS_PREFIX}/include/openssl"
  cp "${ssl_archive}" "${DEPS_PREFIX}/lib/libssl.a"
  cp "${crypto_archive}" "${DEPS_PREFIX}/lib/libcrypto.a"
}

build_nghttp2() {
  local version="${NGHTTP2_VERSION}"
  local archive="${DOWNLOAD_DIR}/nghttp2-v${version}.tar.gz"
  local source_dir="${SRC_DIR}/nghttp2-${version}"
  local build_dir="${WORK_DIR}/nghttp2"
  fetch_archive "https://github.com/nghttp2/nghttp2/releases/download/v${version}/nghttp2-${version}.tar.gz" "${archive}"
  extract_archive "${archive}" "${source_dir}"
  rm -rf "${build_dir}"
  cmake_configure "${source_dir}" "${build_dir}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DENABLE_APP=OFF \
    -DENABLE_ASIO_LIB=OFF \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_HPACK_TOOLS=OFF \
    -DENABLE_PYTHON_BINDINGS=OFF \
    -DENABLE_FAILMALLOC=OFF \
    -DBUILD_TESTING=OFF
  cmake --build "${build_dir}" --parallel "${JOBS}"
  cmake --install "${build_dir}"
}

build_nghttp3() {
  local version="${NGHTTP3_VERSION}"
  local archive="${DOWNLOAD_DIR}/nghttp3-v${version}.tar.gz"
  local source_dir="${SRC_DIR}/nghttp3-${version}"
  local build_dir="${WORK_DIR}/nghttp3"
  fetch_archive "https://github.com/ngtcp2/nghttp3/releases/download/v${version}/nghttp3-${version}.tar.gz" "${archive}"
  extract_archive "${archive}" "${source_dir}"
  rm -rf "${build_dir}"
  cmake_configure "${source_dir}" "${build_dir}" \
    -DENABLE_SHARED_LIB=OFF \
    -DENABLE_STATIC_LIB=ON \
    -DENABLE_LIB_ONLY=ON \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_TESTS=OFF
  cmake --build "${build_dir}" --parallel "${JOBS}"
  cmake --install "${build_dir}"
}

build_ngtcp2() {
  local version="${NGTCP2_VERSION}"
  local archive="${DOWNLOAD_DIR}/ngtcp2-v${version}.tar.gz"
  local source_dir="${SRC_DIR}/ngtcp2-${version}"
  local build_dir="${WORK_DIR}/ngtcp2"
  fetch_archive "https://github.com/ngtcp2/ngtcp2/releases/download/v${version}/ngtcp2-${version}.tar.gz" "${archive}"
  extract_archive "${archive}" "${source_dir}"
  rm -rf "${build_dir}"
  cmake_configure "${source_dir}" "${build_dir}" \
    -DENABLE_SHARED_LIB=OFF \
    -DENABLE_STATIC_LIB=ON \
    -DENABLE_LIB_ONLY=ON \
    -DENABLE_OPENSSL=OFF \
    -DENABLE_WOLFSSL=OFF \
    -DENABLE_GNUTLS=OFF \
    -DENABLE_PICOTLS=OFF \
    -DENABLE_BORINGSSL=ON \
    -DBORINGSSL_INCLUDE_DIR="${DEPS_PREFIX}/include" \
    -DBORINGSSL_LIBRARIES="${DEPS_PREFIX}/lib/libssl.a;${DEPS_PREFIX}/lib/libcrypto.a" \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_TESTS=OFF
  cmake --build "${build_dir}" --parallel "${JOBS}"
  cmake --install "${build_dir}"
}

build_curl_tool() {
  local build_dir="$1"
  local prefix_dir="$2"
  local tool_build_dir="${WORK_DIR}/curl-tool"
  local source_list_file="${tool_build_dir}/sources.txt"
  local object_list_file="${tool_build_dir}/objects.txt"
  local source_file
  local object_file

  rm -rf "${tool_build_dir}"
  mkdir -p "${tool_build_dir}/obj" "${prefix_dir}/bin"

  makefile_list_var "${build_dir}/src/Makefile.inc" "CURL_CFILES" > "${source_list_file}"

  if [[ ! -f "${build_dir}/src/tool_hugehelp.c" ]]; then
    cat > "${build_dir}/src/tool_hugehelp.c" <<'EOF'
#include "tool_hugehelp.h"
EOF
  fi

  printf '%s\n' "tool_hugehelp.c" >> "${source_list_file}"
  : > "${object_list_file}"

  while IFS= read -r source_file; do
    [[ -n "${source_file}" ]] || continue
    object_file="${tool_build_dir}/obj/${source_file//\//_}.o"
    mkdir -p "$(dirname "${object_file}")"
    "${CC}" \
      ${CPPFLAGS} \
      ${CFLAGS} \
      -fPIE \
      -DHAVE_CONFIG_H \
      -DCURL_STATICLIB \
      -I"${build_dir}/include" \
      -I"${build_dir}/lib" \
      -I"${build_dir}/src" \
      -I"${build_dir}/src/toolx" \
      -c "${build_dir}/src/${source_file}" \
      -o "${object_file}"
    printf '%s\n' "${object_file}" >> "${object_list_file}"
  done < "${source_list_file}"

  mapfile -t tool_objects < "${object_list_file}"

  "${CC}" \
    -fPIE \
    -pie \
    -o "${prefix_dir}/bin/curl" \
    "${tool_objects[@]}" \
    -Wl,--start-group \
    "${prefix_dir}/lib/libcurl.a" \
    "${DEPS_PREFIX}/lib/libngtcp2_crypto_boringssl.a" \
    "${DEPS_PREFIX}/lib/libngtcp2.a" \
    "${DEPS_PREFIX}/lib/libnghttp3.a" \
    "${DEPS_PREFIX}/lib/libnghttp2.a" \
    "${DEPS_PREFIX}/lib/libssl.a" \
    "${DEPS_PREFIX}/lib/libcrypto.a" \
    "${DEPS_PREFIX}/lib/libzstd.a" \
    "${DEPS_PREFIX}/lib/libbrotlidec.a" \
    "${DEPS_PREFIX}/lib/libbrotlicommon.a" \
    "${MERGE_RUNTIME_LIBS[@]}" \
    -Wl,--end-group \
    -Wl,-Bdynamic \
    -lz \
    -lm \
    -ldl
}

build_curl() {
  local archive="${DOWNLOAD_DIR}/curl-${CURL_VERSION}.tar.gz"
  local source_dir="${SRC_DIR}/curl-${CURL_VERSION}"
  local build_dir="${WORK_DIR}/curl"
  local prefix_dir="${BUILD_ROOT}/curl-prefix"

  fetch_archive "https://curl.se/download/curl-${CURL_VERSION}.tar.gz" "${archive}"
  extract_archive "${archive}" "${source_dir}"

  rm -rf "${build_dir}" "${prefix_dir}" "${DIST_DIR}"
  cp -R "${source_dir}" "${build_dir}"

  pushd "${build_dir}" >/dev/null
    LIBS="-lngtcp2_crypto_boringssl -lngtcp2 -lnghttp3 -lnghttp2 -lssl -lcrypto -lzstd -lbrotlidec -lbrotlicommon -lz ${CPP_RUNTIME_LIBS}"
    LIBS="${LIBS}" ./configure \
      --host="${TARGET_HOST}" \
      --prefix="${prefix_dir}" \
      --disable-dependency-tracking \
      --disable-manual \
      --disable-shared \
      --enable-static \
      --without-libpsl \
      --with-ca-path="${DEFAULT_CA_PATH}" \
      --with-zlib="${DEPS_PREFIX}" \
      --with-brotli="${DEPS_PREFIX}" \
      --with-zstd="${DEPS_PREFIX}" \
      --with-nghttp2="${DEPS_PREFIX}" \
      --with-nghttp3="${DEPS_PREFIX}" \
      --with-ngtcp2="${DEPS_PREFIX}" \
      --with-openssl="${DEPS_PREFIX}"
    make -j"${JOBS}"
    make install
  popd >/dev/null

  build_curl_tool "${build_dir}" "${prefix_dir}"

  mkdir -p "${DIST_DIR}/bin" "${DIST_DIR}/lib" "${DIST_DIR}/include"
  cp -R "${prefix_dir}/include/"* "${DIST_DIR}/include/"
  cp "${prefix_dir}/bin/curl" "${DIST_DIR}/bin/curl"

  merge_static_libraries \
    "${DIST_DIR}/lib/libcurl.a" \
    "${prefix_dir}/lib/libcurl.a" \
    "${DEPS_PREFIX}/lib/libngtcp2_crypto_boringssl.a" \
    "${DEPS_PREFIX}/lib/libngtcp2.a" \
    "${DEPS_PREFIX}/lib/libnghttp3.a" \
    "${DEPS_PREFIX}/lib/libnghttp2.a" \
    "${DEPS_PREFIX}/lib/libssl.a" \
    "${DEPS_PREFIX}/lib/libcrypto.a" \
    "${DEPS_PREFIX}/lib/libzstd.a" \
    "${DEPS_PREFIX}/lib/libbrotlidec.a" \
    "${DEPS_PREFIX}/lib/libbrotlicommon.a" \
    "${DEPS_PREFIX}/lib/libz.a" \
    "${MERGE_RUNTIME_LIBS[@]}"

  cat > "${DIST_DIR}/BUILD_INFO.txt" <<EOF
CURL_VERSION=${CURL_VERSION}
ANDROID_API=${ANDROID_API}
ABI=${ABI}
TARGET_HOST=${TARGET_HOST}
TLS=boringssl
ZLIB_VERSION=${ZLIB_VERSION}
BROTLI_VERSION=${BROTLI_VERSION}
ZSTD_VERSION=${ZSTD_VERSION}
NGHTTP2_VERSION=${NGHTTP2_VERSION}
NGHTTP3_VERSION=${NGHTTP3_VERSION}
NGTCP2_VERSION=${NGTCP2_VERSION}
BORINGSSL_REF=${BORINGSSL_REF}
DEFAULT_CA_PATH=${DEFAULT_CA_PATH}
FEATURES=gz,deflate,br,zstd,http2,http3
LIBCURL_LAYOUT=single-archive
EOF

  echo "Build complete: ${DIST_DIR}"
}

build_zlib
build_brotli
build_zstd
build_boringssl
build_nghttp2
build_nghttp3
build_ngtcp2
build_curl
