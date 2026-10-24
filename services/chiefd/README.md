# chiefd

`chiefd` is Chief's local, read-only observation boundary. It exposes a normalized portfolio
snapshot and a small event stream to browser, desktop, and automation clients. It does not launch,
stop, approve, merge, or otherwise control an agent session.

```sh
python3 -m services.chiefd \
  --snapshot apps/portfolio/public/snapshot.json \
  --static-root apps/portfolio/public \
  --port 4174
```

Environment equivalents are `CHIEFD_HOST`, `CHIEFD_PORT`, `CHIEFD_SNAPSHOT`, and
`CHIEFD_STATIC_ROOT`; `CHIEFD_DATABASE` selects the local SQLite history file. The default listener is `127.0.0.1:4174`; it is intentionally not reachable
from other hosts.

## API

| Endpoint | Contract |
|---|---|
| `GET /health` | Service and source freshness; `503` when the snapshot is unavailable or invalid |
| `GET /api/v1` | Endpoint discovery |
| `GET /api/v1/snapshot` | Current collector output with `ETag` / `If-None-Match` support |
| `GET /api/v1/events` | Server-sent events; emits `snapshot.updated` when the source changes |
| `GET /api/v1/history` | Durable recent lifecycle events projected into local SQLite |
| `POST /api/v1/refresh` | Re-read configured sources without controlling any provider session |
| `GET /` | Optional static portfolio dashboard |

The service refreshes the configured Git, provider, tracker, and private-workspace sources every 30
seconds, watches the generated snapshot boundary, and stores changed snapshots plus normalized
lifecycle events in a local SQLite projection. Timestamp-only refreshes are deduplicated and the
latest 100 semantic snapshots are retained. The stream is deliberately an observation feed, not a
provider command channel.

Run the hermetic service tests with:

```sh
python3 -m unittest discover -s services/chiefd/tests
```
