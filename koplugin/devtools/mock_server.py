#!/usr/bin/env python3
"""Mock of the kanki HTTP API (DESIGN.md), stdlib only.

Lets the KOReader plugin (or the Lua client tests in this folder) be exercised without the Rust
server or AnkiWeb. Behaves like `kanki serve`:

    python3 mock_server.py [serve] [--port 47321] [--data-dir DIR] [--parent-pid PID]
                           [--font-dir DIR] [--scenario ready|fresh|no-collection|full-sync|sync-error]
                           [--sync-speed 1.0] [--write-media]
                           [--shutdown-delay 0.2] [--exit-delay 0.2] [--ignore-shutdown]

Scenarios:
  ready          logged in, collection present (default)
  fresh          logged out, no collection: login -> first sync becomes a full download
  no-collection  logged in, but no collection yet
  full-sync      the first normal sync answers full_sync_required; full_download then works
  sync-error     every sync fails with a network error

Login: any email + any password except "wrong" (-> 401 kind auth). The password is never printed.
With --write-media, the PNG referenced by the sample image card is written to
DATA_DIR/collection.media so a desktop KOReader can show it.
Exits with code 3 if the port is already in use (like the real server).

POST /shutdown replies after --shutdown-delay (the real server closes the collection first, up to
~15 s when it has to abort a sync), keeps serving for --exit-delay, then exits.
--ignore-shutdown: reply but never exit (to test the plugin's last-resort kill).
GET /status also carries the mock-only field "mock_parent_pid" (what POST /adopt set).
"""

import argparse
import base64
import copy
import json
import os
import random
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "0.1.0-mock"
ANKI_VERSION = "26.09.3"

LOCK = threading.RLock()
LAST_REQUEST = time.time()
PARENT_PID = None
ARGS = None

# Natural widths of the sample images (the server adds width="img_max_px" only above that).
IMAGE_WIDTHS = {"ecg_stemi.png": 1600}

CARD_CSS = """.card {
  font-family: arial;
  font-size: 20px;
  text-align: center;
  color: black;
  background-color: white;
}
.cloze { font-weight: bold; color: blue; }
.nightMode .cloze { color: lightblue; }
#extra { font-size: 15px; color: #333; margin-top: 12px; }
table.dose td { border: 1px solid #000; padding: 4px 8px; }
"""

LONG_BACK = "".join(
    "<p><b>%d.</b> %s</p>" % (i, t)
    for i, t in enumerate(
        [
            "Airway: look, listen, feel; jaw thrust, adjuncts, call anaesthetics early.",
            "Breathing: SpO2, RR, chest expansion, percussion, auscultation; high-flow O2 15 L/min.",
            "Circulation: HR, BP, CRT, ECG; two large-bore cannulae, bloods incl. lactate and cultures.",
            "Disability: AVPU/GCS, pupils, glucose (treat < 4 mmol/L).",
            "Exposure: temperature, rashes, bleeding, calves, catheter, drains.",
            "Reassess after every intervention; escalate (2222 / outreach) if not improving.",
            "Document clearly with times; handover using SBAR.",
            "Consider sepsis six within the first hour: O2, cultures, IV antibiotics, fluids, lactate, urine output.",
            "Check the drug chart, allergies and any treatment-escalation plan or DNACPR.",
            "Speak to the family once the patient is stable.",
        ]
        * 3,
        start=1,
    )
)


def make_card(cid, note, kind, front, back, deck, extra="", ord=1):
    question = front
    answer = front + "<hr id=answer>" + back + (('<div id="extra">%s</div>' % extra) if extra else "")
    return {
        "id": cid,
        "note_id": note,
        "deck": deck,
        "kind": kind,
        "ord": ord,
        "flag": 0,
        "question": question,
        "answer": answer,
        "css": CARD_CSS,
    }


def png_bytes(w, h, pixel, solid=None):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    if solid:
        row = b"\x00" + bytes(solid) * w
        raw = row * h
    else:
        raw = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


_OCCLUSION_URI = None


def occlusion_data_uri():
    """Image occlusion cards come back as ONE <img src="data:..."> of 100-900 KB."""
    global _OCCLUSION_URI
    if _OCCLUSION_URI is None:
        rnd = random.Random(7)
        def pixel(x, y):
            if 80 <= x < 220 and 120 <= y < 170:  # the flattened occlusion mask
                return (255, 140, 0)
            v = rnd.randrange(150, 256)
            return (v, v, rnd.randrange(150, 256))
        data = png_bytes(320, 300, pixel)
        _OCCLUSION_URI = "data:image/png;base64," + base64.b64encode(data).decode("ascii")
    return _OCCLUSION_URI


def cloze(cid, note, kind, text_q, text_a, deck, extra="", ord=1):
    c = make_card(cid, note, kind, text_q, "", deck, extra, ord)
    # Anki cloze answers don't repeat the front: the answer is the revealed text (+ extra)
    c["answer"] = text_a + (('<div id="extra">%s</div>' % extra) if extra else "")
    return c


def initial_cards():
    cards = [
        make_card(1690000000001, 1690000000101, "review",
                  "What is the first-line treatment of anaphylaxis in adults?",
                  "<b>IM adrenaline 0.5 mg</b> (0.5 mL of 1:1000) into the anterolateral thigh; repeat after 5 min if needed.",
                  "Medicine::Paper A", "Resuscitation Council UK 2021"),
        cloze(1690000000002, 1690000000102, "new",
              'In type 2 diabetes <span class="cloze">[...]</span> is the first-line oral agent unless contraindicated.',
              'In type 2 diabetes <span class="cloze">metformin</span> is the first-line oral agent unless contraindicated.',
              "Medicine::Paper A", "Avoid if eGFR &lt; 30."),
        {"id": 1690000000008, "note_id": 1690000000108, "deck": "Medicine::Paper A", "kind": "new",
         "ord": 2, "css": CARD_CSS,
         "question": '<div>Name the structure under the mask:</div><img src="%s">' % occlusion_data_uri(),
         "answer": '<div>Name the structure under the mask:</div><img src="%s"><hr id=answer>'
                   '<b>Left ventricle</b>' % occlusion_data_uri()},
        make_card(1690000000003, 1690000000103, "learning",
                  'Identify the territory of this STEMI:<br><img src="ecg_stemi.png">',
                  'Inferior (II, III, aVF): usually <b>right coronary artery</b>.',
                  "Medicine::Paper B::Cardiology"),
        make_card(1690000000004, 1690000000104, "review",
                  "Outline the ABCDE assessment of the acutely unwell patient.",
                  LONG_BACK, "Medicine::Paper B::Cardiology"),
        make_card(1690000000005, 1690000000105, "relearning",
                  '<span style="font-size: 26px">Gentamicin</span>: main toxicities?',
                  '<table class="dose"><tr><td>Ear</td><td>Ototoxicity (vestibular &gt; cochlear)</td></tr>'
                  '<tr><td>Kidney</td><td>Nephrotoxicity (ATN)</td></tr></table>'
                  '<p style="font-size:14px">Monitor levels (Hartford nomogram).</p>',
                  "Medicine::Paper B::Pharmacology"),
        cloze(1690000000006, 1690000000106, "new",
              'The antidote for paracetamol overdose is <span class="cloze">[...]</span>.',
              'The antidote for paracetamol overdose is <span class="cloze">acetylcysteine</span>.',
              "Medicine::Paper B::Pharmacology"),
        make_card(1690000000007, 1690000000107, "review",
                  "CURB-65 components?",
                  "Confusion, Urea &gt; 7, RR ≥ 30, BP &lt; 90/≤ 60, age ≥ 65.",
                  "Mock Exams::2025"),
    ]
    return cards


DECKS = [
    # id, name, depth, has_children, collapsed
    (1, "Default", 0, False, False),
    (10, "Medicine", 0, True, False),
    (11, "Medicine::Paper A", 1, False, False),
    (12, "Medicine::Paper B", 1, True, False),
    (13, "Medicine::Paper B::Cardiology", 2, False, False),
    (14, "Medicine::Paper B::Pharmacology", 2, False, False),
    (20, "Mock Exams", 0, True, True),
    (21, "Mock Exams::2025", 1, False, False),
]

INTERVALS = {
    "new": ["<1m", "<6m", "<10m", "4d"],
    "learning": ["<1m", "<6m", "1d", "4d"],
    "relearning": ["<10m", "<15m", "1d", "3d"],
    "review": ["<10m", "2d", "5d", "9d"],
}


class State:
    def __init__(self, scenario, sync_speed, data_dir):
        self.scenario = scenario
        self.sync_speed = max(0.05, sync_speed)
        self.data_dir = data_dir
        self.logged_in = scenario not in ("fresh",)
        self.username = "doctor@example.com" if self.logged_in else None
        self.has_collection = scenario not in ("fresh", "no-collection")
        self.cards = initial_cards() if self.has_collection else []
        self.current_deck = 11
        self.undo_stack = []
        self.answered_today = 0
        self.full_sync_pending = scenario == "full-sync"
        self.sync = {
            "state": "idle",
            "stage": None,
            "message": "",
            "server_message": "",
            "media": {"checked": 0, "downloaded": 0, "uploaded": 0, "deleted": 0},
            "last_success": int(time.time()) - 3 * 3600 if self.has_collection else None,
        }
        self.job = None  # dict(kind, started)
        self.sync_count = 0

    # --- sync job simulation ---------------------------------------------------------------
    def tick(self):
        job = self.job
        if not job:
            return
        t = (time.time() - job["started"]) / self.sync_speed
        s = self.sync
        if job["kind"] == "normal" and self.full_sync_pending and t >= 1.5:
            self.full_sync_pending = False
            s.update(state="full_sync_required", stage=None,
                     message="The collection was modified in a way that requires a one-way sync.")
            self.job = None
            return
        if self.scenario == "sync-error" and t >= 1.5:
            s.update(state="error", stage=None, message="AnkiWeb could not be reached (network error).")
            self.job = None
            return
        coll_len = 6.0 if job["kind"] == "full_download" else 3.0
        media_len = 8.0 if job["kind"] == "full_download" else 4.0
        if t < coll_len:
            pct = int(100 * t / coll_len)
            if job["kind"] == "full_download":
                msg = "Downloading collection… %d%%" % pct
            else:
                msg = ["Checking…", "Sending changes…", "Receiving changes…"][min(2, int(3 * t / coll_len))]
            s.update(state="running", stage="collection", message=msg)
        elif t < coll_len + media_len:
            if not self.has_collection or job["kind"] == "full_download":
                self.has_collection = True
                self.cards = initial_cards()
                self.undo_stack = []
            frac = (t - coll_len) / media_len
            total = 4500 if job["kind"] == "full_download" else 120
            s.update(state="running", stage="media", message="")
            s["media"] = {
                "checked": int(total * frac),
                "downloaded": int(total * frac * 0.6),
                "uploaded": 0 if job["kind"] == "full_download" else int(3 * frac),
                "deleted": 0,
            }
        else:
            self.has_collection = True
            if not self.cards:
                self.cards = initial_cards()
            s.update(state="done", stage=None, message="")
            s["last_success"] = int(time.time())
            if self.sync_count % 3 == 1:
                s["server_message"] = "AnkiWeb will be down for maintenance on Sunday 02:00–03:00 UTC."
            self.job = None

    def collection_busy(self):
        self.tick()
        return self.job is not None and self.sync.get("stage") == "collection"

    # --- decks & queue ----------------------------------------------------------------------
    def deck_ids_under(self, deck_id):
        name = next(n for i, n, *_ in DECKS if i == deck_id)
        return {i for i, n, *_ in DECKS if n == name or n.startswith(name + "::")}

    def deck_id_by_name(self, name):
        return next(i for i, n, *_ in DECKS if n == name)

    def counts_for(self, deck_id):
        ids = self.deck_ids_under(deck_id)
        c = {"new": 0, "learning": 0, "review": 0}
        for card in self.cards:
            if self.deck_id_by_name(card["deck"]) in ids:
                k = card["kind"]
                if k == "new":
                    c["new"] += 1
                elif k in ("learning", "relearning"):
                    c["learning"] += 1
                else:
                    c["review"] += 1
        return c

    def queue(self):
        ids = self.deck_ids_under(self.current_deck)
        return [c for c in self.cards if self.deck_id_by_name(c["deck"]) in ids]

    def next_body(self, img_max_px=None):
        if not self.has_collection:
            return {"state": "no_collection", "counts": {"new": 0, "learning": 0, "review": 0},
                    "undo": None}
        q = self.queue()
        undo = self.undo_stack[-1]["label"] if self.undo_stack else None
        counts = self.counts_for(self.current_deck)
        if not q:
            return {"state": "done", "counts": counts, "undo": undo}
        card = copy.deepcopy(q[0])
        ivl = INTERVALS[card["kind"]]
        card["buttons"] = [
            {"rating": i + 1, "label": lbl, "interval": ivl[i]}
            for i, lbl in enumerate(["Again", "Hard", "Good", "Easy"])
        ]
        cap_images(card, img_max_px)
        return {"state": "card", "counts": counts, "undo": undo, "card": card}

    def card_body(self, card_id, img_max_px=None):
        card = next((c for c in self.cards if c["id"] == card_id), None)
        if card is None:
            card = next((c for c in initial_cards() if c["id"] == card_id), None)
        if card is None:
            return None
        card = copy.deepcopy(card)
        cap_images(card, img_max_px)
        # Same shape as the real server's GET /card (a preview: no deck/kind/ord/note_id).
        return {"card": {k: card[k] for k in ("id", "question", "answer", "css")}}

    def stats(self):
        """GET /stats, shaped like the real server (kanki/src/engine.rs Engine::stats)."""
        now = int(time.time())
        answered = self.answered_today
        days = [{"day": d, "count": c, "seconds": c * 9} for d, c in
                zip(range(-13, 1), [52, 0, 61, 75, 40, 33, 0, 88, 64, 70, 45, 58, 66, answered])]
        streak = 0
        for d in reversed(days if answered else days[:-1]):
            if d["count"] == 0:
                break
            streak += 1
        return {
            "today": {"answered": answered, "seconds": answered * 9, "correct": int(answered * 0.88),
                      "learn": answered // 5, "review": answered - answered // 5, "relearn": 0,
                      "mature_correct": int(answered * 0.5), "mature_total": answered // 2},
            "days": days,
            "streak": streak,
            "due_today": {k: sum(self.counts_for(d)[k] for d, n, *_ in DECKS if "::" not in n)
                          for k in ("new", "learning", "review")},
            "due_tomorrow": 87,
            "retention": {"today": 0.88 if answered else None, "week": 0.9, "month": 0.89},
            "cards": {"new": 543, "learn": 4, "relearn": 1, "young": 1610, "mature": 2988,
                      "suspended": 0, "buried": 0},
            "studied_text": "Studied %d cards in %d minutes today." % (answered, answered * 9 // 60),
            "next_day_at": now - now % 86400 + 86400 + 4 * 3600,
            "generated_at": now,
        }

    def verify(self):
        media = 0
        if self.data_dir:
            d = os.path.join(self.data_dir, "collection.media")
            if os.path.isdir(d):
                media = len(os.listdir(d))
        return {"cards": len(self.cards) + 4521 if self.has_collection else 0,
                "notes": len(self.cards) + 3100 if self.has_collection else 0,
                "media_files": media}

    def push_undo(self, label):
        self.undo_stack.append({"label": label, "cards": copy.deepcopy(self.cards)})

    def answer(self, card_id, rating):
        idx = next((i for i, c in enumerate(self.cards) if c["id"] == card_id), None)
        if idx is None:
            return False
        self.push_undo("Answer Card")
        self.answered_today += 1
        card = self.cards.pop(idx)
        if rating == 1:
            card["kind"] = "relearning" if card["kind"] == "review" else "learning"
            self.cards.append(card)  # comes back later in this session
        return True

    def remove(self, card_id, label):
        idx = next((i for i, c in enumerate(self.cards) if c["id"] == card_id), None)
        if idx is None:
            return False
        self.push_undo(label)
        self.cards.pop(idx)
        return True

    def undo(self):
        if not self.undo_stack:
            return False
        entry = self.undo_stack.pop()
        before = {c["id"] for c in self.cards}
        self.cards = entry["cards"]
        # bring the undone card to the front, like Anki does
        restored = [c for c in self.cards if c["id"] not in before]
        if restored:
            self.cards.remove(restored[0])
            self.cards.insert(0, restored[0])
        return True


def cap_images(card, img_max_px):
    """Like the real server: add width="img_max_px" only to images wider than img_max_px."""
    if not img_max_px:
        return
    for side in ("question", "answer"):
        html = card[side]
        for name, natural in IMAGE_WIDTHS.items():
            if natural > img_max_px:
                html = html.replace('<img src="%s">' % name, '<img src="%s" width="%d">' % (name, img_max_px))
        card[side] = html


STATE = None


class Handler(BaseHTTPRequestHandler):
    server_version = "kanki-mock/" + VERSION

    def log_message(self, fmt, *args):  # quieter default logging
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # --- helpers ---------------------------------------------------------------------------
    def send_json(self, code, body):
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, code, kind, message):
        self.send_json(code, {"error": message, "kind": kind})

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return None

    def img_max(self, query):
        v = query.get("img_max_px", [None])[0]
        return int(v) if v and v.isdigit() else None

    # --- routing ---------------------------------------------------------------------------
    def do_GET(self):
        global LAST_REQUEST
        LAST_REQUEST = time.time()
        url = urlparse(self.path)
        q = parse_qs(url.query)
        with LOCK:
            STATE.tick()
            if url.path == "/status":
                return self.send_json(200, {
                    "version": VERSION, "anki_version": ANKI_VERSION,
                    "logged_in": STATE.logged_in, "username": STATE.username,
                    "has_collection": STATE.has_collection,
                    "card_count": len(STATE.cards) + 4521 if STATE.has_collection else 0,
                    "media_dir": (os.path.abspath(os.path.join(STATE.data_dir, "collection.media"))
                                  if STATE.data_dir else None),
                    "mock_parent_pid": PARENT_PID,
                    "sync": STATE.sync,
                    "undo": STATE.undo_stack[-1]["label"] if STATE.undo_stack else None,
                })
            if url.path == "/sync":
                return self.send_json(200, STATE.sync)
            if url.path == "/stats":
                if not STATE.has_collection:
                    return self.error(404, "no_collection", "No collection on this device yet.")
                return self.send_json(200, STATE.stats())
            if url.path == "/verify":
                return self.send_json(200, STATE.verify())
            if url.path == "/card":
                if not STATE.has_collection:
                    return self.error(404, "no_collection", "No collection on this device yet.")
                try:
                    cid = int(q.get("id", [""])[0])
                except ValueError:
                    return self.error(400, "bad_request", "id (int) is required")
                body = STATE.card_body(cid, self.img_max(q))
                if body is None:
                    return self.error(400, "bad_request", "No such card: %d" % cid)
                return self.send_json(200, body)
            if url.path == "/decks":
                if STATE.collection_busy():
                    return self.error(409, "busy", "A collection sync is in progress.")
                if not STATE.has_collection:
                    return self.error(404, "no_collection", "No collection on this device yet.")
                decks = []
                for i, name, depth, kids, collapsed in DECKS:
                    c = STATE.counts_for(i)
                    decks.append({"id": i, "name": name, "short_name": name.split("::")[-1],
                                  "depth": depth, "new": c["new"], "learning": c["learning"],
                                  "review": c["review"], "collapsed": collapsed,
                                  "has_children": kids})
                return self.send_json(200, {"current_id": STATE.current_deck, "decks": decks})
            if url.path == "/next":
                if STATE.collection_busy():
                    return self.error(409, "busy", "A collection sync is in progress.")
                return self.send_json(200, STATE.next_body(self.img_max(q)))
        return self.error(404, "bad_request", "No such endpoint: " + url.path)

    def do_POST(self):
        global LAST_REQUEST, PARENT_PID
        LAST_REQUEST = time.time()
        url = urlparse(self.path)
        q = parse_qs(url.query)
        body = self.read_json()
        if body is None:
            return self.error(400, "bad_request", "Body is not valid JSON.")
        if url.path == "/shutdown":
            # Real server: closes the collection (aborting a sync) BEFORE replying, then exits ~1 s later.
            time.sleep(ARGS.shutdown_delay)
            self.send_json(200, {"ok": True})
            if not ARGS.ignore_shutdown:
                threading.Thread(target=lambda: (time.sleep(ARGS.exit_delay), os._exit(0)),
                                 daemon=True).start()
            return
        if url.path == "/adopt":
            pid = body.get("parent_pid")
            if not isinstance(pid, int) or pid <= 0:
                return self.error(400, "bad_request", "parent_pid (int) is required")
            PARENT_PID = pid
            sys.stderr.write("  adopted by parent pid %d\n" % pid)
            return self.send_json(200, {"ok": True})
        with LOCK:
            STATE.tick()
            p = url.path
            if p == "/login":
                user = (body.get("username") or "").strip()
                pw = body.get("password") or ""
                sys.stderr.write("  login attempt for %r (password not shown)\n" % user)
                if not user or not pw:
                    return self.error(400, "bad_request", "Username and password are required.")
                time.sleep(0.8)  # AnkiWeb round trip
                if pw == "wrong":
                    return self.error(401, "auth", "AnkiWeb ID or password was incorrect.")
                STATE.logged_in, STATE.username = True, user
                return self.send_json(200, {"ok": True})
            if p == "/logout":
                STATE.logged_in, STATE.username = False, None
                return self.send_json(200, {"ok": True})
            if p == "/sync":
                kind = body.get("kind", "normal")
                if kind not in ("normal", "full_download"):
                    return self.error(400, "bad_request", "kind must be normal or full_download")
                if not STATE.logged_in:
                    return self.error(401, "need_login", "Please log in to AnkiWeb first.")
                if STATE.job:
                    return self.error(409, "busy", "A sync is already running.")
                if not STATE.has_collection:
                    kind = "full_download"
                STATE.sync_count += 1
                STATE.job = {"kind": kind, "started": time.time()}
                STATE.sync.update(state="running", stage="collection", message="Starting…",
                                  server_message="")
                STATE.sync["media"] = {"checked": 0, "downloaded": 0, "uploaded": 0, "deleted": 0}
                return self.send_json(202, {"started": True})
            # collection endpoints
            if p in ("/deck/select", "/answer", "/undo", "/bury", "/suspend", "/flag"):
                if STATE.collection_busy():
                    return self.error(409, "busy", "A collection sync is in progress.")
                if not STATE.has_collection:
                    return self.error(404, "no_collection", "No collection on this device yet.")
            if p == "/flag":
                cid, flag = body.get("card_id"), body.get("flag")
                if not isinstance(cid, int) or flag not in range(0, 8):
                    return self.error(400, "bad_request", "card_id (int) and flag (0-7) are required")
                for c in STATE.cards:
                    if c["id"] == cid:
                        c["flag"] = flag
                return self.send_json(200, {"ok": True, "flag": flag})
            if p == "/deck/select":
                did = body.get("id")
                if did not in [d[0] for d in DECKS]:
                    return self.error(400, "bad_request", "No such deck: %r" % (did,))
                STATE.current_deck = did
                return self.send_json(200, {"ok": True})
            if p == "/answer":
                cid, rating, ms = body.get("card_id"), body.get("rating"), body.get("ms_taken")
                if not isinstance(cid, int) or rating not in (1, 2, 3, 4) or not isinstance(ms, int):
                    return self.error(400, "bad_request",
                                      "card_id (int), rating (1-4) and ms_taken (int) are required; got %r"
                                      % (body,))
                sys.stderr.write("  answer card %d rating %d after %d ms\n" % (cid, rating, ms))
                if not STATE.answer(cid, rating):
                    return self.error(400, "bad_request", "Card %d is not in the queue." % cid)
                return self.send_json(200, STATE.next_body(self.img_max(q)))
            if p == "/undo":
                if not STATE.undo():
                    return self.error(400, "bad_request", "Nothing to undo.")
                return self.send_json(200, STATE.next_body(self.img_max(q)))
            if p in ("/bury", "/suspend"):
                cid = body.get("card_id")
                if not isinstance(cid, int):
                    return self.error(400, "bad_request", "card_id (int) is required")
                label = "Bury Card" if p == "/bury" else "Suspend Card"
                if not STATE.remove(cid, label):
                    return self.error(400, "bad_request", "Card %d is not in the queue." % cid)
                return self.send_json(200, STATE.next_body(self.img_max(q)))
        return self.error(404, "bad_request", "No such endpoint: " + url.path)


def watchdog():
    while True:
        time.sleep(5)
        if PARENT_PID:
            try:
                os.kill(PARENT_PID, 0)
            except OSError:
                sys.stderr.write("parent %d gone, exiting\n" % PARENT_PID)
                os._exit(0)
        if time.time() - LAST_REQUEST > 30 * 60:
            sys.stderr.write("idle for 30 min, exiting\n")
            os._exit(0)


def main():
    global STATE, PARENT_PID, ARGS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="serve", choices=["serve", "version"])
    ap.add_argument("--port", type=int, default=47321)
    ap.add_argument("--data-dir", default=None)
    ap.add_argument("--parent-pid", type=int, default=None)
    ap.add_argument("--font-dir", default=None, help="accepted and ignored")
    ap.add_argument("--scenario", default="ready",
                    choices=["ready", "fresh", "no-collection", "full-sync", "sync-error"])
    ap.add_argument("--sync-speed", type=float, default=1.0,
                    help="multiply simulated sync durations (0.1 = ten times faster)")
    ap.add_argument("--write-media", action="store_true")
    ap.add_argument("--shutdown-delay", type=float, default=0.2,
                    help="seconds POST /shutdown takes to reply (closing the collection)")
    ap.add_argument("--exit-delay", type=float, default=0.2,
                    help="seconds the process keeps serving after replying to /shutdown")
    ap.add_argument("--ignore-shutdown", action="store_true")
    args = ap.parse_args()
    ARGS = args
    PARENT_PID = args.parent_pid
    if args.command == "version":
        print(VERSION)
        return 0
    STATE = State(args.scenario, args.sync_speed, args.data_dir)
    if args.write_media and args.data_dir:
        media = os.path.join(args.data_dir, "collection.media")
        os.makedirs(media, exist_ok=True)
        with open(os.path.join(media, "ecg_stemi.png"), "wb") as f:
            f.write(png_bytes(IMAGE_WIDTHS["ecg_stemi.png"], 640, None, solid=(240, 200, 200)))
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as e:
        sys.stderr.write("port %d unavailable (%s): another kanki is running\n" % (args.port, e))
        return 3
    threading.Thread(target=watchdog, daemon=True).start()
    sys.stderr.write("kanki mock %s on http://127.0.0.1:%d (scenario %s)\n"
                     % (VERSION, args.port, args.scenario))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
