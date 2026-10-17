#!/bin/sh
LOG=/opt/var/log/router_bot.log
GIVEUP=/var/run/routerbot.giveup
MAX_FAILS=10
FAILS=0

# Если маркер есть — не запускаться
if [ -f "$GIVEUP" ]; then
    echo "$(date '+%F %T') wrapper: giveup marker present, exit" >> "$LOG"
    exit 0
fi

# Ждём DNS готовности
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    if /opt/bin/python3 -c "import socket; socket.gethostbyname('api.telegram.org')" >/dev/null 2>&1; then
        echo "$(date '+%F %T') wrapper: DNS OK" >> "$LOG"
        break
    fi
    sleep 5
done

while true; do
    if [ -f "$GIVEUP" ]; then
        echo "$(date '+%F %T') wrapper: giveup marker detected, stopping" >> "$LOG"
        exit 0
    fi

    echo "$(date '+%F %T') wrapper: Starting bot..." >> "$LOG"
    T0=$(date +%s)
    /opt/bin/python3 /opt/router_bot/main.py >> "$LOG" 2>&1
    T1=$(date +%s)
    RUNTIME=$((T1 - T0))

    if [ "$RUNTIME" -lt 60 ]; then
        FAILS=$((FAILS + 1))
        echo "$(date '+%F %T') wrapper: Bot died after ${RUNTIME}s (fail $FAILS/$MAX_FAILS)" >> "$LOG"
        if [ "$FAILS" -ge "$MAX_FAILS" ]; then
            echo "$(date '+%F %T') wrapper: GIVE UP after $FAILS quick failures" >> "$LOG"
            echo "$(date '+%F %T') wrapper: Marker: $GIVEUP" >> "$LOG"
            echo "$(date '+%F %T') wrapper: To reset: rm $GIVEUP && /opt/etc/init.d/S98routerbot restart" >> "$LOG"
            touch "$GIVEUP"
            exit 1
        fi
    else
        if [ "$FAILS" -gt 0 ]; then
            echo "$(date '+%F %T') wrapper: Bot ran ${RUNTIME}s, counter reset (was $FAILS)" >> "$LOG"
        fi
        FAILS=0
        echo "$(date '+%F %T') wrapper: Bot died after ${RUNTIME}s, restart in 10s" >> "$LOG"
    fi
    sleep 10
done