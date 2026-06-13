#!/bin/sh
# Investalo Autotrader entrypoint
# - korrigiert Rechte am Daten-Volume (Bind-Mount kommt als root vom Host)
# - dropt anschließend Privilegien auf den 'app'-User
set -eu

DATA_DIR="${DATA_DIR:-/app/data}"

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$DATA_DIR"
    chown -R app:app "$DATA_DIR"
    exec gosu app "$@"
fi

exec "$@"
