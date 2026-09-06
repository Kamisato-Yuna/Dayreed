#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--verify|--logs|--debug) ;; *) echo "usage: $0 [--verify|--logs|--debug]" >&2; exit 2;; esac
APP_PATH="$ROOT_DIR/build/debug/Dayreed.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Dayreed"
# Stop only this checkout's generated app, never an installed or other checkout's app.
while read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(ps -p "$pid" -o comm=)"
    if [[ "$executable" == "$APP_BINARY" ]]; then
        kill -TERM "$pid"
    fi
done < <(pgrep -x Dayreed || true)
"$ROOT_DIR/script/build_app.sh" debug
if [[ "$MODE" == "--debug" ]]; then
    exec lldb -- "$APP_BINARY"
fi
/usr/bin/open -n -F "$APP_PATH"
case "$MODE" in
    --verify)
        sleep 1
        found=0
        while read -r pid; do
            [[ -n "$pid" ]] || continue
            if [[ "$(ps -p "$pid" -o comm=)" == "$APP_BINARY" ]]; then
                echo "Dayreed PID: $pid ($APP_BINARY)"
                found=1
            fi
        done < <(pgrep -x Dayreed || true)
        [[ "$found" == 1 ]]
        ;;
    --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Dayreed"';;
esac
