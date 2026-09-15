"""Tests für den Poll-Lifecycle inkl. Stale-Re-Dispatch.

Hintergrund (Incident 15.09.): USDCAD-Signal blieb als DISPATCHED ohne Ack in
der Queue hängen (Poll-Response kam beim EA nie an) und wurde nie ausgeführt.
Der Gateway re-dispatcht solche verwaisten Signale jetzt automatisch.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import main

TOKEN = "test-token-12345678"
HEADERS = {"X-API-KEY": TOKEN}
PAYLOAD = {
    "action": "BUY",
    "symbol": "USDCAD",
    "price": 1.39014,
    "sl": 1.38966,
    "tp1": 1.39085,
    "tp2": 1.39133,
    "qty_pct": 100,
}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    """Isolierte Test-Instanz: eigener DATA_DIR, eigener Token, echte App."""
    monkeypatch.setattr(main, "SIGNALS_FILE", tmp_path / "signals.json")
    monkeypatch.setattr(main, "HISTORY_FILE", tmp_path / "signals_history.json")
    # Lifespan überschreibt ALLOWED_TOKENS aus tokens.json -> Quelle mocken
    monkeypatch.setattr(main, "_load_tokens", lambda: {TOKEN: "test"})
    with TestClient(main.app) as c:
        yield c


def _post_signal(client) -> str:
    resp = client.post("/v1/webhook", params={"token": TOKEN}, json=PAYLOAD)
    assert resp.status_code == 201
    return resp.json()["signal_id"]


def _store() -> dict:
    return json.loads(main.SIGNALS_FILE.read_text(encoding="utf-8"))


def _save_store(store: dict) -> None:
    main.SIGNALS_FILE.write_text(json.dumps(store), encoding="utf-8")


def _age_signal(signal_id: str, minutes: float = 10.0) -> None:
    """dispatched_at künstlich altern (ohne den Stale-Zyklus warten zu müssen)."""
    store = _store()
    sig = store["tokens"][TOKEN]["signals"][0]
    assert sig["signal_id"] == signal_id
    past = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat(
        timespec="seconds"
    )
    sig["dispatched_at"] = past
    _save_store(store)


def test_poll_flow_and_ack(client):
    """Regelfall: Webhook -> Poll (attempts=1) -> leerer Poll -> Ack -> Archiv."""
    signal_id = _post_signal(client)

    body = client.get("/v1/signals/poll", headers=HEADERS).json()
    assert body[0]["signal_id"] == signal_id
    assert body[0]["status"] == "DISPATCHED"
    assert body[0]["attempts"] == 1

    # zweiter Poll: Queue leer, kein Re-Dispatch
    assert client.get("/v1/signals/poll", headers=HEADERS).json() == []

    # Ack -> EXECUTED, aus der Queue archiviert
    r = client.post(
        f"/v1/signals/{signal_id}/ack",
        headers=HEADERS,
        json={"success": True, "error_message": ""},
    )
    assert r.status_code == 200
    history = json.loads(main.HISTORY_FILE.read_text(encoding="utf-8"))
    assert history["signals"][0]["status"] == "EXECUTED"
    assert _store()["tokens"][TOKEN]["signals"] == []


def test_stale_dispatch_requeues(client, monkeypatch):
    """DISPATCHED ohne Ack > Stale-Schwelle -> beim nächsten Poll erneut liefern."""
    monkeypatch.setattr(main, "STALE_DISPATCH_SECONDS", 90)
    signal_id = _post_signal(client)

    client.get("/v1/signals/poll", headers=HEADERS)
    _age_signal(signal_id, minutes=10)

    body = client.get("/v1/signals/poll", headers=HEADERS).json()
    assert body[0]["signal_id"] == signal_id  # Re-Dispatch desselben Signals
    assert body[0]["status"] == "DISPATCHED"
    assert body[0]["attempts"] == 2


def test_stale_dispatch_fails_after_max_attempts(client, monkeypatch):
    """Nach MAX_DISPATCH_ATTEMPTS vergeblichen Versuchen -> FAILED + Archiv."""
    monkeypatch.setattr(main, "STALE_DISPATCH_SECONDS", 90)
    monkeypatch.setattr(main, "MAX_DISPATCH_ATTEMPTS", 1)
    signal_id = _post_signal(client)

    client.get("/v1/signals/poll", headers=HEADERS)
    _age_signal(signal_id, minutes=10)

    assert client.get("/v1/signals/poll", headers=HEADERS).json() == []
    history = json.loads(main.HISTORY_FILE.read_text(encoding="utf-8"))
    sig = history["signals"][0]
    assert sig["status"] == "FAILED"
    assert "stale dispatch" in sig["result"]["error_message"]
    # Queue ist wieder frei (kein Head-of-Line-Blocking)
    assert _store()["tokens"][TOKEN]["signals"] == []


def test_fresh_dispatch_not_requeued(client):
    """Frisch DISPATCHED-Signal bleibt in der Zustellung (kein vorzeitiger Requeue)."""
    _post_signal(client)
    client.get("/v1/signals/poll", headers=HEADERS)
    assert client.get("/v1/signals/poll", headers=HEADERS).json() == []


def test_broken_dispatched_at_not_requeued(client):
    """Korruptes dispatched_at -> kein Re-Dispatch, Signal bleibt erhalten."""
    signal_id = _post_signal(client)
    client.get("/v1/signals/poll", headers=HEADERS)

    store = _store()
    store["tokens"][TOKEN]["signals"][0]["dispatched_at"] = "not-a-date"
    _save_store(store)

    assert client.get("/v1/signals/poll", headers=HEADERS).json() == []
    assert _store()["tokens"][TOKEN]["signals"][0]["signal_id"] == signal_id
