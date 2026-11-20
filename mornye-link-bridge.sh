#!/bin/sh
# Installer/controller for Mornye Link Player on Yandex Station 2.
set -u
BIN_DIR=/data/local/bin
TMP_DIR=/data/local/tmp
PID_FILE=/tmp/mornye-link-ws.pid
LOG_FILE=/tmp/mornye-link-ws.log
BIN_ARM64="$BIN_DIR/mornye-link-ws-arm64"
BIN_ARM="$BIN_DIR/mornye-link-ws-armv7"
LED_BIN="$BIN_DIR/mornye-ledviz"

say() { printf '%s\n' "$*"; }
err() { say "ОШИБКА: $*" >&2; exit 1; }
need_root() { [ "$(id -u 2>/dev/null)" = 0 ] || err "Нужен root: сначала выполни su."; }

choose_bin() {
    BITS=$(getconf LONG_BIT 2>/dev/null || echo '')
    # Test executability on the actual Station userspace rather than relying
    # on uname, which reports the kernel ABI and may differ from the userspace.
    if [ "$BITS" = "64" ] && [ -x "$BIN_ARM64" ] && "$BIN_ARM64" --version >/dev/null 2>&1; then
        BIN="$BIN_ARM64"; return 0
    fi
    if [ "$BITS" = "32" ] && [ -x "$BIN_ARM" ] && "$BIN_ARM" --version >/dev/null 2>&1; then
        BIN="$BIN_ARM"; return 0
    fi
    if [ -x "$BIN_ARM64" ] && "$BIN_ARM64" --version >/dev/null 2>&1; then
        BIN="$BIN_ARM64"; return 0
    fi
    if [ -x "$BIN_ARM" ] && "$BIN_ARM" --version >/dev/null 2>&1; then
        BIN="$BIN_ARM"; return 0
    fi
    err "Не удалось запустить ни ARM64, ни ARMv7 бинарник. getconf LONG_BIT=${BITS:-unknown}, uname -m=$(uname -m 2>/dev/null)."
}

find_binary() {
    wanted="$1"
    supplied_dir="${2:-$TMP_DIR}"
    for candidate in \
        "$supplied_dir/$wanted" \
        "$TMP_DIR/$wanted" \
        "/data/local/tmp/station-mornye/$wanted" \
        "/sdcard/Download/$wanted" \
        "/storage/emulated/0/Download/$wanted"; do
        if [ -f "$candidate" ]; then
            bytes=$(wc -c < "$candidate" 2>/dev/null | tr -d ' ')
            case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
            if [ "$bytes" -gt 100000 ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

install_bins() {
    need_root
    SOURCE_DIR="${1:-$TMP_DIR}"
    mkdir -p "$BIN_DIR" || err "Не удалось создать $BIN_DIR."
    COPIED=0

    SRC64=$(find_binary mornye-link-ws-arm64 "$SOURCE_DIR" 2>/dev/null || true)
    if [ -n "$SRC64" ]; then
        say "Найден ARM64: $SRC64"
        if [ -s "$BIN_ARM64" ] && [ ! -s "$BIN_ARM64.pre-v0.3.bak" ]; then cp "$BIN_ARM64" "$BIN_ARM64.pre-v0.3.bak" 2>/dev/null || true; fi
        cp "$SRC64" "$BIN_ARM64" || err "Не удалось скопировать ARM64-бинарник."
        chmod 755 "$BIN_ARM64" || err "Не удалось назначить права на ARM64-бинарник."
        [ -s "$BIN_ARM64" ] && [ -x "$BIN_ARM64" ] || err "ARM64-бинарник скопирован некорректно."
        COPIED=1
    else
        say "ARM64-бинарник не найден в $SOURCE_DIR и стандартных папках."
    fi

    SRCARM=$(find_binary mornye-link-ws-armv7 "$SOURCE_DIR" 2>/dev/null || true)
    if [ -n "$SRCARM" ]; then
        say "Найден ARMv7: $SRCARM"
        if [ -s "$BIN_ARM" ] && [ ! -s "$BIN_ARM.pre-v0.3.bak" ]; then cp "$BIN_ARM" "$BIN_ARM.pre-v0.3.bak" 2>/dev/null || true; fi
        cp "$SRCARM" "$BIN_ARM" || err "Не удалось скопировать ARMv7-бинарник."
        chmod 755 "$BIN_ARM" || err "Не удалось назначить права на ARMv7-бинарник."
        [ -s "$BIN_ARM" ] && [ -x "$BIN_ARM" ] || err "ARMv7-бинарник скопирован некорректно."
        COPIED=1
    else
        say "ARMv7-бинарник не найден в $SOURCE_DIR и стандартных папках."
    fi

    [ "$COPIED" = 1 ] || {
        say "Содержимое $TMP_DIR (имена, начинающиеся с mornye-link):"
        ls -la "$TMP_DIR"/mornye-link* 2>&1 || true
        err "Бинарные файлы не найдены. Повтори adb push ARM64/ARMv7 файлов."
    }

    # The LED renderer is optional. Install the binary matching the actual
    # userspace ABI, not merely the kernel's uname architecture.
    BITS=$(getconf LONG_BIT 2>/dev/null || echo '')
    LED_SOURCE=''
    if [ "$BITS" = "32" ]; then
        LED_SOURCE=$(find_binary mornye-ledviz-armv7 "$SOURCE_DIR" 2>/dev/null || true)
    else
        LED_SOURCE=$(find_binary mornye-ledviz-arm64 "$SOURCE_DIR" 2>/dev/null || true)
    fi
    if [ -n "$LED_SOURCE" ]; then
        cp "$LED_SOURCE" "$LED_BIN" || err "Не удалось установить LED renderer."
        chmod 755 "$LED_BIN" || err "Не удалось назначить права LED renderer."
        say "LED renderer установлен: $LED_BIN (source=$LED_SOURCE)."
    else
        say "LED renderer не найден; остальные функции плеера установлены. LED можно добавить отдельно."
        rm -f "$LED_BIN"
    fi

    # The Go bridge invokes this exact path for playback commands.
    if [ -s "$TMP_DIR/mornye-station2.sh" ]; then
        chmod 755 "$TMP_DIR/mornye-station2.sh" || err "Не удалось назначить права player shell script."
    fi
    say "Установка завершена. Содержимое $BIN_DIR:"
    ls -l "$BIN_DIR"/mornye-link-ws-* "$LED_BIN" 2>/dev/null || true
    [ -s "$TMP_DIR/mornye-station2.sh" ] && say "Player shell script: $TMP_DIR/mornye-station2.sh" || say "ВНИМАНИЕ: не вижу $TMP_DIR/mornye-station2.sh; передай его отдельно через adb push."
}

start_client() {
    need_root
    [ -s /data/local/etc/mornye-link.json ] || err "Не найден API config /data/local/etc/mornye-link.json."
    [ -s /data/local/etc/mornye-link-cert.pem ] || err "Не найден TLS-сертификат /data/local/etc/mornye-link-cert.pem."
    [ -s /data/local/tmp/mornye-station2.sh ] || err "Не найден player script /data/local/tmp/mornye-station2.sh. Передай его через adb push."
    if [ -f "$PID_FILE" ]; then
        OLD=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then say "Mornye Link WS уже запущен, PID=$OLD"; return 0; fi
        rm -f "$PID_FILE"
    fi
    choose_bin
    mkdir -p "$BIN_DIR" || err "Не удалось создать $BIN_DIR."
    rm -f "$LOG_FILE"
    "$BIN" >> "$LOG_FILE" 2>&1 &
    PID=$!
    sleep 2
    if kill -0 "$PID" 2>/dev/null; then
        printf '%s\n' "$PID" > "$PID_FILE"
        say "Mornye Link WS запущен: PID=$PID, ABI=$BIN"
        say "Журнал: $LOG_FILE"
        return 0
    fi
    wait "$PID" 2>/dev/null || true
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    err "Не удалось запустить WS-клиент."
}

stop_client() {
    need_root
    if [ ! -f "$PID_FILE" ]; then say "WS-клиент не запущен (PID-файл отсутствует)."; return 0; fi
    PID=$(cat "$PID_FILE" 2>/dev/null)
    case "$PID" in *[!0-9]*|'') rm -f "$PID_FILE"; err "Некорректный PID-файл." ;; esac
    kill -TERM "$PID" 2>/dev/null || true
    N=0
    while kill -0 "$PID" 2>/dev/null && [ "$N" -lt 5 ]; do sleep 1; N=$((N+1)); done
    kill -KILL "$PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    say "WS-клиент остановлен."
}

status_client() {
    if [ -f "$PID_FILE" ]; then PID=$(cat "$PID_FILE" 2>/dev/null); if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then say "WS-клиент работает, PID=$PID"; else say "PID-файл устарел."; fi; else say "WS-клиент не запущен."; fi
    [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE"
}

case "${1:-}" in
    install) install_bins "${2:-$TMP_DIR}" ;;
    start) start_client ;;
    stop) stop_client ;;
    restart) stop_client; start_client ;;
    status) status_client ;;
    log) [ -f "$LOG_FILE" ] || err "Журнал пока не создан."; tail -n 80 "$LOG_FILE" ;;
    *) say "Использование: sh $0 {install|start|stop|restart|status|log}"; exit 2 ;;
esac
