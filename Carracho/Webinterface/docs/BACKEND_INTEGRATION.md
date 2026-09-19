# Backend-Erweiterungen für Transfermonitor, Kick, Log und SSE

Die Web-GUI ist für diese Endpunkte vorbereitet. Sie liegen unter der bestehenden
`/api/v1`-Admin-API und verwenden denselben Bearer-Token wie die bisherigen Routen.

## 1. Aktive Transfers

### `GET /api/v1/transfers`

Antwort:

```json
{
  "transfers": [
    {
      "id": "transfer-42",
      "user": "luigi",
      "direction": "download",
      "fileName": "ubuntu.iso",
      "path": "/Software/ubuntu.iso",
      "sizeBytes": 5046586572,
      "transferredBytes": 2483027968,
      "speedBytesPerSecond": 19293798,
      "etaSeconds": 133,
      "status": "active",
      "startedAt": "2026-09-19T10:55:12Z"
    }
  ]
}
```

`direction` ist `download` oder `upload`. `id` muss während der Lebensdauer des
Transfers stabil sein.

### `POST /api/v1/transfers/{id}/cancel`

Erfolg: `200 {"ok":true}` oder `204 No Content`.

Der Abbruch sollte dieselbe interne Transfer-Abbruchfunktion verwenden wie eine
lokale Admin-/Serveraktion und nicht nur einen Datenbankwert umschalten.

## 2. User-Kick

### `POST /api/v1/users/{id}/kick`

`id` sollte bevorzugt eine Session-ID sein. Falls die bestehende Userliste nur eine
stabile numerische User-ID liefert, kann diese verwendet werden.

Erfolg: `200 {"ok":true}` oder `204 No Content`.

## 3. Log-Snapshot

### `GET /api/v1/log?limit=200`

Antwort:

```json
{
  "entries": [
    {
      "time": "2026-09-19T10:55:12Z",
      "type": "server",
      "message": "User luigi connected"
    }
  ]
}
```

Die letzten Einträge reichen. Die Web-GUI hält selbst einen kleinen lokalen Verlauf.

## 4. Live Events via Server-Sent Events

### `GET /api/v1/events`

Content-Type:

```text
text/event-stream
```

Ein einfaches Event genügt:

```text
data: {"type":"transfer.updated","message":"Transfer transfer-42 updated","time":"2026-09-19T10:55:13Z"}

```

Sinnvolle Eventtypen:

- `user.connected`
- `user.disconnected`
- `user.kicked`
- `transfer.started`
- `transfer.updated`
- `transfer.completed`
- `transfer.cancelled`
- `conference.created`
- `conference.deleted`
- `log`

Der native Web-Proxy reicht `Accept: text/event-stream` und `Last-Event-ID` inzwischen
zum Carracho-Server durch und streamt die Antwort ohne Zwischenpufferung weiter.

## Fallback

Die Transferseite pollt `GET /transfers` einmal pro Sekunde. Beim Live-Log wird SSE
bevorzugt; wenn `/events` nicht verfügbar ist, wird `/log` periodisch abgefragt.
Damit bleibt das Webend auch während einer schrittweisen Server-Integration benutzbar.
