#!/bin/bash
# Build and run the TTS provider benchmark (Tools/SpeechBench).
#   scripts/speech-bench.sh init          write ~/.config/mtool/speech-bench.json to fill in
#   scripts/speech-bench.sh run [...]     measure; see Tools/SpeechBench/README.md
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -o build/speech-bench \
  Sources/Core/Config/JSONValue.swift \
  Sources/Core/Speech/*.swift Sources/Core/Speech/Engines/*.swift \
  Tools/SpeechBench/*.swift
exec build/speech-bench "$@"
