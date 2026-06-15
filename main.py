"""
Investalo Autotrader – Signal Gateway
=====================================
Webhook-zu-Polling-Bridge zwischen TradingView (POST) und MetaTrader 5 EA (GET/POST).

Datenhaltung: lokale JSON-Datei (asyncio-Lock geschützt). Mandantenfähig über
API-Token (UUID), keine FTMO-Kontonummer im Klartext.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.getenv("DATA_DIR", BASE_DIR / "data"))
SIGNALS_FILE = DATA_DIR / "signals.json"
HISTORY_FILE = DATA_DIR / "signals_history.json"
TOKENS_FILE = Path(os.getenv("TOKENS_FILE", BASE_DIR / "tokens.json"))

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("autotrader")

# uvicorn bringt eigene Handler ohne Timestamp mit -> wir vereinheitlichen
# alles auf das Root-Format (asctime im Prefix).
for _name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
    _lg = logging.getLogger(_name)
    _lg.handlers.clear()
    _lg.propagate = True

ActionT = Literal[
    "BUY",
    "SELL",
    "BUY_LIMIT",
    "SELL_LIMIT",
    "PARTIAL_CLOSE",
    "CLOSE_ALL",
    "BREAKEVEN",
]
StatusT = Literal["PENDING", "DISPATCHED", "EXECUTED", "FAILED"]

# ---------------------------------------------------------------------------
# Pydantic-Modelle
# ---------------------------------------------------------------------------
class WebhookPayload(BaseModel):
    """TradingView-Signal-Payload (strikt validiert)."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    action: ActionT
    symbol: str = Field(..., min_length=3, max_length=12)
    price: float = Field(..., gt=0)
    sl: float | None = Field(default=None, gt=0)
    tp1: float | None = Field(default=None, gt=0)
    tp2: float | None = Field(default=None, gt=0)
    qty_pct: int = Field(default=100, ge=1, le=100)
    breakeven: bool = False  # SL nach Teilschließung auf Breakeven ziehen (PARTIAL_CLOSE)

    @field_validator("symbol")
    @classmethod
    def _upper_symbol(cls, v: str) -> str:
        v = v.upper()
        if not v.isalnum():
            raise ValueError("symbol must be alphanumeric")
        return v


class AckPayload(BaseModel):
    """Quittung des MT5 EA nach Ausführung (oder Fehler)."""

    model_config = ConfigDict(extra="ignore")

    success: bool
    error_message: str | None = Field(default=None, max_length=512)

    @field_validator("error_message", mode="before")
    @classmethod
    def _empty_to_none(cls, v: Any) -> Any:
        if isinstance(v, str) and v.strip() == "":
            return None
        return v


class StoredSignal(BaseModel):
    """Persistiertes Signal inkl. Lifecycle-Metadaten."""

    signal_id: str
    token: str
    status: StatusT
    created_at: str
    dispatched_at: str | None = None
    acked_at: str | None = None
    payload: WebhookPayload
    result: AckPayload | None = None


# ---------------------------------------------------------------------------
# Token-Management
# ---------------------------------------------------------------------------
def _load_tokens() -> dict[str, str]:
    """tokens.json laden -> dict {token: label}. Fehlerhaft = leer + Warnung."""
    if not TOKENS_FILE.exists():
        log.warning("tokens file %s not found – no tokens loaded", TOKENS_FILE)
        return {}
    try:
        raw = json.loads(TOKENS_FILE.read_text(encoding="utf-8"))
        return {entry["token"]: entry.get("label", "") for entry in raw.get("tokens", [])}
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        log.error("invalid tokens file: %s", exc)
        return {}


ALLOWED_TOKENS: dict[str, str] = {}


def _require_token(token: str | None) -> str:
    if not token or token not in ALLOWED_TOKENS:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid token")
    return token


async def auth_query(token: str = Query(..., min_length=8, description="API-Token")) -> str:
    """Auth via Query-Parameter (TradingView-Webhooks können keine Header senden)."""
    return _require_token(token)


async def auth_header(x_api_key: str | None = Header(default=None, alias="X-API-KEY")) -> str:
    """Auth via Header (MT5 EA)."""
    return _require_token(x_api_key)


# ---------------------------------------------------------------------------
# Persistenz – asyncio.Lock-geschützt, Atomic Write
# ---------------------------------------------------------------------------
_file_lock = asyncio.Lock()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _empty_store() -> dict[str, Any]:
    return {"_meta": {"created_at": _now_iso()}, "tokens": {}}


def _read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        log.exception("corrupt json at %s – falling back to default", path)
        return default


def _atomic_write(path: Path, data: Any) -> None:
    """Atomic write: erst tmp-Datei, dann os.replace -> kein Halbzustand bei Crash."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


async def _load_store() -> dict[str, Any]:
    return _read_json(SIGNALS_FILE, _empty_store())


async def _save_store(store: dict[str, Any]) -> None:
    _atomic_write(SIGNALS_FILE, store)


async def _archive(signal: dict[str, Any]) -> None:
    """EXECUTED/FAILED-Signale in separate History-Datei umziehen."""
    history = _read_json(HISTORY_FILE, {"signals": []})
    history["signals"].append(signal)
    _atomic_write(HISTORY_FILE, history)


# ---------------------------------------------------------------------------
# App-Lifecycle
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(_: FastAPI):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not SIGNALS_FILE.exists():
        _atomic_write(SIGNALS_FILE, _empty_store())
    global ALLOWED_TOKENS
    ALLOWED_TOKENS = _load_tokens()
    log.info("startup: %d token(s) loaded, store=%s", len(ALLOWED_TOKENS), SIGNALS_FILE)
    yield
    log.info("shutdown")


app = FastAPI(
    title="Investalo Autotrader Signal Gateway",
    version="1.0.0",
    description="TradingView -> JSON-Queue -> MT5 EA Polling",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Endpunkte
# ---------------------------------------------------------------------------
@app.get("/health", tags=["meta"])
async def health() -> dict[str, str]:
    """Liveness-Probe."""
    return {"status": "ok", "time": _now_iso()}


@app.post("/v1/webhook", status_code=status.HTTP_201_CREATED, tags=["signals"])
async def webhook(payload: WebhookPayload, token: str = Depends(auth_query)) -> dict[str, str]:
    """TradingView -> Signal in JSON-Queue ablegen (Status PENDING)."""
    signal = StoredSignal(
        signal_id=str(uuid.uuid4()),
        token=token,
        status="PENDING",
        created_at=_now_iso(),
        payload=payload,
    )
    async with _file_lock:
        store = await _load_store()
        bucket = store["tokens"].setdefault(token, {"signals": []})
        bucket["signals"].append(signal.model_dump(mode="json"))
        await _save_store(store)

    log.info("webhook %s/%s %s %s @%s", token[:8], signal.signal_id, payload.action, payload.symbol, payload.price)
    return {"signal_id": signal.signal_id, "status": signal.status}


@app.get("/v1/signals/poll", tags=["signals"])
async def poll(token: str = Depends(auth_header)) -> list[dict[str, Any]]:
    """MT5 EA -> nächstes PENDING-Signal holen (FIFO) und auf DISPATCHED setzen."""
    async with _file_lock:
        store = await _load_store()
        bucket = store["tokens"].get(token, {"signals": []})
        for sig in bucket["signals"]:
            if sig["status"] == "PENDING":
                sig["status"] = "DISPATCHED"
                sig["dispatched_at"] = _now_iso()
                await _save_store(store)
                log.info("dispatch %s/%s -> MT5", token[:8], sig["signal_id"])
                return [sig]
    return []


@app.post("/v1/signals/{signal_id}/ack", tags=["signals"])
async def ack(
    signal_id: str,
    body: AckPayload,
    token: str = Depends(auth_header),
) -> dict[str, str]:
    """MT5 EA -> Ausführung quittieren (EXECUTED/FAILED) und in History archivieren."""
    final: StatusT = "EXECUTED" if body.success else "FAILED"

    async with _file_lock:
        store = await _load_store()
        bucket = store["tokens"].get(token, {"signals": []})
        target = next((s for s in bucket["signals"] if s["signal_id"] == signal_id), None)
        if target is None:
            raise HTTPException(status_code=404, detail="signal not found")

        target["status"] = final
        target["acked_at"] = _now_iso()
        target["result"] = body.model_dump()

        bucket["signals"] = [s for s in bucket["signals"] if s["signal_id"] != signal_id]
        await _save_store(store)
        await _archive(target)

    log.info("ack %s/%s -> %s", token[:8], signal_id, final)
    return {"signal_id": signal_id, "status": final}


# ---------------------------------------------------------------------------
# Globaler Exception-Handler – nie Stacktrace an Clients
# ---------------------------------------------------------------------------
@app.exception_handler(RequestValidationError)
async def _validation(request: Request, exc: RequestValidationError) -> JSONResponse:
    """422-Antworten mit Body-Echo loggen – hilft beim Debuggen von MT5/TV-Payloads."""
    raw = await request.body()
    log.warning(
        "422 %s %s | body=%r | errors=%s",
        request.method,
        request.url.path,
        raw[:1000],
        exc.errors(),
    )
    return JSONResponse(status_code=422, content={"detail": exc.errors()})


@app.exception_handler(Exception)
async def _unhandled(_: Request, exc: Exception) -> JSONResponse:
    log.exception("unhandled: %s", exc)
    return JSONResponse(status_code=500, content={"detail": "internal error"})
