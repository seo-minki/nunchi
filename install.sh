#!/bin/sh
# kt 설치: 빌드한 뒤 $PREFIX/bin/kt 로 복사한다 (기본 /usr/local/bin, macOS 기본 PATH에 들어 있음)
# 지우기: ./install.sh --remove
set -e
cd "$(dirname "$0")"
PREFIX="${PREFIX:-/usr/local}"
DEST="$PREFIX/bin/kt"

# 쓰기 권한이 없는 폴더면 sudo로 실행한다 (폴더가 아직 없으면 가장 가까운 상위 폴더로 판단)
writable() { d="$PREFIX/bin"; while [ ! -e "$d" ]; do d=$(dirname "$d"); done; [ -w "$d" ]; }
run() { if writable; then "$@"; else sudo "$@"; fi }

if [ "$1" = "--remove" ]; then
  run rm -f "$DEST"
  echo "지웠습니다: $DEST"
  exit 0
fi

./build.sh
run mkdir -p "$PREFIX/bin"
run cp kt "$DEST"
echo "설치했습니다: $DEST"
echo "처음 실행하기 전에 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 터미널 앱을 켜 주세요."
