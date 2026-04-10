# mini-curl

Android `arm64-v8a` curl/libcurl build system with full compression and modern HTTP support.

## Features

- Uses the latest curl release by default.
- Builds a single `libcurl.a` and a single `curl` executable for Android `arm64-v8a`.
- Enables `gz`, `deflate`, `br`, `zstd`, `http2`, and `http3`.
- Uses BoringSSL for TLS and QUIC.
- Builds all required third-party dependencies from source.
- Runs locally or in GitHub Actions.

## Dependency stack

- `zlib` for `gz` / `deflate`
- `brotli` for `br`
- `zstd` for `zstd`
- `BoringSSL` for TLS
- `nghttp2` for HTTP/2
- `nghttp3` + `ngtcp2` for HTTP/3

## Host requirements

- Linux or macOS
- `bash`, `curl`, `tar`, `git`, `perl`
- `cmake`, `ninja`, `make`, `pkg-config`
- Android NDK via `ANDROID_NDK_HOME` or `ANDROID_NDK_ROOT`

## Quick start

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk
./scripts/build-android-arm64.sh
```

## Common options

```bash
CURL_VERSION=latest ./scripts/build-android-arm64.sh
CURL_VERSION=8.19.0 ./scripts/build-android-arm64.sh
BORINGSSL_REF=main ./scripts/build-android-arm64.sh
ANDROID_API=30 JOBS=8 ./scripts/build-android-arm64.sh
DEFAULT_CA_PATH=/system/etc/security/cacerts ./scripts/build-android-arm64.sh
```

## Output

- `dist/curl-<version>-android-arm64-v8a/bin/curl`
- `dist/curl-<version>-android-arm64-v8a/lib/libcurl.a`
- `dist/curl-<version>-android-arm64-v8a/include/curl/*.h`
- `dist/curl-<version>-android-arm64-v8a/BUILD_INFO.txt`

`lib/libcurl.a` is a merged static archive containing curl plus its compression, TLS, HTTP/2, and HTTP/3 dependencies.

`bin/curl` is relinked as an Android-native PIE that keeps core system dependencies dynamic (`libc.so`, `libm.so`, `libdl.so`, `libz.so`) instead of trying to fold them into a self-contained executable.

## GitHub Actions

Workflow file: `.github/workflows/android-arm64.yml`

It installs build tooling, builds all dependencies plus curl, and uploads `curl-android-arm64.tar.gz` as an artifact.

## Notes

- The script currently targets only `arm64-v8a`.
- The default `ANDROID_API` is `30` to keep the generated executable compatible with modern Android ELF TLS behavior on arm64.
- The default CA directory is `/system/etc/security/cacerts`; override `DEFAULT_CA_PATH` if your Android environment uses a different trust store path.
- curl defaults to the latest release by parsing curl's official release table.
- BoringSSL defaults to `main`; pin `BORINGSSL_REF` if you want reproducible builds.
- The packaged output intentionally keeps only one static SDK archive: `lib/libcurl.a`.
