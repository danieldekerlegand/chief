from __future__ import annotations

import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from services.chiefd.server import ChiefdServer
from services.chiefd.store import HistoryStore


class ChiefdServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.snapshot = root / "snapshot.json"
        self.snapshot.write_text(
            json.dumps(
                {
                    "schemaVersion": "chief.portfolio/v1",
                    "generatedAt": "2026-10-21T00:00:00Z",
                    "workspace": {"name": "Test", "root": str(root)},
                    "projects": [],
                    "roadmap": [],
                    "gauntlets": [],
                    "competitors": [],
                    "ideas": [],
                    "runs": [],
                    "research": [],
                    "sources": [],
                }
            )
        )
        self.static_root = root / "public"
        self.static_root.mkdir()
        (self.static_root / "index.html").write_text("<h1>Chief</h1>")
        self.service = ChiefdServer(
            snapshot=self.snapshot,
            static_root=self.static_root,
            host="127.0.0.1",
            port=0,
            poll_interval=0.05,
            quiet=True,
            database=root / "chiefd.sqlite3",
        )
        self.thread = threading.Thread(target=self.service.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.service.address
        self.base = f"http://{host}:{port}"

    def tearDown(self) -> None:
        self.service.shutdown()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def get_json(self, path: str) -> tuple[dict, object]:
        with urlopen(f"{self.base}{path}", timeout=2) as response:
            return json.load(response), response.headers

    def test_health_and_snapshot_are_available(self) -> None:
        health, _ = self.get_json("/health")
        self.assertEqual(health["service"], "chiefd")
        self.assertEqual(health["status"], "ok")
        self.assertTrue(health["snapshot"]["available"])

        snapshot, headers = self.get_json("/api/v1/snapshot")
        self.assertEqual(snapshot["workspace"]["name"], "Test")
        self.assertTrue(headers["ETag"].startswith('"'))

    def test_snapshot_supports_conditional_reads(self) -> None:
        _, headers = self.get_json("/api/v1/snapshot")
        request = Request(f"{self.base}/api/v1/snapshot", headers={"If-None-Match": headers["ETag"]})
        with self.assertRaises(HTTPError) as result:
            urlopen(request, timeout=2)
        self.assertEqual(result.exception.code, 304)

    def test_static_assets_and_traversal_guard(self) -> None:
        with urlopen(f"{self.base}/", timeout=2) as response:
            self.assertEqual(response.read(), b"<h1>Chief</h1>")
        with self.assertRaises(HTTPError) as result:
            urlopen(f"{self.base}/%2e%2e/snapshot.json", timeout=2)
        self.assertEqual(result.exception.code, 404)

    def test_tauri_origin_receives_cors_headers(self) -> None:
        request = Request(f"{self.base}/health", headers={"Origin": "tauri://localhost"})
        with urlopen(request, timeout=2) as response:
            self.assertEqual(response.headers["Access-Control-Allow-Origin"], "tauri://localhost")

    def test_event_stream_emits_current_snapshot(self) -> None:
        host, port = self.service.address
        connection = http.client.HTTPConnection(host, port, timeout=2)
        connection.request("GET", "/api/v1/events")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        lines = [response.readline().decode().rstrip("\n") for _ in range(4)]
        self.assertTrue(lines[0].startswith("id: "))
        self.assertEqual(lines[1], "event: snapshot.updated")
        self.assertTrue(lines[2].startswith("data: "))
        event = json.loads(lines[2].removeprefix("data: "))
        self.assertEqual(event["schemaVersion"], "chief.event/v1")
        self.assertEqual(event["kind"], "snapshot.updated")
        connection.close()

        history, _ = self.get_json("/api/v1/history")
        self.assertEqual(history["events"][0]["kind"], "snapshot.updated")


class MissingSnapshotTest(unittest.TestCase):
    def test_missing_snapshot_makes_health_degraded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            service = ChiefdServer(
                snapshot=Path(temporary) / "missing.json",
                static_root=None,
                host="127.0.0.1",
                port=0,
                quiet=True,
            )
            thread = threading.Thread(target=service.serve_forever, daemon=True)
            thread.start()
            host, port = service.address
            try:
                with self.assertRaises(HTTPError) as result:
                    urlopen(f"http://{host}:{port}/health", timeout=2)
                self.assertEqual(result.exception.code, 503)
                body = json.loads(result.exception.read())
                self.assertEqual(body["status"], "degraded")
            finally:
                service.shutdown()
                thread.join(timeout=2)


class CollectorBootstrapTest(unittest.TestCase):
    def test_configured_service_builds_and_refreshes_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / "Development"
            workspace.mkdir()
            config = root / "portfolio.json"
            config.write_text(json.dumps({
                "workspace": {"name": "Fresh install", "root": str(workspace)},
                "scan": {"exclude": [], "roadmap_names": ["ROADMAP.md"]},
            }))
            snapshot = root / "snapshot.json"
            service = ChiefdServer(
                snapshot=snapshot, static_root=None, host="127.0.0.1", port=0,
                quiet=True, collector_config=config, database=root / "history.sqlite3",
            )
            thread = threading.Thread(target=service.serve_forever, daemon=True)
            thread.start()
            host, port = service.address
            try:
                self.assertTrue(snapshot.exists())
                request = Request(f"http://{host}:{port}/api/v1/refresh", method="POST")
                with urlopen(request, timeout=2) as response:
                    self.assertTrue(json.load(response)["refreshed"])
                blocked = Request(
                    f"http://{host}:{port}/api/v1/refresh", method="POST",
                    headers={"Origin": "https://untrusted.example"},
                )
                with self.assertRaises(HTTPError) as result:
                    urlopen(blocked, timeout=2)
                self.assertEqual(result.exception.code, 403)
                with urlopen(f"http://{host}:{port}/api/v1/snapshot", timeout=2) as response:
                    document = json.load(response)
                self.assertEqual(document["workspace"]["name"], "Fresh install")
                self.assertIn("nativeSessions", document)
            finally:
                service.shutdown()
                thread.join(timeout=2)


class HistoryStoreTest(unittest.TestCase):
    def test_native_events_deduplicate_across_snapshot_etags(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = HistoryStore(Path(temporary) / "history.sqlite3")
            native = {
                "schemaVersion": "chief.normalized-event/v1", "id": "provider:event-1",
                "eventType": "stage.completed", "observedAt": "2026-10-21T12:00:00Z",
            }
            document = {"generatedAt": "2026-10-21T12:00:00Z", "events": [native]}
            store.record('"etag-1"', "2026-10-21T12:00:00Z", document, {"kind": "snapshot.updated"})
            document["generatedAt"] = "2026-10-21T12:01:00Z"
            store.record('"etag-2"', "2026-10-21T12:01:00Z", document, {"kind": "snapshot.updated"})
            events = store.events()
            self.assertEqual(sum(item.get("id") == "provider:event-1" for item in events), 1)
            self.assertEqual(sum(item.get("kind") == "snapshot.updated" for item in events), 1)


if __name__ == "__main__":
    unittest.main()
