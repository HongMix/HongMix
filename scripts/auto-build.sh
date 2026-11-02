#!/bin/bash
# 자동 빌드 루프: 한 번 실행해 두면 Claude가 build/control/cmd 파일을 써서
# 다시 빌드 / 앱 실행 / 스크린샷 / DMG 생성을 요청할 수 있습니다. 창을 닫으면 종료.
cd "$(dirname "$0")/.."
for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$p" ] && eval "$("$p" shellenv)" && break
done
mkdir -p build/control build/logs
ST=build/logs/auto-status.txt
APPBIN=build/cli/HongMix.app/Contents/MacOS/HongMix
APP_PID=""
note() { echo "$(date '+%H:%M:%S') $*" | tee -a "$ST"; }
stop_app() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; APP_PID=""; pkill -x HongMix 2>/dev/null
  for i in 1 2 3 4 5 6; do pgrep -x HongMix >/dev/null || break; sleep 0.5; done
  # anything still alive (stuck in shutdown) is killed — never leave two instances fighting over GPU/ports
  for i in 1 2 3 4 5 6 7 8 9 10; do
    P=$(pgrep -x HongMix) || break
    kill -9 $P 2>/dev/null; sleep 0.5
  done
  pgrep -x HongMix >/dev/null && note "경고: 이전 앱 프로세스가 남아 있음 ($(pgrep -x HongMix | tr '\n' ' '))"
}
: > "$ST"
note "자동 빌드 시작 (첫 실행: 전체 점검)"
bash scripts/check-build.sh > build/logs/run.txt 2>&1
tail -3 build/logs/run.txt | head -1 | while read -r l; do note "$l"; done
grep -q "BUILD SUCCEEDED" build/logs/run.txt && note "RESULT ok" || note "RESULT fail"
note "대기 중 — 이 창은 열어 두세요"
while true; do
  if [ -f build/control/cmd ]; then
    CMD="$(cat build/control/cmd)"; rm -f build/control/cmd
    note "명령: $CMD"
    case "$CMD" in
      build)
        stop_app
        bash scripts/build-cli.sh release > build/logs/run.txt 2>&1
        grep -q "BUILD SUCCEEDED" build/logs/run.txt && note "RESULT ok" || note "RESULT fail $(tail -1 build/logs/run.txt)" ;;
      run)
        stop_app
        "$APPBIN" > build/logs/app.log 2>&1 &
        APP_PID=$!
        sleep 6
        if kill -0 "$APP_PID" 2>/dev/null; then note "RESULT running pid=$APP_PID"; else note "RESULT crashed"; fi ;;
      shot)
        bash scripts/ui-shot.sh > build/logs/ui.txt 2>&1; note "RESULT shot $(tail -1 build/logs/ui.txt)" ;;
      test)
        bash scripts/smoke-test.sh > build/logs/test.txt 2>&1; note "RESULT test $(tail -1 build/logs/test.txt)" ;;
      quit-app)
        stop_app; note "RESULT stopped" ;;
      dmg)
        stop_app
        bash scripts/make-dmg.sh > build/logs/dmg.txt 2>&1 && note "RESULT ok $(tail -1 build/logs/dmg.txt)" || note "RESULT fail $(tail -1 build/logs/dmg.txt)" ;;
      exit)
        stop_app; note "종료"; exit 0 ;;
      *) note "RESULT unknown" ;;
    esac
    note "대기 중"
  fi
  sleep 2
done
