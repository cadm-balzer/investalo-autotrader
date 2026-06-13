#!/bin/sh
# Investalo Autotrader entrypoint
# - korrigiert Rechte am Daten-Volume (Bind-Mount kommt als root vom Host)
# - dropt anschließend Privilegien auf den 'app'-User
set -eu

DATA_DIR="${DATA_DIR:-/app/data}"

echo "[entrypoint] uid=$(id -u) gid=$(id -g) DATA_DIR=$DATA_DIR"

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$DATA_DIR"
    chown -R app:app "$DATA_DIR"
    chmod -R u+rwX,g+rwX "$DATA_DIR"
    echo "[entrypoint] fixed ownership -> $(ls -ld "$DATA_DIR")"
    echo "[entrypoint] dropping privileges to 'app'"
    exec gosu app "$@"
fi

echo "[entrypoint] running as non-root, no chown"
exec "$@"
