#!/bin/sh
# nunchi 빌드 (Swift 6 동시성 경고는 Swift 5 모드에서 무해하므로 숨긴다)
cd "$(dirname "$0")" && swiftc -O -suppress-warnings main.swift -o nunchi
