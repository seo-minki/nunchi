#!/bin/sh
# nunchi 설치: 빌드한 뒤 $PREFIX/bin/nunchi 로 복사한다 (기본 /usr/local/bin, macOS 기본 PATH에 들어 있음)
#   ./install.sh                 설치 (처음 설치한 위치·방식을 기억해 두고 업데이트 때 그대로 쓴다)
#   PREFIX=~/.local ./install.sh 다른 위치에 설치
#   ./install.sh --link          복사 대신 이 저장소의 빌드로 바로가기를 건다 (개발용, 업데이트 때 다시 빌드만 함)
#   ./install.sh --remove        지우기
set -e
cd "$(dirname "$0")"
CONFIG="$HOME/.config/nunchi"

# 위치·방식을 따로 정하지 않으면 지난번 설치 때 기억해 둔 값을 쓴다 (업데이트가 엉뚱한 곳에 설치하지 않게)
SAVED_PREFIX=$(cat "$CONFIG/prefix" 2>/dev/null || true)
SAVED_MODE=$(cat "$CONFIG/mode" 2>/dev/null || true)
PREFIX="${PREFIX:-${SAVED_PREFIX:-/usr/local}}"
MODE="${SAVED_MODE:-copy}"
[ "$1" = "--link" ] && MODE=link
[ "$1" = "--copy" ] && MODE=copy
DEST="$PREFIX/bin/nunchi"

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
  rm -f "$CONFIG/source" "$CONFIG/prefix" "$CONFIG/mode"
  echo "지웠습니다: $DEST"
  exit 0
fi

./build.sh
run mkdir -p "$PREFIX/bin"
if [ "$MODE" = link ]; then
  run ln -sf "$PWD/nunchi" "$DEST"
else
  run rm -f "$DEST"   # 예전에 바로가기였다면 바로가기가 가리키는 파일을 덮어쓰지 않도록 먼저 지운다
  run cp nunchi "$DEST"
fi
# nunchi --update가 이 저장소에서, 같은 위치·방식으로 업데이트할 수 있게 기억해 둔다
mkdir -p "$CONFIG"
pwd > "$CONFIG/source"
echo "$PREFIX" > "$CONFIG/prefix"
echo "$MODE" > "$CONFIG/mode"
echo "설치했습니다: $DEST ($(./nunchi --version)$([ "$MODE" = link ] && echo ", 바로가기"))"
echo "처음 실행하기 전에 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 터미널 앱을 켜 주세요."
