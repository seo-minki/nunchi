#!/bin/sh
# nunchi 설치: 빌드한 뒤 $PREFIX/bin/nunchi 로 복사한다 (기본 /usr/local/bin, macOS 기본 PATH에 들어 있음)
# 지우기: ./install.sh --remove
set -e
cd "$(dirname "$0")"
PREFIX="${PREFIX:-/usr/local}"
DEST="$PREFIX/bin/nunchi"
CONFIG="$HOME/.config/nunchi"

# 쓰기 권한이 없는 폴더면 sudo로 실행한다 (폴더가 아직 없으면 가장 가까운 상위 폴더로 판단)
writable() { d="$PREFIX/bin"; while [ ! -e "$d" ]; do d=$(dirname "$d"); done; [ -w "$d" ]; }
run() {
  if writable; then "$@"; return; fi
  if [ -z "$ASKED" ]; then echo "$PREFIX/bin 에 설치하려면 관리자 비밀번호가 필요합니다."; ASKED=1; fi
  sudo "$@"
}

# v0.2.0까지는 명령어 이름이 kt였다. 이 프로젝트가 설치한 kt면 정리한다.
LEGACY="$PREFIX/bin/kt"
if [ -f "$LEGACY" ] && grep -q "com.kakao.KakaoTalkMac" "$LEGACY" 2>/dev/null; then
  run rm -f "$LEGACY"
  echo "예전 명령어를 정리했습니다: $LEGACY (이제 nunchi로 실행하세요)"
fi

if [ "$1" = "--remove" ]; then
  run rm -f "$DEST"
  rm -f "$CONFIG/source"
  echo "지웠습니다: $DEST"
  exit 0
fi

./build.sh
run mkdir -p "$PREFIX/bin"
run cp nunchi "$DEST"
# nunchi --update가 이 저장소에서 업데이트할 수 있게 위치를 기억해 둔다
mkdir -p "$CONFIG"
pwd > "$CONFIG/source"
echo "설치했습니다: $DEST ($(./nunchi --version))"
echo "처음 실행하기 전에 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 터미널 앱을 켜 주세요."
