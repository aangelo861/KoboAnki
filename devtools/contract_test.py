#!/usr/bin/env python3
"""Contract test: the real kanki server must return every field the UI's mock server returns.

The KOReader plugin was developed against koplugin/devtools/mock_server.py. If the real server
drifts from it (as when /status lacked "card_count" and the plugin re-synced every second), this
fails. Runs the real server against Anki's own sync server locally (never AnkiWeb).

  devtools/contract_test.py <collection.anki2 to copy> <work dir>
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "target", "release")
MOCK = os.path.join(ROOT, "koplugin", "devtools", "mock_server.py")
SYNC_PORT, REAL_PORT, MOCK_PORT = 8091, 47995, 47994
ENDPOINT = f"http://127.0.0.1:{SYNC_PORT}/"


def call(port, method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")


def wait_up(port, path="/status", secs=30):
    for _ in range(secs * 4):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=1)
            return
        except urllib.error.HTTPError:
            return  # any HTTP answer (e.g. the sync server's 404 for "/") means it's up
        except Exception:
            time.sleep(0.25)
    sys.exit(f"port {port} never came up")


def wait_sync(port):
    for _ in range(600):
        s = call(port, "GET", "/sync")
        if s.get("state") != "running":
            return s
        time.sleep(0.5)
    sys.exit("sync timed out")


def shape(v, path, out):
    """Collect key paths (lists: their first element) with a coarse type."""
    if isinstance(v, dict):
        for k, x in v.items():
            shape(x, f"{path}.{k}", out)
    elif isinstance(v, list):
        if v:
            shape(v[0], f"{path}[]", out)
    out[path] = type(v).__name__


def main():
    src, work = sys.argv[1], sys.argv[2]
    shutil.rmtree(work, ignore_errors=True)
    for d in ("desktop", "kobo", "syncbase", "mock"):
        os.makedirs(os.path.join(work, d))
    subprocess.run(["cp", "-c", src, os.path.join(work, "desktop", "collection.anki2")], check=True)
    procs = []
    try:
        env = dict(os.environ, SYNC_USER1="test:test", SYNC_BASE=os.path.join(work, "syncbase"),
                   SYNC_HOST="127.0.0.1", SYNC_PORT=str(SYNC_PORT))
        procs.append(subprocess.Popen([os.path.join(BIN, "kanki_devsync"), "server"], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        wait_up(SYNC_PORT, "/")
        subprocess.run([os.path.join(BIN, "kanki_devsync"), "upload",
                        os.path.join(work, "desktop", "collection.anki2"), ENDPOINT, "test", "test"],
                       check=True, stdout=subprocess.DEVNULL)

        log = open(os.path.join(work, "kanki.log"), "w")
        procs.append(subprocess.Popen([os.path.join(BIN, "kanki"), "serve", "--data-dir",
                                       os.path.join(work, "kobo"), "--port", str(REAL_PORT)],
                                      stdout=log, stderr=log))
        procs.append(subprocess.Popen([sys.executable, MOCK, "--scenario", "ready", "--port", str(MOCK_PORT),
                                       "--data-dir", os.path.join(work, "mock")],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        wait_up(REAL_PORT)
        wait_up(MOCK_PORT)

        call(REAL_PORT, "POST", "/login", {"username": "test", "password": "test", "endpoint": ENDPOINT})
        call(REAL_PORT, "POST", "/sync", {"kind": "normal"})
        wait_sync(REAL_PORT)

        failures = []
        st = call(REAL_PORT, "GET", "/status")
        if not isinstance(st.get("card_count"), int) or st["card_count"] <= 0:
            failures.append(f"/status card_count after sync should be a positive int, got {st.get('card_count')!r}")

        real_card = call(REAL_PORT, "GET", "/next?img_max_px=600").get("card", {}).get("id")
        mock_card = call(MOCK_PORT, "GET", "/next?img_max_px=600").get("card", {}).get("id")
        checks = [
            ("GET", "/status", "/status"),
            ("GET", "/sync", "/sync"),
            ("GET", "/decks", "/decks"),
            ("GET", "/next?img_max_px=600", "/next?img_max_px=600"),
            ("GET", f"/card?id={real_card}&img_max_px=600", f"/card?id={mock_card}&img_max_px=600"),
            ("GET", "/verify", "/verify"),
            ("GET", "/stats", "/stats"),
            ("POST", "/flag", "/flag"),
        ]
        bodies = {"/flag": ({"card_id": real_card, "flag": 0}, {"card_id": mock_card, "flag": 0})}
        for method, real_path, mock_path in checks:
            real, mock = {}, {}
            real_body, mock_body = bodies.get(real_path, (None, None))
            shape(call(REAL_PORT, method, real_path, real_body), "", real)
            shape(call(MOCK_PORT, method, mock_path, mock_body), "", mock)
            name = real_path.split("?")[0]
            for key, typ in sorted(mock.items()):
                if key.startswith(".mock_"):
                    continue  # mock-only debugging fields
                if key not in real:
                    failures.append(f"{name}: real server lacks {key or '<root>'} (mock: {typ})")
                elif typ != real[key] and "NoneType" not in (typ, real[key]) and {typ, real[key]} != {"int", "float"}:
                    failures.append(f"{name}: {key} is {real[key]} on the real server, {typ} in the mock")
            print(f"checked {name}: {len(mock)} mock fields")

        if failures:
            print("\nCONTRACT FAILURES:")
            for f in failures:
                print("  - " + f)
            sys.exit(1)
        print("\ncontract OK: the real server provides every field the mock (and so the plugin) uses")
    finally:
        try:
            call(REAL_PORT, "POST", "/shutdown", timeout=20)
            call(MOCK_PORT, "POST", "/shutdown", timeout=5)
        except Exception:
            pass
        time.sleep(1)
        for p in procs:
            p.terminate()


if __name__ == "__main__":
    main()
