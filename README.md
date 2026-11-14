# KoboAnki

**Anki on your Kobo e-reader.** Review your AnkiWeb flashcards in KOReader and sync straight to AnkiWeb
over Wi-Fi: no computer, no phone, no add-ons needed once it's installed.

It runs Anki's own engine on the Kobo, so scheduling (SM-2 and FSRS), sync and statistics behave exactly
as on desktop Anki and AnkiDroid.

* Your decks with their new / learning / due counts; tap a deck to study.
* Big **Again / Hard / Good / Easy** buttons, or the page-turn buttons (forward = Good, back = Again).
* Pictures in cards, image occlusion, cloze, your note types' styling; tap a picture to see it full screen.
* Undo, bury, suspend, flags; a study timer and Pomodoro; today's stats (also as the sleep screen).
* Brightness and warmth without leaving your cards (☼, or swipe along the screen edge).
* Two-way sync with AnkiWeb, including media. Your password is never stored, only AnkiWeb's sync key.

## What you need

* **A Kobo with [KOReader](https://koreader.rocks/) installed.** Follow KOReader's guide:
  [Installation on Kobo devices](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices).
  KoboAnki is tested on a **Kobo Libra Colour** (firmware 4.46, KOReader v2026.07). Other Kobos with KOReader
  should work too (it's built for 32-bit ARM, like every Kobo), but haven't been tried yet.
* **An [AnkiWeb](https://ankiweb.net) account** (free) with your cards synced to it, and Wi-Fi on the Kobo.
* Optional: **[NickelMenu](https://pgaskin.net/NickelMenu/)**, to start Anki straight from the Kobo's home
  screen menu.

## Install (about 5 minutes)

1. **Download** `KoboAnki-…zip` from the [latest release](https://github.com/aangelo861/KoboAnki/releases/latest)
   and unzip it. You get a folder with `kanki.koplugin`, `NickelMenu/kanki` and `install-macos.sh`.
2. **Connect the Kobo** to your computer with USB and tap **Connect** on the Kobo. It appears as a drive
   called `KOBOeReader`.
3. **Copy `kanki.koplugin`** into `KOBOeReader/.adds/koreader/plugins/`.
   The `.adds` folder is hidden: on a Mac press **Cmd + Shift + .** in Finder to show it; on Windows tick
   *View → Hidden items*. (Updating? Replace the old `kanki.koplugin` folder; your cards are kept elsewhere.)
4. *Optional, with NickelMenu:* copy `NickelMenu/kanki` into `KOBOeReader/.adds/nm/`.
5. **Eject** the Kobo.

**On a Mac you can do steps 3–5 with one command** instead (Terminal, with the Kobo connected):

```sh
bash ~/Downloads/KoboAnki-v0.1.0/install-macos.sh
```

(adjust the path to where you unzipped it). It checks that KOReader is on the Kobo, copies the plugin and
the NickelMenu entry, removes the hidden `._*` files macOS leaves on the Kobo, and ejects it.

## First start

1. Open KOReader (or, with NickelMenu: home screen menu → **Anki**).
2. In KOReader tap the top of the screen → **☰** menu → **Anki** → **Log in**, and enter your AnkiWeb email and
   password.
3. Open **Anki → Decks**. The first sync downloads your collection and then your pictures and sounds in the
   background; a large collection can take a while on the Kobo's Wi-Fi. You can start reviewing as soon as the
   cards are in.

## Using it

| | |
|---|---|
| Open | KOReader → ☰ → **Anki** → Decks (or NickelMenu → **Anki**) |
| Question | tap the card or press either page button to show the answer |
| Answer | tap **Again / Hard / Good / Easy**; page buttons: forward = Good, back = Again (swappable in Settings) |
| Pictures | tap a picture, or **Image** in the top bar: full screen, pinch to zoom, drag to move. Close with **✕**, **Close** or a page button. On an image-occlusion question a tap shows the answer, so use **Image** there |
| Top bar | deck, study time · cards · Pomodoro, counts, **Image**, **☼** light, **Undo**, **☰** (flag, bury, suspend, Pomodoro, sync, back to decks) |
| Light | **☼**, or swipe up/down along the **left edge** (brightness) or **right edge** (warmth) of a card |
| Stats | ☰ → Anki → **Today's stats** (the same screen can be your sleep screen: Anki → Settings) |
| Sync | automatic when you open the deck list and after a session, or **Sync** in the deck list |
| Settings | ☰ → Anki → **Settings**: text size, page buttons, refresh, study timer and Pomodoro, sleep screen, sync, Wi-Fi |

## Good to know

* **Sync is two-way**, as in any Anki app. If AnkiWeb ever asks for a one-way ("full") sync, the Kobo only
  ever *downloads* AnkiWeb's copy; it never overwrites AnkiWeb.
* **Leaving Anki restarts the Kobo** on MediaTek models (Libra Colour, Clara Colour/BW): going back to the
  Kobo's own software from KOReader can crash these devices and remove NickelMenu, so a clean restart is used
  instead. You can turn this off in Anki → Settings.
* Your collection and media live in `KOBOeReader/.adds/kanki/` (plus `auth.json` with the sync key and
  `kanki.log`). Updating or removing the plugin doesn't touch them.
* **Uninstall:** delete `.adds/koreader/plugins/kanki.koplugin`, `.adds/nm/kanki` and, to remove your cards from
  the Kobo too, `.adds/kanki`.
* Close Anki (or KOReader) before connecting the Kobo over USB, so the collection is closed cleanly.

## How it works

* **`kanki/` (Rust):** Anki's own core (`rslib` from Anki 26.09.3) compiled into one static ARM binary that runs
  on the Kobo and serves a small JSON API on 127.0.0.1 to the UI: AnkiWeb login and sync, scheduling, undo,
  bury/suspend/flags, card rendering, statistics.
* **`kanki_html/` (Rust):** makes Anki's card HTML suit KOReader's HTML engine: removes scripts and audio tags,
  flattens image-occlusion masks onto their pictures, sizes images for the screen.
* **`koplugin/kanki.koplugin/` (Lua):** the KOReader plugin: deck list, reviewer, image viewer, timer and
  Pomodoro, stats, sync, login; starts and stops the server.

`DESIGN.md` has the API and design details.

## Building from source

```sh
scripts/fetch-anki.sh                       # Anki 26.09.3 source into vendor/anki, with patches/ applied
PROTOC=$(command -v protoc) cargo build --release -p kanki -p kanki_devsync   # native build + tests' sync server
scripts/build-kobo.sh --small               # ARM build for the Kobo (needs cargo-zigbuild and zig)
scripts/package.sh                          # -> dist/kanki.koplugin (plugin + binary)
scripts/deploy-usb.sh                       # copy to a Kobo mounted over USB
scripts/deploy-ssh.sh --stop-server <ip>    # or over KOReader's SSH server, then restart KOReader
```

Tests run locally against Anki's own sync server, never AnkiWeb: `devtools/e2e.sh`, `devtools/contract_test.py`,
`devtools/sync_loop_test.sh`, and the plugin's Lua tests in `koplugin/devtools/` (see its README).
`devtools/kobo` is a remote control for development (screenshots and taps over KOReader's SSH server).

## Licence

The code in this repository is under the MIT licence (`LICENSE`). The Kobo binary in the releases also
contains Anki's core (© Ankitects Pty Ltd and contributors), which is licensed under the
**GNU AGPL v3** (`LICENSE-AGPL-3.0.txt`); the binary as a whole is therefore distributed under the AGPL v3.
Its complete source is this repository plus Anki 26.09.3 with `patches/anki-26.09.3-kanki.patch`
(`scripts/fetch-anki.sh` puts them together).

KoboAnki is not affiliated with Ankitects, Kobo or the KOReader project.
