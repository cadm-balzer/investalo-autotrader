# Investalo Autotrader – Signal Gateway

Schlankes FastAPI-Gateway: TradingView-Webhooks → JSON-Queue → MT5 EA Polling.
Mandantenfähig per API-Token, kein DB-Setup, asyncio-Lock + atomic write gegen Race Conditions.

## Endpunkte

| Methode | Pfad                              | Auth                | Zweck                                  |
| ------- | --------------------------------- | ------------------- | -------------------------------------- |
| POST    | `/v1/webhook?token=…`             | Query `token`       | TradingView legt Signal `PENDING` ab   |
| GET     | `/v1/signals/poll`                | Header `X-API-KEY`  | MT5 holt nächstes Signal → `DISPATCHED`|
| POST    | `/v1/signals/{signal_id}/ack`     | Header `X-API-KEY`  | MT5 quittiert → `EXECUTED` / `FAILED`  |
| GET     | `/health`                         | –                   | Liveness                               |

OpenAPI/Swagger UI: `http://<host>:3005/docs`

## Payloads

**Webhook (TradingView):**
```json
{ "action": "BUY", "symbol": "EURUSD", "price": 1.0875,
  "sl": 1.0850, "tp1": 1.0900, "tp2": 1.0925, "qty_pct": 100 }
```
`action` ∈ `BUY | SELL | PARTIAL_CLOSE | CLOSE_ALL | BREAKEVEN`

**Ack (MT5):**
```json
{ "success": true, "error_message": null }
```

## Setup

```bash
# Token vergeben
$EDITOR tokens.json   # demo-token-please-change-me ersetzen (uuidgen)

# Lokal
pip install -r requirements.txt
uvicorn main:app --reload

# Docker
docker compose up -d --build
docker compose logs -f
```

## Datenhaltung

- `./data/signals.json` – aktive Queue (Bind-Mount, host-sichtbar)
- `./data/signals_history.json` – archivierte EXECUTED/FAILED-Signale
- Schreibzugriffe: `asyncio.Lock` + `os.replace` (atomic)

## Sicherheit

- Tokens in `tokens.json` (read-only ins Image gemountet); Rotation = Datei tauschen + Container neu starten.
- Unautorisierte Anfragen → `401 Unauthorized`.
- FTMO-Kontonummer wird **nie** übertragen; Mapping Token ↔ Konto erfolgt ausschließlich im EA.
- HTTPS via vorgeschaltetem Reverse-Proxy (Caddy/Traefik/nginx) ergänzen.

## TradingView-Alert-URL

```
https://<host>/v1/webhook?token=<API_TOKEN>
```
JSON-Body wie oben in das Alert-„Message“-Feld einsetzen.

## Polling-Hinweis

MT5 EA pollt 500–1000 ms. `/poll` liefert FIFO ein Signal pro Aufruf;
leere Queue → `200 []` (kein 404).

## MT EA

JSON Loader = [JSON Loader](https://github.com/vivazzi/JAson)