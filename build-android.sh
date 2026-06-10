#!/usr/bin/bash
# Standalone Android build script for rustdesk.
# Builds one or more ABI targets and produces APKs in the script directory.
#
# Usage: bash build-android.sh [aarch64|armv7|x86_64|all]
#   Default target: aarch64
#
# Required environment / tools (auto-detected where possible):
#   ANDROID_NDK_HOME  — path to NDK r27c (detected from common install locations)
#   ANDROID_SDK_ROOT  — path to Android SDK (detected from common install locations)
#   JAVA_HOME         — JDK 17 (detected from common install locations)
#   flutter           — must be on PATH (version 3.24.5)
#   cargo / rustup    — must be on PATH
#   cargo-ndk 3.1.2   — installed automatically if missing

set -euo pipefail

_scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${_scriptdir}"

# ── Versions (must match CI) ──────────────────────────────────────────────────
_RUST_VERSION='1.75'
_CARGO_NDK_VERSION='3.1.2'
_NDK_VERSION='r28c'
_FLUTTER_VERSION='3.24.5'
_PKGVER='1.4.7'
_FLUTTER_PATCH='.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff'
_FRBVER='1.80.1'

# ── Colours / logging ─────────────────────────────────────────────────────────
msg()     { printf '\033[1;32m==> \033[0m\033[1m%s\033[0m\n' "$*"; }
msg2()    { printf '\033[1;34m  -> \033[0m%s\n' "$*"; }
error()   { printf '\033[1;31m==> ERROR: \033[0m%s\n' "$*" >&2; exit 1; }

# ── Source directory (reuse what build.sh extracted) ─────────────────────────
_srcdir="${_scriptdir}/src/rustdesk-${_PKGVER}"
[ -d "${_srcdir}" ] || error "Source not found at ${_srcdir}. Run build.sh first (or at least its prepare step)."

# ── Target selection ──────────────────────────────────────────────────────────
_arg="${1:-aarch64}"
case "${_arg}" in
  aarch64) _targets=(aarch64) ;;
  armv7)   _targets=(armv7) ;;
  x86_64)  _targets=(x86_64) ;;
  all)     _targets=(aarch64 armv7 x86_64) ;;
  *) error "Unknown target '${_arg}'. Use: aarch64 | armv7 | x86_64 | all" ;;
esac

# ── Auto-detect Android NDK ───────────────────────────────────────────────────
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  # Try exact letter-version first, then any installed NDK 27.x
  for _c in \
      "${HOME}/Android/Sdk/ndk/${_NDK_VERSION}" \
      "${HOME}/android/ndk/${_NDK_VERSION}" \
      "/opt/android-ndk-${_NDK_VERSION}" \
      "/opt/android/ndk/${_NDK_VERSION}"; do
    if [ -d "${_c}" ]; then
      export ANDROID_NDK_HOME="${_c}"
      break
    fi
  done
  # Fallback: any NDK 27.x under ~/Android/Sdk/ndk/
  if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -d "${HOME}/Android/Sdk/ndk" ]; then
    _c="$(find "${HOME}/Android/Sdk/ndk" -maxdepth 1 -name '27.*' -type d | sort -V | tail -1)"
    [ -d "${_c:-}" ] && export ANDROID_NDK_HOME="${_c}"
  fi
fi
[ -d "${ANDROID_NDK_HOME:-}" ] || error "Android NDK ${_NDK_VERSION} not found. Set ANDROID_NDK_HOME."
export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}"
msg2 "NDK: ${ANDROID_NDK_HOME}"

# ── Auto-detect Android SDK ───────────────────────────────────────────────────
if [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -z "${ANDROID_HOME:-}" ]; then
  for _c in \
      "${HOME}/Android/Sdk" \
      "${HOME}/android/sdk" \
      "/opt/android-sdk" \
      "/opt/android/sdk"; do
    if [ -d "${_c}" ]; then
      export ANDROID_SDK_ROOT="${_c}"
      break
    fi
  done
fi
[ -d "${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}" ] || error "Android SDK not found. Set ANDROID_SDK_ROOT."
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME}}"
msg2 "SDK: ${ANDROID_SDK_ROOT}"

# ── Auto-detect JAVA_HOME (JDK 17) ───────────────────────────────────────────
# Always force JDK 17: Gradle 7.6 supports Java ≤ 20, and an ambient
# JAVA_HOME pointing at Java 21+ causes "Unsupported class file major version 65".
JAVA_HOME=''
for _c in \
    "/usr/lib/jvm/java-17-openjdk-amd64" \
    "/usr/lib/jvm/java-17-openjdk" \
    "/usr/lib/jvm/temurin-17" \
    "/opt/jdk-17"; do
  if [ -d "${_c}" ]; then
    export JAVA_HOME="${_c}"
    break
  fi
done
[ -d "${JAVA_HOME:-}" ] || error "JDK 17 not found. Set JAVA_HOME."
export PATH="${JAVA_HOME}/bin:${PATH}"
msg2 "JAVA_HOME: ${JAVA_HOME}"

# ── Prefer local flutter (extracted by build.sh) over system flutter ─────────
# The system flutter is typically installed read-only (e.g. /usr/lib/flutter),
# which causes Gradle to fail when it tries to create its project cache dir
# inside flutter/packages/flutter_tools/gradle/.gradle/.
_local_flutter="${_scriptdir}/src/flutter/bin"
if [ -x "${_local_flutter}/flutter" ]; then
  export PATH="${_local_flutter}:${PATH}"
  msg2 "Using local flutter: ${_local_flutter}"
fi

# ── Verify flutter ────────────────────────────────────────────────────────────
command -v flutter &>/dev/null || error "flutter not found on PATH."
_fv="$(flutter --version --machine 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['frameworkVersion'])" 2>/dev/null || true)"
msg2 "Flutter: ${_fv:-unknown}"

# ── Verify / install Rust toolchain ──────────────────────────────────────────
if ! rustup toolchain list 2>/dev/null | grep -q "^${_RUST_VERSION}"; then
  msg "Installing Rust toolchain ${_RUST_VERSION}"
  rustup toolchain install "${_RUST_VERSION}" --component rustfmt
fi

# Locate the toolchain bin dir directly so the official rustc (with all LLVM
# backends) takes precedence over any system rustc on PATH.
_RUSTUP_HOME="${RUSTUP_HOME:-${HOME}/.rustup}"
_RUST_BIN=''
for _h in x86_64-unknown-linux-gnu x86_64-unknown-linux-musl aarch64-unknown-linux-gnu; do
  _c="${_RUSTUP_HOME}/toolchains/${_RUST_VERSION}-${_h}/bin"
  if [ -x "${_c}/rustc" ]; then
    _RUST_BIN="${_c}"
    break
  fi
done
[ -n "${_RUST_BIN}" ] || error "Cannot find rustup toolchain ${_RUST_VERSION} bin dir under ${_RUSTUP_HOME}/toolchains — install via: rustup toolchain install ${_RUST_VERSION}"
msg2 "Rust toolchain bin: ${_RUST_BIN}"

# ── Verify / install cargo-ndk ────────────────────────────────────────────────
_CGH="${CARGO_HOME:-${HOME}/.cargo}"
# Prepend the official rustup toolchain and cargo/bin so they shadow any system binaries.
export PATH="${_RUST_BIN}:${_CGH}/bin:${PATH}"
if ! cargo-ndk --version 2>/dev/null | grep -q "${_CARGO_NDK_VERSION}"; then
  msg "Installing cargo-ndk ${_CARGO_NDK_VERSION}"
  cargo install cargo-ndk --version "${_CARGO_NDK_VERSION}" --locked
fi

# ── Patch flutter (dropdown fix for 3.24.5) ──────────────────────────────────
_flutter_root="$(dirname "$(dirname "$(which flutter)")")"
if [ -f "${_srcdir}/${_FLUTTER_PATCH}" ] && [ -d "${_flutter_root}/.git" ]; then
  pushd "${_flutter_root}" > /dev/null
  if ! git apply --check "${_srcdir}/${_FLUTTER_PATCH}" 2>/dev/null; then
    msg2 "Flutter patch already applied or not needed"
  else
    msg2 "Applying flutter patch"
    git apply "${_srcdir}/${_FLUTTER_PATCH}"
  fi
  popd > /dev/null
fi

# ── Apply flutter_rust_bridge patch to generated_bridge.dart if needed ───────
# The bridge file is already present in the source tree; no codegen needed here.

# ── vcpkg for Android ─────────────────────────────────────────────────────────
# Locate the vcpkg directory extracted by build.sh
_VCPKG_COMMIT='120deac3062162151622ca4860575a33844ba10b'
_srcdirvc="${_scriptdir}/src/vcpkg-${_VCPKG_COMMIT}"
[ -d "${_srcdirvc}" ] || error "vcpkg not found at ${_srcdirvc}. Run build.sh prepare step first."
export VCPKG_ROOT="${_srcdirvc}"
if [ ! -x "${VCPKG_ROOT}/vcpkg" ]; then
  msg "Bootstrapping vcpkg"
  "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics
fi

# Android manifest-mode vcpkg needs git baseline resolution.
# The vcpkg dir came from a tarball (no .git), so we seed a repo and override
# the baseline SHA with --x-builtin-baseline=<our-commit>.
if [ ! -d "${VCPKG_ROOT}/.git" ]; then
  msg "Initialising git in vcpkg (needed for baseline resolution)"
  git -C "${VCPKG_ROOT}" init -q
  git -C "${VCPKG_ROOT}" add -A
  GIT_AUTHOR_NAME=build GIT_AUTHOR_EMAIL=build \
  GIT_COMMITTER_NAME=build GIT_COMMITTER_EMAIL=build \
  GIT_AUTHOR_DATE='1970-01-01T00:00:00Z' \
  GIT_COMMITTER_DATE='1970-01-01T00:00:00Z' \
    git -C "${VCPKG_ROOT}" commit -q -m 'offline baseline'
fi
_VCS_SHA="$(git -C "${VCPKG_ROOT}" rev-parse HEAD)"
msg2 "vcpkg baseline SHA: ${_VCS_SHA}"

# vcpkg manifest mode resolves baselines via git; our tarball-extracted vcpkg
# has a freshly-seeded repo, so the SHA in vcpkg.json won't exist in its object
# store. Temporarily patch the baseline SHA to our commit and restore on exit.
_vcpkg_json="${_srcdir}/vcpkg.json"
_vcpkg_json_bak="${_vcpkg_json}.bak.$$"
cp "${_vcpkg_json}" "${_vcpkg_json_bak}"
trap 'mv -f "${_vcpkg_json_bak}" "${_vcpkg_json}"' EXIT INT TERM
python3 - "${_vcpkg_json}" "${_VCS_SHA}" << 'PYEOF'
import json, sys
p, sha = sys.argv[1], sys.argv[2]
with open(p) as f: d = json.load(f)
d['vcpkg-configuration']['default-registry']['baseline'] = sha
with open(p, 'w') as f: json.dump(d, f, indent=2)
PYEOF
msg2 "Patched vcpkg.json baseline → ${_VCS_SHA}"

# ── Per-target build ──────────────────────────────────────────────────────────
_build_target() {
  local _arch="$1"

  local _rust_target _abi _flutter_platform _jnidir _libc_shared_dir _apk_name
  case "${_arch}" in
    aarch64)
      _rust_target='aarch64-linux-android'
      _abi='arm64-v8a'
      _flutter_platform='android-arm64'
      _libc_shared_dir='aarch64-linux-android'
      ;;
    armv7)
      _rust_target='armv7-linux-androideabi'
      _abi='armeabi-v7a'
      _flutter_platform='android-arm'
      _libc_shared_dir='arm-linux-androideabi'
      ;;
    x86_64)
      _rust_target='x86_64-linux-android'
      _abi='x86_64'
      _flutter_platform='android-x64'
      _libc_shared_dir='x86_64-linux-android'
      ;;
  esac
  _jnidir="${_srcdir}/flutter/android/app/src/main/jniLibs/${_abi}"
  _apk_name="rustdesk-${_PKGVER}-${_arch}.apk"

  msg "Building target: ${_arch} (${_rust_target})"

  # vcpkg Android deps — delegate to build_android_deps.sh which runs vcpkg in
  # manifest mode with the correct minimal flags and handles the arm-neon rename.
  msg2 "vcpkg: installing Android deps for ${_abi}"
  (
    ANDROID_NDK="${ANDROID_NDK_HOME}" \
    ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" \
    VCPKG_ROOT="${VCPKG_ROOT}" \
      "${_srcdir}/flutter/build_android_deps.sh" "${_abi}"
  )

  # Rust target
  msg2 "rustup: adding target ${_rust_target}"
  rustup target add "${_rust_target}" --toolchain "${_RUST_VERSION}"

  # cargo ndk build — PATH already has the official rustup toolchain first
  msg2 "cargo ndk: building librustdesk.so"
  (
    cd "${_srcdir}"
    local _features='flutter,hwcodec'
    [ "${_arch}" = 'x86_64' ] && _features='flutter'
    # Tell bindgen's clang to use the NDK sysroot instead of the host /usr/include.
    # Without this, x86-only headers (e.g. __float128 in floatn.h) cause build failures
    # when cross-compiling for Android targets.
    local _ndk_sysroot="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local _bindgen_var="BINDGEN_EXTRA_CLANG_ARGS_${_rust_target//-/_}"
    export "${_bindgen_var}"="--sysroot=${_ndk_sysroot} --target=${_rust_target}"
    ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" \
    ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}" \
      cargo ndk \
        --platform 22 \
        --target "${_rust_target}" \
        build --release --features "${_features}"
  )

  # Copy .so into jniLibs
  mkdir -p "${_jnidir}"
  cp "${_srcdir}/target/${_rust_target}/release/liblibrustdesk.so" \
     "${_jnidir}/librustdesk.so"

  # libc++_shared.so
  cp "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/${_libc_shared_dir}/libc++_shared.so" \
     "${_jnidir}/"

  # Gradle JVM bump + debug signing
  sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx4g/" \
      "${_srcdir}/flutter/android/gradle.properties"
  sed -i "s/signingConfigs.release/signingConfigs.debug/" \
      "${_srcdir}/flutter/android/app/build.gradle"

  # flutter build apk
  msg2 "flutter build apk (${_flutter_platform})"
  (
    cd "${_srcdir}/flutter"
    flutter build apk --release --target-platform "${_flutter_platform}" --split-per-abi
  )

  local _built_apk
  case "${_arch}" in
    aarch64) _built_apk="${_srcdir}/flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" ;;
    armv7)   _built_apk="${_srcdir}/flutter/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk" ;;
    x86_64)  _built_apk="${_srcdir}/flutter/build/app/outputs/flutter-apk/app-x86_64-release.apk" ;;
  esac
  cp "${_built_apk}" "${_scriptdir}/${_apk_name}"
  msg "Output: ${_scriptdir}/${_apk_name}"
}

msg "Building rustdesk ${_PKGVER} for Android — targets: ${_targets[*]}"

for _t in "${_targets[@]}"; do
  _build_target "${_t}"
done

msg "Done"
