#!/bin/sh
# Mornye Link / OpenSubsonic player for retail Yandex Station 2.
# Uses the Mornye API key obtained by pair-mornye-station2.ps1 and the
# self-signed Mornye certificate exported by export-mornye-cert.ps1.
# HTTP/TLS is handled by the Station's bundled GStreamer souphttpsrc plugin;
# curl, wget-HTTPS and openssl are not required on the Station.

set -u
umask 077

CONFIG_FILE="/data/local/etc/mornye-link.json"
CERT_FILE="/data/local/etc/mornye-link-cert.pem"
STATE_DIR="/data/local/etc"
HOSTS_FILE="/etc/hosts"
HOSTS_SHADOW="$STATE_DIR/mornye-station2.hosts"
HOSTS_SHADOW_TMP="$STATE_DIR/mornye-station2.hosts.tmp"
HOSTS_MOUNT_MARKER="/tmp/mornye-station2-hosts-mounted"
HOSTS_MARKER="# MornyeStation2"
HOST_NAME="mornye.local"
QUASAR_DIR="/system/vendor/quasar"
MAIND="$QUASAR_DIR/maind"
QUEUE_FILE="$STATE_DIR/mornye-station2.queue"
PID_FILE="/tmp/mornye-station2-wrapper.pid"
GST_PID_FILE="/tmp/mornye-station2-gst.pid"
STOP_FILE="/tmp/mornye-station2-stop"
POSITION_FILE="/tmp/mornye-station2-position"
SEEK_FILE="/tmp/mornye-station2-seek-ms"
NEXT_FILE="/tmp/mornye-station2-next"
PAUSED_FILE="/tmp/mornye-station2-paused"
RESTART_MARKER_FILE="/tmp/mornye-station2-track-restart"
REPEAT_FILE="$STATE_DIR/mornye-station2-repeat"
VOLUME_FILE="$STATE_DIR/mornye-station2-volume"
LED_ENABLE_FILE="$STATE_DIR/mornye-station2-ledviz.enabled"
LED_FIFO="/tmp/mornye-station2-audio.pcm"
LED_PID_FILE="/tmp/mornye-station2-ledviz.pid"
LED_BIN="/data/local/bin/mornye-ledviz"
FB_DEVICE="/dev/fb0"
LOG_FILE="/tmp/mornye-station2-player.log"
TMP_DIR="/tmp/mornye-station2-$$"

say() { printf '%s\n' "$*"; }
err() { say "ОШИБКА: $*" >&2; exit 1; }

need_root() {
    UID_NOW=$(id -u 2>/dev/null || echo 999)
    [ "$UID_NOW" = "0" ] || err "Нужен root. Выполни su в adb shell."
}

# /etc/hosts is read-only on some Station 2 firmware builds. Do not try to
# edit it in place. Instead, create a writable shadow copy under /data/local
# and bind-mount that file over /etc/hosts for the lifetime of the request or
# playback session. The underlying firmware file is never modified.
restore_hosts() {
    [ -f "$HOSTS_MOUNT_MARKER" ] || return 0
    # A marker is created only after our bind mount succeeds. If the mount was
    # already removed (for example after a reboot), umount may fail harmlessly.
    umount "$HOSTS_FILE" >/dev/null 2>&1 || true
    rm -f "$HOSTS_MOUNT_MARKER"
    return 0
}

load_config() {
    [ -s "$CONFIG_FILE" ] || err "Не найден $CONFIG_FILE. Сначала выполни сопряжение на Windows."
    SERVER_URL=$(sed -n 's/.*"server"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n 1)
    SERVER_FP=$(sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n 1)
    SERVER_ID=$(sed -n 's/.*"serverId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n 1)
    API_KEY=$(sed -n 's/.*"apiKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n 1)
    [ -n "$SERVER_URL" ] || err "В $CONFIG_FILE отсутствует server."
    [ -n "$API_KEY" ] || err "В $CONFIG_FILE отсутствует apiKey. Повтори pairing."
    case "$SERVER_URL" in
        https://*) SERVER_AUTH=${SERVER_URL#https://} ;;
        *) err "Ожидался HTTPS URL сервера Mornye в $CONFIG_FILE." ;;
    esac
    SERVER_HOSTPORT=${SERVER_AUTH%%/*}
    SERVER_IP=${SERVER_HOSTPORT%%:*}
    SERVER_PORT=${SERVER_HOSTPORT##*:}
    case "$SERVER_IP" in *[!0-9.]*|'') err "Некорректный IPv4 адрес в $CONFIG_FILE: $SERVER_IP" ;; esac
    case "$SERVER_PORT" in *[!0-9]*|'') err "Некорректный порт в $CONFIG_FILE: $SERVER_PORT" ;; esac
    SERVER_BASE="https://$HOST_NAME:$SERVER_PORT"
}

check_dependencies() {
    [ -x "$MAIND" ] || err "Не найден $MAIND. Проверь наличие встроенного GStreamer в прошивке."
    [ -s "$CERT_FILE" ] || err "Не найден TLS-сертификат $CERT_FILE. Сначала запусти export-mornye-cert.ps1 на Windows."
    [ -r "$HOSTS_FILE" ] || err "Не удаётся прочитать $HOSTS_FILE."
    command -v mount >/dev/null 2>&1 || err "На колонке не найдена команда mount; без неё нельзя временно сопоставить mornye.local с IP."
    command -v umount >/dev/null 2>&1 || err "На колонке не найдена команда umount."
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" || err "Не удалось создать $STATE_DIR."
}

prepare_hosts() {
    need_root
    [ -r "$HOSTS_FILE" ] || err "Не удаётся прочитать $HOSTS_FILE."

    # Reuse an already active mount for an ongoing playlist.
    if [ -f "$HOSTS_MOUNT_MARKER" ] && grep -q "$HOSTS_MARKER" "$HOSTS_FILE"; then
        return 0
    fi
    # Clear stale marker/mount from a previously interrupted run.
    restore_hosts || err "Не удалось снять предыдущее временное монтирование /etc/hosts."

    say "Файловая система /etc/hosts только для чтения; создаю временное bind-монтирование..."
    awk -v h="$HOST_NAME" -v marker="$HOSTS_MARKER" '
        index($0, marker) { next }
        /^[[:space:]]*#/ { print; next }
        {
            for (i = 2; i <= NF; i++) if ($i == h) next
            print
        }
    ' "$HOSTS_FILE" > "$HOSTS_SHADOW_TMP" || err "Не удалось создать временную копию hosts."
    printf '%s\t%s %s\n' "$SERVER_IP" "$HOST_NAME" "$HOSTS_MARKER" >> "$HOSTS_SHADOW_TMP"
    chmod 600 "$HOSTS_SHADOW_TMP" 2>/dev/null || true
    mv -f "$HOSTS_SHADOW_TMP" "$HOSTS_SHADOW" || err "Не удалось сохранить временную копию $HOSTS_SHADOW."

    if ! mount -o bind "$HOSTS_SHADOW" "$HOSTS_FILE"; then
        rm -f "$HOSTS_SHADOW_TMP"
        err "Прошивка запретила bind-монтирование поверх /etc/hosts. Системный файл не изменён. Нужен другой способ DNS-разрешения mornye.local."
    fi
    if ! grep -q "$HOST_NAME" "$HOSTS_FILE"; then
        umount "$HOSTS_FILE" >/dev/null 2>&1 || true
        err "Bind-монтирование выполнено, но запись $HOST_NAME не видна через /etc/hosts."
    fi
    : > "$HOSTS_MOUNT_MARKER"
    say "Временное сопоставление $HOST_NAME -> $SERVER_IP активировано."
}

urlencode() {
    printf '%s' "$1" | od -An -v -tu1 | awk '
    {
        for (i = 1; i <= NF; i++) {
            c = $i + 0
            if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
                (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126)
                printf "%c", c
            else
                printf "%%%02X", c
        }
    }'
}

api_url() {
    METHOD=$1
    EXTRA=${2:-}
    KEY_ENC=$(urlencode "$API_KEY")
    printf '%s/rest/%s.view?apiKey=%s&v=1.16.1&c=YandexStation2&f=xml%s' \
        "$SERVER_BASE" "$METHOD" "$KEY_ENC" "$EXTRA"
}

# Use GStreamer's souphttpsrc as the HTTPS client. The server certificate is
# pinned locally as a private trust anchor; hostname validation is against
# Mornye's documented self-signed name, mornye.local.
gst_exec() {
    PIPELINE=$1
    (
        cd "$QUASAR_DIR" || exit 90
        export LD_LIBRARY_PATH="$QUASAR_DIR:$QUASAR_DIR/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export GST_PLUGIN_PATH="$QUASAR_DIR/libs${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
        ./maind --gst-launch "$PIPELINE"
    )
}

gst_fetch() {
    URL=$1
    OUT=$2
    rm -f "$OUT"
    PIPELINE="souphttpsrc location=$URL ssl-ca-file=$CERT_FILE ssl-strict=true timeout=15 ! filesink location=$OUT"
    gst_exec "$PIPELINE" > "$TMP_DIR/gst-fetch.log" 2>&1
    RC=$?
    if [ "$RC" -ne 0 ] || [ ! -s "$OUT" ]; then
        say "GStreamer не смог получить ответ Mornye. Диагностика:" >&2
        tail -n 25 "$TMP_DIR/gst-fetch.log" 2>/dev/null >&2 || true
        return 1
    fi
    return 0
}

fetch_api() {
    URL=$1
    OUT=$2
    prepare_hosts
    if ! gst_fetch "$URL" "$OUT"; then
        restore_hosts
        return 1
    fi
    restore_hosts
    return 0
}

check_api() {
    load_config
    check_dependencies
    mkdir -p "$TMP_DIR" || err "Не удалось создать временную папку."
    URL=$(api_url ping '')
    say "Проверяю OpenSubsonic: $SERVER_BASE"
    if ! fetch_api "$URL" "$TMP_DIR/ping.xml"; then
        rm -rf "$TMP_DIR"
        err "Не удалось выполнить ping. Проверь сертификат, GStreamer и доступность ПК."
    fi
    if ! grep -q 'status="ok"' "$TMP_DIR/ping.xml"; then
        cat "$TMP_DIR/ping.xml"
        rm -rf "$TMP_DIR"
        err "Mornye ответил, но авторизация OpenSubsonic не прошла."
    fi
    say "OpenSubsonic отвечает; API-ключ принят."
    rm -rf "$TMP_DIR"
}

show_songs() {
    XML_FILE=$1
    SONG_LINES=$(sed 's/></>\
</g' "$XML_FILE" | grep '<song[ >]' || true)
    [ -n "$SONG_LINES" ] || {
        say "Песни не найдены. Проверь, что библиотека опубликована в Mornye Link."
        return 1
    }
    printf '%s\n' "$SONG_LINES" | while IFS= read -r ROW; do
        ID=$(printf '%s\n' "$ROW" | sed -n 's/.* id="\([^"]*\)".*/\1/p')
        TITLE=$(printf '%s\n' "$ROW" | sed -n 's/.* title="\([^"]*\)".*/\1/p')
        ARTIST=$(printf '%s\n' "$ROW" | sed -n 's/.* artist="\([^"]*\)".*/\1/p')
        ALBUM=$(printf '%s\n' "$ROW" | sed -n 's/.* album="\([^"]*\)".*/\1/p')
        [ -n "$ID" ] || continue
        printf 'ID: %s\n    %s — %s\n    Альбом: %s\n\n' \
            "$ID" "${ARTIST:-Неизвестный исполнитель}" "${TITLE:-Без названия}" "${ALBUM:-—}"
    done
}

search_music() {
    load_config
    check_dependencies
    QUERY=${1:-}
    [ -n "$QUERY" ] || err "Укажи запрос: sh $0 search \"исполнитель или название\""
    mkdir -p "$TMP_DIR" || err "Не удалось создать временную папку."
    QENC=$(urlencode "$QUERY")
    URL=$(api_url search3 "&query=$QENC&songCount=30&albumCount=0&artistCount=0")
    say "Ищу: $QUERY"
    if ! fetch_api "$URL" "$TMP_DIR/search.xml"; then
        rm -rf "$TMP_DIR"
        err "Не удалось выполнить search3."
    fi
    if ! grep -q 'status="ok"' "$TMP_DIR/search.xml"; then
        cat "$TMP_DIR/search.xml"
        rm -rf "$TMP_DIR"
        err "Mornye вернул ошибку поиска."
    fi
    show_songs "$TMP_DIR/search.xml" || true
    rm -rf "$TMP_DIR"
}

random_music() {
    load_config
    check_dependencies
    mkdir -p "$TMP_DIR" || err "Не удалось создать временную папку."
    URL=$(api_url getRandomSongs '&size=20')
    say "Случайные композиции Mornye:"
    if ! fetch_api "$URL" "$TMP_DIR/random.xml"; then
        rm -rf "$TMP_DIR"
        err "Не удалось получить случайные композиции."
    fi
    show_songs "$TMP_DIR/random.xml" || true
    rm -rf "$TMP_DIR"
}

stream_url() {
    SID=$1
    OFFSET_MS=${2:-0}
    SID_ENC=$(urlencode "$SID")
    KEY_ENC=$(urlencode "$API_KEY")
    URL="$SERVER_BASE/rest/stream.view?id=$SID_ENC&apiKey=$KEY_ENC&v=1.16.1&c=YandexStation2"
    # OpenSubsonic Transcode Offset uses seconds. If Mornye Link advertises
    # this extension, timeOffset enables accurate restart-based seeking.
    if [ "$OFFSET_MS" -gt 0 ] 2>/dev/null; then
        OFFSET_SEC=$((OFFSET_MS / 1000))
        URL="$URL&timeOffset=$OFFSET_SEC"
    fi
    printf '%s' "$URL"
}

start_ledviz_for_track() {
    [ -f "$LED_ENABLE_FILE" ] || return 1
    [ -x "$LED_BIN" ] || {
        printf 'LED-визуализация включена, но не найден %s\n' "$LED_BIN" >> "$LOG_FILE"
        return 1
    }
    rm -f "$LED_FIFO"
    mkfifo "$LED_FIFO" || {
        printf 'Не удалось создать FIFO для LED-визуализатора\n' >> "$LOG_FILE"
        return 1
    }
    "$LED_BIN" "$LED_FIFO" >> /tmp/mornye-station2-ledviz.log 2>&1 &
    LED_PID=$!
    printf '%s\n' "$LED_PID" > "$LED_PID_FILE"
    # Give the renderer a moment to open /dev/fb0 and the FIFO. If it exited
    # (e.g. framebuffer denied), do not attach a filesink to a FIFO with no reader.
    sleep 0.2
    if ! kill -0 "$LED_PID" 2>/dev/null; then
        printf 'LED renderer завершился при запуске; продолжаю без визуализации.\n' >> "$LOG_FILE"
        rm -f "$LED_PID_FILE" "$LED_FIFO"
        return 1
    fi
    return 0
}

stop_ledviz_for_track() {
    if [ -s "$LED_PID_FILE" ]; then
        LPID=$(cat "$LED_PID_FILE" 2>/dev/null)
        case "$LPID" in *[!0-9]*|'') LPID='' ;; esac
        [ -n "$LPID" ] && kill -TERM "$LPID" 2>/dev/null || true
    fi
    rm -f "$LED_PID_FILE" "$LED_FIFO"
}

read_repeat_mode() {
    MODE=$(cat "$REPEAT_FILE" 2>/dev/null || echo none)
    case "$MODE" in one|all) printf '%s' "$MODE" ;; *) printf 'none' ;; esac
}

mark_track_restart() {
    RESTART_COUNT=$(cat "$RESTART_MARKER_FILE" 2>/dev/null || echo 0)
    case "$RESTART_COUNT" in *[!0-9]*|'') RESTART_COUNT=0 ;; esac
    RESTART_COUNT=$((RESTART_COUNT + 1))
    printf '%s\n' "$RESTART_COUNT" > "$RESTART_MARKER_FILE"
}

play_queue() {
    load_config
    check_dependencies
    OFFSET_MS=$1
    shift
    [ "$#" -gt 0 ] || err "Укажи один или несколько ID композиций."
    case "$OFFSET_MS" in *[!0-9]*|'') err "Некорректная позиция начала: $OFFSET_MS" ;; esac
    mkdir -p "$TMP_DIR" || err "Не удалось создать временную папку."
    : > "$QUEUE_FILE" || err "Не удалось записать очередь."
    for SID in "$@"; do
        case "$SID" in *[!A-Za-z0-9._:-]*|'') err "Недопустимый ID композиции: $SID" ;; esac
        printf '%s\n' "$SID" >> "$QUEUE_FILE"
    done
    chmod 600 "$QUEUE_FILE" 2>/dev/null || true

    if [ -f "$PID_FILE" ]; then stop_player; else restore_hosts; fi
    rm -f "$STOP_FILE" "$GST_PID_FILE" "$POSITION_FILE" "$SEEK_FILE" "$NEXT_FILE" "$PAUSED_FILE" "$RESTART_MARKER_FILE"
    prepare_hosts
    (
        GST_PID=""
        trap 'if [ -n "$GST_PID" ]; then kill -CONT "$GST_PID" 2>/dev/null || true; kill -TERM "$GST_PID" 2>/dev/null || true; fi; stop_ledviz_for_track; restore_hosts; rm -f "$GST_PID_FILE" "$PID_FILE" "$POSITION_FILE" "$SEEK_FILE" "$NEXT_FILE" "$PAUSED_FILE"; exit 143' INT TERM HUP
        cd "$QUASAR_DIR" || { restore_hosts; exit 90; }
        export LD_LIBRARY_PATH="$QUASAR_DIR:$QUASAR_DIR/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export GST_PLUGIN_PATH="$QUASAR_DIR/libs${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
        INITIAL_OFFSET_MS=$OFFSET_MS
        while :; do
            INDEX=0
            while IFS= read -r SID; do
                [ -n "$SID" ] || continue
                [ -f "$STOP_FILE" ] && break
                INDEX=$((INDEX + 1))
                printf '%s\n' "$INDEX" > "$POSITION_FILE"
                if [ "$INDEX" -eq 1 ]; then TRACK_OFFSET_MS=$INITIAL_OFFSET_MS; else TRACK_OFFSET_MS=0; fi
                while :; do
                    if [ -s "$SEEK_FILE" ]; then
                        TRACK_OFFSET_MS=$(cat "$SEEK_FILE" 2>/dev/null || echo 0)
                        rm -f "$SEEK_FILE"
                    fi
                    SONG_URL=$(stream_url "$SID" "$TRACK_OFFSET_MS")
                    VOLUME_PCT=$(cat "$VOLUME_FILE" 2>/dev/null || echo 100)
                    case "$VOLUME_PCT" in *[!0-9]*|'') VOLUME_PCT=100 ;; esac
                    [ "$VOLUME_PCT" -gt 100 ] && VOLUME_PCT=100
                    VOL=$(awk -v n="$VOLUME_PCT" 'BEGIN { printf "%.3f", n/100 }')
                    start_ledviz_for_track || true
                    if [ -s "$LED_PID_FILE" ] && [ -p "$LED_FIFO" ] && kill -0 "$(cat "$LED_PID_FILE" 2>/dev/null)" 2>/dev/null; then
                        if command -v amixer >/dev/null 2>&1; then
                            GST_PIPELINE="souphttpsrc location=$SONG_URL ssl-ca-file=$CERT_FILE ssl-strict=true timeout=30 ! queue ! decodebin ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,channels=2,rate=48000 ! tee name=t t. ! queue ! alsasink t. ! queue ! filesink location=$LED_FIFO sync=false"
                        else
                            GST_PIPELINE="souphttpsrc location=$SONG_URL ssl-ca-file=$CERT_FILE ssl-strict=true timeout=30 ! queue ! decodebin ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,channels=2,rate=48000 ! tee name=t t. ! queue ! volume volume=$VOL ! alsasink t. ! queue ! filesink location=$LED_FIFO sync=false"
                        fi
                    else
                        if command -v amixer >/dev/null 2>&1; then
                            GST_PIPELINE="souphttpsrc location=$SONG_URL ssl-ca-file=$CERT_FILE ssl-strict=true timeout=30 ! queue ! decodebin ! audioconvert ! audioresample ! alsasink"
                        else
                            GST_PIPELINE="souphttpsrc location=$SONG_URL ssl-ca-file=$CERT_FILE ssl-strict=true timeout=30 ! queue ! decodebin ! audioconvert ! audioresample ! volume volume=$VOL ! alsasink"
                        fi
                    fi
                    printf 'Воспроизведение ID=%s offset=%s ms volume=%s%%\n' "$SID" "$TRACK_OFFSET_MS" "$VOLUME_PCT" >> "$LOG_FILE"
                    ./maind --gst-launch "$GST_PIPELINE" >> "$LOG_FILE" 2>&1 &
                    GST_PID=$!
                    printf '%s\n' "$GST_PID" > "$GST_PID_FILE"
                    sleep 0.15
                    if [ -f "$PAUSED_FILE" ]; then kill -STOP "$GST_PID" 2>/dev/null || true; fi
                    wait "$GST_PID"
                    GST_RC=$?
                    rm -f "$GST_PID_FILE"
                    GST_PID=""
                    stop_ledviz_for_track
                    [ -f "$STOP_FILE" ] && break
                    if [ -s "$SEEK_FILE" ]; then
                        TRACK_OFFSET_MS=$(cat "$SEEK_FILE" 2>/dev/null || echo 0)
                        rm -f "$SEEK_FILE"
                        continue
                    fi
                    if [ -f "$NEXT_FILE" ]; then
                        rm -f "$NEXT_FILE"
                        break
                    fi
                    REPEAT_MODE=$(read_repeat_mode)
                    if [ "$REPEAT_MODE" = "one" ] && [ "$GST_RC" -eq 0 ]; then
                        mark_track_restart
                        TRACK_OFFSET_MS=0
                        continue
                    fi
                    if [ "$GST_RC" -ne 0 ]; then
                        printf 'Ошибка воспроизведения ID=%s, код=%s\n' "$SID" "$GST_RC" >> "$LOG_FILE"
                    fi
                    break
                done
                [ -f "$STOP_FILE" ] && break
            done < "$QUEUE_FILE"
            [ -f "$STOP_FILE" ] && break
            [ "$(read_repeat_mode)" = "all" ] || break
            mark_track_restart
            INITIAL_OFFSET_MS=0
        done
        stop_ledviz_for_track
        restore_hosts
        rm -f "$GST_PID_FILE" "$PID_FILE" "$POSITION_FILE" "$STOP_FILE" "$SEEK_FILE" "$NEXT_FILE" "$PAUSED_FILE"
    ) > "$LOG_FILE" 2>&1 </dev/null &
    WRAPPER_PID=$!
    printf '%s\n' "$WRAPPER_PID" > "$PID_FILE"
    sleep 2
    if kill -0 "$WRAPPER_PID" 2>/dev/null; then
        say "Очередь запущена ($# композ.). PID=$WRAPPER_PID"
        say "Пауза: sh $0 pause | Продолжить: sh $0 resume | Следующая: sh $0 next | Стоп: sh $0 stop"
        say "Журнал: $LOG_FILE"
    else
        restore_hosts
        rm -f "$PID_FILE"
        tail -n 30 "$LOG_FILE" 2>/dev/null || true
        err "GStreamer не запустился."
    fi
}

current_gst_pid() {
    [ -s "$GST_PID_FILE" ] || return 1
    P=$(cat "$GST_PID_FILE" 2>/dev/null)
    case "$P" in *[!0-9]*|'') return 1 ;; esac
    kill -0 "$P" 2>/dev/null || return 1
    printf '%s' "$P"
}

pause_player() {
    P=$(current_gst_pid) || err "Сейчас нет активного трека."
    kill -STOP "$P" || err "Не удалось поставить воспроизведение на паузу."
    : > "$PAUSED_FILE"
    say "Пауза."
}

resume_player() {
    P=$(current_gst_pid) || err "Сейчас нет активного трека."
    kill -CONT "$P" || err "Не удалось продолжить воспроизведение."
    rm -f "$PAUSED_FILE"
    say "Воспроизведение продолжено."
}

next_track() {
    P=$(current_gst_pid) || err "Сейчас нет активного трека или очередь завершилась."
    rm -f "$PAUSED_FILE"
    : > "$NEXT_FILE"
    kill -CONT "$P" 2>/dev/null || true
    kill -TERM "$P" || err "Не удалось переключить композицию."
    say "Переключаю на следующую композицию..."
}

seek_player() {
    OFFSET_MS=$1
    case "$OFFSET_MS" in *[!0-9]*|'') err "Позиция должна быть в миллисекундах." ;; esac
    [ -s "$PID_FILE" ] || err "Плеер не запущен."
    P=$(current_gst_pid) || err "Сейчас нет активного трека."
    printf '%s\n' "$OFFSET_MS" > "$SEEK_FILE"
    kill -CONT "$P" 2>/dev/null || true
    kill -TERM "$P" || err "Не удалось перезапустить поток для перемотки."
    say "Перемотка на $OFFSET_MS ms. Требуется поддержка OpenSubsonic Transcode Offset сервером."
}

set_volume() {
    PCT=$1
    OFFSET_MS=${2:-0}
    case "$PCT" in *[!0-9]*|'') err "Громкость задаётся числом 0–100." ;; esac
    case "$OFFSET_MS" in *[!0-9]*|'') OFFSET_MS=0 ;; esac
    [ "$PCT" -le 100 ] || PCT=100
    [ "$PCT" -ge 0 ] || PCT=0
    printf '%s\n' "$PCT" > "$VOLUME_FILE"
    if command -v amixer >/dev/null 2>&1; then
        if amixer set Master "${PCT}%" >/dev/null 2>&1 || amixer -c 0 set Master "${PCT}%" >/dev/null 2>&1; then
            say "Громкость установлена через ALSA: ${PCT}%."
            return 0
        fi
        printf 'amixer найден, но Master не изменён; использую GStreamer volume.\n' >> "$LOG_FILE"
    fi
    # No working amixer on some retail builds: the GStreamer volume element is used.
    # Restart only the current stream at its current offset so the change is
    # immediate and does not wait for the next song.
    printf '%s\n' "$OFFSET_MS" > "$SEEK_FILE"
    if P=$(current_gst_pid 2>/dev/null); then
        kill -CONT "$P" 2>/dev/null || true
        kill -TERM "$P" 2>/dev/null || err "Не удалось применить громкость: текущий GStreamer-процесс не остановился."
        say "Громкость ${PCT}% сохранена; поток перезапускается с позиции ${OFFSET_MS} ms."
    else
        say "Громкость ${PCT}% сохранена и применится при следующем запуске трека."
    fi
}

set_repeat() {
    MODE=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$MODE" in none|off|0) MODE=none ;; one|track|1) MODE=one ;; all|queue|2) MODE=all ;; *) err "Режим повтора: none, one или all." ;; esac
    printf '%s\n' "$MODE" > "$REPEAT_FILE"
    say "Повтор: $MODE."
}

set_shuffle() {
    VALUE=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$VALUE" in 1|true|on|yes) VALUE=on ;; 0|false|off|no) VALUE=off ;; *) err "Shuffle задаётся как on/off." ;; esac
    printf '%s\n' "$VALUE" > "$STATE_DIR/mornye-station2-shuffle"
    say "Shuffle: $VALUE. Перемешивание текущей очереди выполняет WebSocket-клиент при получении команды."
}

ledviz_control() {
    ACTION=${1:-status}
    case "$ACTION" in
        on)
            [ -x "$LED_BIN" ] || err "Не найден $LED_BIN. Передай бинарник mornye-ledviz на колонку."
            : > "$LED_ENABLE_FILE"
            say "LED-визуализация включена; применится при следующем запуске или переключении композиции."
            ;;
        off)
            rm -f "$LED_ENABLE_FILE"
            if [ -s "$LED_PID_FILE" ]; then LPID=$(cat "$LED_PID_FILE" 2>/dev/null); kill -TERM "$LPID" 2>/dev/null || true; fi
            rm -f "$LED_FIFO" "$LED_PID_FILE"
            if [ -w "$FB_DEVICE" ]; then dd if=/dev/zero of="$FB_DEVICE" bs=356 count=1 2>/dev/null || true; fi
            say "LED-визуализация выключена."
            ;;
        status)
            if [ -f "$LED_ENABLE_FILE" ]; then say "LED-визуализация: включена"; else say "LED-визуализация: выключена"; fi
            [ -c "$FB_DEVICE" ] && say "Framebuffer: $FB_DEVICE доступен" || say "Framebuffer: $FB_DEVICE не найден"
            [ -x "$LED_BIN" ] && say "LED renderer: установлен" || say "LED renderer: не установлен"
            ;;
        test)
            [ -x "$LED_BIN" ] || err "Не найден $LED_BIN."
            "$LED_BIN" --test
            ;;
        *) err "Использование: ledviz on|off|status|test" ;;
    esac
}

stop_player() {
    [ -f "$PID_FILE" ] || {
        restore_hosts
        say "Плеер не запущен."
        return 0
    }
    WRAPPER_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    case "$WRAPPER_PID" in *[!0-9]*|'') WRAPPER_PID="" ;; esac
    : > "$STOP_FILE"
    P=$(current_gst_pid 2>/dev/null || true)
    if [ -n "$P" ]; then kill -CONT "$P" 2>/dev/null || true; kill -TERM "$P" 2>/dev/null || true; fi
    if [ -n "$WRAPPER_PID" ]; then kill -TERM "$WRAPPER_PID" 2>/dev/null || true; fi
    if [ -s "$LED_PID_FILE" ]; then LPID=$(cat "$LED_PID_FILE" 2>/dev/null); kill -TERM "$LPID" 2>/dev/null || true; fi
    sleep 1
    restore_hosts
    rm -f "$PID_FILE" "$GST_PID_FILE" "$POSITION_FILE" "$STOP_FILE" "$SEEK_FILE" "$NEXT_FILE" "$PAUSED_FILE" "$LED_PID_FILE" "$LED_FIFO"
    say "Воспроизведение остановлено."
}

show_extensions() {
    load_config
    check_dependencies
    mkdir -p "$TMP_DIR" || err "Не удалось создать временную папку."
    URL=$(api_url getOpenSubsonicExtensions '')
    say "Проверяю расширения OpenSubsonic..."
    if ! fetch_api "$URL" "$TMP_DIR/extensions.xml"; then rm -rf "$TMP_DIR"; err "Не удалось получить список расширений."; fi
    cat "$TMP_DIR/extensions.xml"
    if grep -q 'name="transcodeOffset"' "$TMP_DIR/extensions.xml"; then
        say "Поддержка seek через timeOffset: ЕСТЬ"
    else
        say "Поддержка seek через timeOffset: не объявлена; перемотка может не сработать на этом сервере."
    fi
    rm -rf "$TMP_DIR"
}

status() {
    load_config
    say "Сервер: $SERVER_URL"
    say "Имя TLS: $HOST_NAME"
    say "Fingerprint из pairing: $SERVER_FP"
    say "Конфигурация: $CONFIG_FILE"
    if [ -s "$CERT_FILE" ]; then say "TLS-сертификат: установлен"; else say "TLS-сертификат: отсутствует (нужен export-mornye-cert.ps1)"; fi
    if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        say "Плеер: запущен (PID $(cat "$PID_FILE"))"
        if P=$(current_gst_pid 2>/dev/null); then say "GStreamer: активен (PID $P)"; fi
        if [ -s "$POSITION_FILE" ]; then say "Позиция в очереди: $(cat "$POSITION_FILE")"; fi
    else
        say "Плеер: остановлен"
    fi
}

check_environment() {
    say "Проверка Mornye-клиента на Яндекс Станции 2"
    say "Архитектура: $(uname -m 2>/dev/null || echo неизвестно)"
    say "UID: $(id -u 2>/dev/null || echo неизвестно)"
    [ -s "$CONFIG_FILE" ] && say "  pairing JSON: найден" || say "  pairing JSON: отсутствует"
    [ -s "$CERT_FILE" ] && say "  TLS сертификат: найден" || say "  TLS сертификат: отсутствует"
    [ -x "$MAIND" ] && say "  maind: $MAIND" || say "  maind: не найден"
    [ -w "$HOSTS_FILE" ] && say "  /etc/hosts: доступен для записи" || say "  /etc/hosts: read-only; будет использована временная bind-копия"
    command -v mount >/dev/null 2>&1 && say "  mount: найден" || say "  mount: не найден"
    command -v umount >/dev/null 2>&1 && say "  umount: найден" || say "  umount: не найден"
    if command -v gst-inspect-1.0 >/dev/null 2>&1; then
        gst-inspect-1.0 souphttpsrc >/dev/null 2>&1 && say "  souphttpsrc: найден" || say "  souphttpsrc: не найден gst-inspect не смог его открыть"
    else
        say "  gst-inspect-1.0: не найден; проверка souphttpsrc будет выполнена при ping"
    fi
    [ -x "$LED_BIN" ] && say "  LED renderer: установлен" || say "  LED renderer: не установлен"
    [ -c "$FB_DEVICE" ] && say "  LED framebuffer: $FB_DEVICE найден" || say "  LED framebuffer: не найден"
    say "Для сетевых запросов используются GStreamer souphttpsrc и сохранённый сертификат. curl/openssl на колонке не требуются."
}

usage() {
    cat <<USAGE
Mornye Link — Яндекс Станция 2

Сначала на Windows выполни export-mornye-cert.ps1, затем:
  sh $0 check
  sh $0 status
  sh $0 ping
  sh $0 search "Daft Punk"
  sh $0 random
  sh $0 play SONG_ID [SONG_ID ...]
  sh $0 pause
  sh $0 resume
  sh $0 next
  sh $0 seek POSITION_MS
  sh $0 volume 0..100 [POSITION_MS]
  sh $0 repeat none|one|all
  sh $0 shuffle on|off
  sh $0 extensions
  sh $0 ledviz on|off|status|test
  sh $0 stop

Несколько ID после play образуют последовательную очередь.
Конфигурация: $CONFIG_FILE
Сертификат:   $CERT_FILE
Журнал:       $LOG_FILE
USAGE
}

# Recover a stale temporary bind mount after a previous interrupted run.
if [ -f "$HOSTS_MOUNT_MARKER" ] && [ ! -f "$PID_FILE" ]; then restore_hosts; fi

COMMAND=${1:-help}
shift 2>/dev/null || true
case "$COMMAND" in
    check) check_environment ;;
    status) status ;;
    ping) check_api ;;
    search) search_music "${1:-}" ;;
    random) random_music ;;
    play) play_queue 0 "$@" ;;
    playfrom) OFFSET=${1:-0}; shift 2>/dev/null || true; play_queue "$OFFSET" "$@" ;;
    pause) pause_player ;;
    resume) resume_player ;;
    next) next_track ;;
    seek) seek_player "${1:-}" ;;
    volume) set_volume "${1:-}" ;;
    repeat) set_repeat "${1:-}" ;;
    shuffle) set_shuffle "${1:-}" ;;
    extensions) show_extensions ;;
    ledviz) ledviz_control "${1:-status}" ;;
    stop) stop_player ;;
    help|-h|--help) usage ;;
    *) usage; err "Неизвестная команда: $COMMAND" ;;
esac
