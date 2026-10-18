#!/usr/bin/env bash
set -euo pipefail

sample_mode=comparison
sample_check=false
sample_build_runtime=false
for sample_argument in "$@"; do
  case "${sample_argument}" in
    --coreml) sample_mode=coreml ;;
    --comparison) sample_mode=comparison ;;
    --check) sample_check=true ;;
    --build-runtime) sample_build_runtime=true ;;
    --help|-h)
      echo 'Usage: bash Scripts/setup.sh [--comparison|--coreml] [--check] [--build-runtime]'
      echo 'Samples open directly in Xcode; setup is optional.'
      echo '--check: check Xcode and bundled files without downloads or builds.'
      echo '--build-runtime: rebuild and package speech.cpp from pinned source (developer tools required).'
      exit 0 ;;
    *) echo "Unknown option: ${sample_argument}" >&2; exit 2 ;;
  esac
done
sample_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'Use an Apple Silicon Mac with the full Xcode app selected.' >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null || ! xcodebuild -version >/dev/null 2>&1; then
  echo 'Install Xcode and select it with xcode-select before running setup.' >&2
  exit 1
fi
xcodebuild -version
if [[ "${sample_build_runtime}" == true && "${sample_mode}" != comparison ]]; then
  echo '--build-runtime requires --comparison.' >&2
  exit 2
fi
if [[ "${sample_mode}" == comparison ]]; then
  if [[ "${sample_build_runtime}" == true ]]; then
    sample_missing=()
    for sample_tool in git cmake ninja python3; do
      command -v "${sample_tool}" >/dev/null || sample_missing+=("${sample_tool}")
    done
    if [[ ${#sample_missing[@]} -gt 0 ]]; then
      echo "Missing developer tools: ${sample_missing[*]}" >&2
      echo 'Source builds require Git, CMake, Ninja and Python 3.' >&2
      exit 1
    fi
    if [[ "${sample_check}" == false ]]; then
      bash "${sample_root}/Packages/IrodoriSpeechCpp/Scripts/build-runtime.sh"
    fi
  fi
  if [[ ! -f "${sample_root}/Packages/IrodoriSpeechCpp/Artifacts/SpeechCpp.xcframework.zip" ]]; then
    echo 'The bundled runtime is missing. Get the complete repository or project ZIP.' >&2
    exit 1
  fi
  sample_project=IrodoriComparison
else
  sample_project=IrodoriSamples
fi
if [[ "${sample_check}" == true ]]; then
  echo "Prerequisites OK (${sample_mode}); no downloads or builds performed."
else
  echo "Open ${sample_root}/Examples/${sample_project}.xcodeproj"
  echo 'Choose your Signing Team and a unique Bundle Identifier before running on iPhone.'
fi
