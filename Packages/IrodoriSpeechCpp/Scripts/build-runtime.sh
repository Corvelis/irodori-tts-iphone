#!/usr/bin/env bash
set -euo pipefail

# Build the pinned runtime with its own ggml and Objective-C Metal class.
speech_revision=a72f1bbedd50e293d5b3f4c2bf0fb44ec003227d
speech_ggml_revision=a655cf6910770404213bc338e622cd82b08ca277
speech_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
speech_cache="${speech_root}/.build/runtime"
speech_source="${SPEECH_CPP_SOURCE:-${speech_cache}/source}"
speech_destination="${speech_root}/Frameworks"
speech_jobs="${SPEECH_CPP_BUILD_JOBS:-4}"
# Use portable diagnostic paths in the distributed binary.
speech_path_flags="-ffile-prefix-map=\"${speech_root}=IrodoriSpeechCpp\" -fdebug-prefix-map=\"${speech_root}=IrodoriSpeechCpp\""
mkdir -p "${speech_cache}" "${speech_destination}"

# Keep unchanged public headers stable so rebuilding a kernel does not invalidate
# the app's imported Clang modules and force every Swift source to recompile.
speech_write_if_changed() {
  local speech_output="$1"
  local speech_temporary
  speech_temporary="$(mktemp "${speech_output}.tmp.XXXXXX")"
  cat > "${speech_temporary}"
  if cmp -s "${speech_temporary}" "${speech_output}"; then
    rm "${speech_temporary}"
  else
    chmod 644 "${speech_temporary}"
    mv "${speech_temporary}" "${speech_output}"
  fi
}

if [[ ! -d "${speech_source}/.git" ]]; then
  git init "${speech_source}"
  git -C "${speech_source}" remote add origin https://github.com/nyosegawa/speech.cpp.git
fi
if [[ "$(git -C "${speech_source}" rev-parse HEAD 2>/dev/null || true)" != "${speech_revision}" ]]; then
  if [[ -n "$(git -C "${speech_source}" status --porcelain --untracked-files=no)" ]]; then
    echo "speech.cpp source has local changes; select a clean SPEECH_CPP_SOURCE." >&2
    exit 1
  fi
  git -C "${speech_source}" fetch --depth 1 origin "${speech_revision}"
  git -C "${speech_source}" checkout --detach FETCH_HEAD
fi
git -C "${speech_source}" submodule sync --recursive
git -C "${speech_source}" submodule update --init --depth 1
if [[ "$(git -C "${speech_source}/ggml" rev-parse HEAD)" != "${speech_ggml_revision}" ]]; then
  echo 'Unexpected ggml revision in the pinned speech.cpp source.' >&2
  exit 1
fi
if [[ -n "$(git -C "${speech_source}" status --porcelain --untracked-files=no)" ]]; then
  echo 'The pinned speech.cpp/ggml checkout contains local changes; use a clean source.' >&2
  exit 1
fi
speech_version="$(tr -d '\r\n' < "${speech_source}/VERSION")"
cp "${speech_source}/LICENSE" "${speech_root}/LICENSES/speech.cpp-MIT.txt"
cp "${speech_source}/ggml/LICENSE" "${speech_root}/LICENSES/ggml-MIT.txt"
speech_patched="${speech_cache}/asr-metal4-source"
python3 "${speech_root}/Scripts/Patches/patch_metal.py" "${speech_source}" "${speech_patched}"
python3 "${speech_root}/Scripts/Patches/patch_speech_tts.py" "${speech_patched}"
python3 "${speech_root}/Scripts/Patches/patch_cpu_idle.py" "${speech_patched}"
python3 "${speech_root}/Scripts/Patches/patch_mobile_memory.py" "${speech_patched}"

speech_frameworks=()
for speech_sdk in iphoneos iphonesimulator; do
  speech_build="${speech_cache}/${speech_sdk}-asr-metal4"
  cmake -S "${speech_patched}" -B "${speech_build}" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="${speech_sdk}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.1 \
    -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_TARGET_OS=ios \
    -DGGML_BLAS=OFF -DGGML_ACCELERATE=ON \
    -DGGML_BUILD_COMMIT="${speech_ggml_revision:0:7}+stackchan" \
    -DCMAKE_C_FLAGS="-DGGMLMetalClass=SpeechCppMetalClass ${speech_path_flags}" \
    -DCMAKE_CXX_FLAGS="${speech_path_flags}"
  cmake --build "${speech_build}" --target speech -j "${speech_jobs}"
  speech_framework="${speech_build}/SpeechCpp.framework"
  mkdir -p "${speech_framework}/Headers" "${speech_framework}/Modules"
  cp "${speech_build}/libspeech.3.dylib" "${speech_framework}/SpeechCpp"
  install_name_tool -id '@rpath/SpeechCpp.framework/SpeechCpp' "${speech_framework}/SpeechCpp"
  if ! cmp -s "${speech_source}/include/speech.h" "${speech_framework}/Headers/speech.h"; then
    cp -p "${speech_source}/include/speech.h" "${speech_framework}/Headers/"
  fi
  speech_write_if_changed "${speech_framework}/Headers/SpeechCppBuild.h" <<BUILD
#pragma once
#define STACKCHAN_SPEECH_REVISION "${speech_revision}"
#define STACKCHAN_SPEECH_GGML_REVISION "${speech_ggml_revision}"
BUILD
  speech_write_if_changed "${speech_framework}/Modules/module.modulemap" <<'MODULE'
framework module SpeechCpp {
  umbrella header "speech.h"
  export *
}
MODULE
  speech_write_if_changed "${speech_framework}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.stackchan.speechcpp.runtime</string>
<key>CFBundleName</key><string>SpeechCpp</string>
<key>CFBundleExecutable</key><string>SpeechCpp</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>${speech_version}</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$(if [[ "${speech_sdk}" = iphoneos ]]; then echo iPhoneOS; else echo iPhoneSimulator; fi)</string></array>
</dict></plist>
PLIST
  speech_frameworks+=(-framework "${speech_framework}")
done
# Only replace the previously generated runtime after both builds succeed.
speech_staged="${speech_cache}/packaged/SpeechCpp.xcframework"
mkdir -p "${speech_cache}/packaged"
if [[ -d "${speech_staged}" ]]; then rm -rf "${speech_staged}"; fi
xcodebuild -create-xcframework "${speech_frameworks[@]}" -output "${speech_staged}"
if [[ -d "${speech_destination}/SpeechCpp.xcframework" ]]; then
  rm -rf "${speech_destination}/SpeechCpp.xcframework"
fi
cp -pR "${speech_staged}" "${speech_destination}/"
python3 "${speech_root}/../../Scripts/package_speech_runtime.py"
echo "speech.cpp ${speech_version} installed (${speech_revision}). Open Examples/IrodoriComparison.xcodeproj from the repository root."
