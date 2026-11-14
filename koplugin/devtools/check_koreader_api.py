#!/usr/bin/env python3
"""Static cross-check of the plugin against an installed KOReader (read-only).

    python3 check_koreader_api.py /Volumes/KOBOeReader/.adds/koreader
    python3 check_koreader_api.py --plugin ../other.koplugin KOREADER_DIR   (any other plugin)

1. Every require("...") in kanki.koplugin resolves to a file on KOReader's package.path
   (common/, frontend/, KOReader root; .lua or .so) or to the plugin itself.
2. For `local X = require("koreader/module")`, every `X:name(` / `X.name` used by the plugin is
   defined somewhere in that module's source file or in one of the base classes it extends
   (followed through `local Base = require(...)` + `Base:extend{`). Screen:* is checked against
   the framebuffer and generic device sources.
Prints anything it can't find; exit status 1 if so.
"""

import os
import re
import sys

PLUGIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kanki.koplugin")
# --plugin DIR checks another plugin (e.g. ../other.koplugin); its own modules are required as
# "<name>/..." where <name> is the folder name without ".koplugin" (kanki/, other/).
if "--plugin" in sys.argv:
    i = sys.argv.index("--plugin")
    PLUGIN = os.path.abspath(sys.argv[i + 1])
    del sys.argv[i:i + 2]
PREFIX = os.path.basename(PLUGIN.rstrip("/")).replace(".koplugin", "") + "/"
GENERIC = {"new", "extend", "init", "free", "paintTo", "getSize", "handleEvent", "_init"}
# Modules whose real implementation lives elsewhere (device.lua returns the per-platform Device object).
EXTRA_SOURCES = {
    "device": ["frontend/device/generic/device.lua", "frontend/device/kobo/device.lua"],
}
# Defined in C (LuaSocket core) or as `_M.X` module fields the regexes don't see.
KNOWN = {("socket", "skip"), ("socket", "gettime"), ("socket", "sleep"), ("socket", "tcp"), ("socket.http", "PROXY"), ("socket.http", "TIMEOUT")}
REQ_RE = re.compile(r'local\s+(\w+)\s*=\s*require\("([^"]+)"\)')
USE_RE = re.compile(r'\b(\w+)([:.])([A-Za-z_]\w*)')


def resolve(root, mod):
    if mod in ("ffi", "bit", "jit"):
        return "builtin"
    rel = mod.replace(".", "/") if "/" not in mod else mod
    if mod.startswith(PREFIX):
        p = os.path.join(PLUGIN, mod + ".lua")
        return p if os.path.exists(p) else None
    for base in ("common", "frontend", ""):
        for ext in (".lua", ".so"):
            p = os.path.join(root, base, rel + ext)
            if os.path.exists(p):
                return p
        p = os.path.join(root, base, rel, "init.lua")
        if os.path.exists(p):
            return p
    return None


def defined_names(root, path, seen=None):
    """Names defined in a KOReader module, following `X:extend{` base classes."""
    seen = seen or set()
    if path in seen or not path or not path.endswith(".lua"):
        return set()
    seen.add(path)
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return set()
    names = set(re.findall(r'function\s+[\w.]+[:.](\w+)\s*\(', src))
    names |= set(re.findall(r'^\s*(\w+)\s*=', src, re.M))          # table fields
    names |= set(re.findall(r'[\w\]]\.(\w+)\s*=', src))              # X.name = ...
    names |= set(re.findall(r'\[\s*"(\w+)"\s*\]\s*=', src))
    reqs = dict(REQ_RE.findall(src))
    for base in re.findall(r'(\w+):extend\s*[{(]', src):
        if base in reqs:
            names |= defined_names(root, resolve(root, reqs[base]), seen)
    return names


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "/Volumes/KOBOeReader/.adds/koreader"
    problems = []
    screen_names = set()
    for f in ("ffi/framebuffer.lua", "ffi/framebuffer_mxcfb.lua", "frontend/device/generic/device.lua"):
        screen_names |= defined_names(root, os.path.join(root, f))
    screen_names |= set(re.findall(r'self\.screen\.(\w+)\s*=',
                                   open(os.path.join(root, "frontend/device/generic/device.lua")).read()))
    for dirpath, _, files in os.walk(PLUGIN):
        for fn in files:
            if not fn.endswith(".lua"):
                continue
            path = os.path.join(dirpath, fn)
            src = open(path, encoding="utf-8").read()
            code = re.sub(r'--\[\[.*?\]\]', "", src, flags=re.S)
            code = re.sub(r'--[^\n]*', "", code)
            code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
            rel = os.path.relpath(path, PLUGIN)
            reqs = dict(REQ_RE.findall(src))
            for var, mod in reqs.items():
                if resolve(root, mod) is None:
                    problems.append("%s: require(%r) does not resolve" % (rel, mod))
            for m in re.finditer(r'require\("([^"]+)"\)', src):
                if resolve(root, m.group(1)) is None:
                    problems.append("%s: require(%r) does not resolve" % (rel, m.group(1)))
            cache = {}
            for var, sep, name in USE_RE.findall(code):
                if name in GENERIC:
                    continue
                if var == "Screen":
                    if name not in screen_names:
                        problems.append("%s: Screen:%s not found in framebuffer/device sources" % (rel, name))
                    continue
                if var not in reqs:
                    continue
                mod = reqs[var]
                target = resolve(root, mod)
                if target in (None, "builtin") or not target.endswith(".lua"):
                    continue
                if (mod, name) in KNOWN:
                    continue
                if target not in cache:
                    cache[target] = defined_names(root, target)
                    for extra in EXTRA_SOURCES.get(mod, []):
                        cache[target] |= defined_names(root, os.path.join(root, extra))
                if name not in cache[target]:
                    problems.append("%s: %s%s%s (from %s) not found" % (rel, var, sep, name, mod))
    for p in sorted(set(problems)):
        print(p)
    print("%d potential problem(s)" % len(set(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
