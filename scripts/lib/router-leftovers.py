#!/usr/bin/env python3
"""
router-leftovers — strip the old bundled 9router's routing from ONE daemon home.

    python3 router-leftovers.py [--check] <home>        (usually /home/paseo)

`make router-on` asked 9router to write its routing straight into the CLIs'
own config, on the daemon's volume, where it outlives the router:

    ~/.claude/settings.json   env.ANTHROPIC_BASE_URL, env.ANTHROPIC_AUTH_TOKEN,
                              env.ANTHROPIC_DEFAULT_*_MODEL
    ~/.codex/config.toml      model_provider = "9router",
                              [model_providers.9router*]

Left there they silently override the AI Router plugin: Claude keeps calling a
router that is gone, and one daemon's Codex answered 401 for hours. This
removes exactly those entries, after a timestamped backup of each file it
changes, and nothing else. It never opens a login file (.credentials.json,
auth.json). A second run finds nothing and writes nothing.

--check reports what it would remove and exits 1 if anything is left.
Runs inside the container (python3 - <home> < this file) on Python 3.8+.
"""

import json
import os
import re
import shutil
import sys
import time

CLAUDE_KEYS = ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN")
CLAUDE_MODEL_RE = re.compile(r"^ANTHROPIC_DEFAULT_[A-Z0-9_]+_MODEL$")

# A TOML table header, e.g. [model_providers.9router] or [[x]]. Anchored to the
# whole line so an array value continuing onto a line like `  [1, 2],` is not
# mistaken for one.
TABLE_RE = re.compile(r"""^\s*\[\[?\s*[A-Za-z0-9_."'-]+\s*\]\]?\s*(#.*)?$""")
ROUTER_TABLE_RE = re.compile(r"""^\s*\[\s*model_providers\.["']?9router[^\]]*\]\s*(#.*)?$""")
ROUTER_PROVIDER_RE = re.compile(r"""^\s*model_provider\s*=\s*["']9router["']\s*(#.*)?$""")
COMMENT_OR_BLANK_RE = re.compile(r"^\s*(#.*)?$")


def strip_claude(text):
    """Return (new_text, removed_keys, base_url). new_text is None when the
    file is not a JSON object we can safely edit."""
    try:
        doc = json.loads(text)
    except ValueError:
        return None, [], ""
    if not isinstance(doc, dict):
        return None, [], ""
    env = doc.get("env")
    if not isinstance(env, dict):
        return text, [], ""
    base_url = str(env.get("ANTHROPIC_BASE_URL", ""))
    removed = [k for k in list(env) if k in CLAUDE_KEYS or CLAUDE_MODEL_RE.match(k)]
    if not removed:
        return text, [], ""
    for k in removed:
        del env[k]
    if not env:
        del doc["env"]
    return (json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
            ["env." + k for k in removed], base_url)


def strip_codex(text):
    """Return (new_text, removed_items). Line-based: there is no TOML writer in
    the standard library, and a rewrite through one would reformat the file."""
    out, removed, held = [], [], []
    skipping = False
    for line in text.splitlines(keepends=True):
        if TABLE_RE.match(line):
            if ROUTER_TABLE_RE.match(line):
                skipping = True
                held = []            # comments above it belonged to it
                removed.append(line.strip())
                continue
            skipping = False
            out.extend(held)         # comments above the NEXT table stay
            held = []
            out.append(line)
            continue
        if skipping:
            if COMMENT_OR_BLANK_RE.match(line):
                held.append(line)
            else:
                held = []            # a key of the removed table
            continue
        if ROUTER_PROVIDER_RE.match(line):
            removed.append('model_provider = "9router"')
            continue
        out.append(line)
    if skipping:
        out.extend(held)
    return "".join(out), removed


def rewrite(path, new_text, stamp):
    """Back up, then replace atomically, keeping the file's mode."""
    backup = f"{path}.bak.{stamp}"
    shutil.copy2(path, backup)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
    return os.path.basename(backup)


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    home = args[0] if args else os.path.expanduser("~")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    found = False

    targets = (
        (os.path.join(home, ".claude", "settings.json"), "~/.claude/settings.json"),
        (os.path.join(home, ".codex", "config.toml"), "~/.codex/config.toml"),
    )
    for path, label in targets:
        if not os.path.isfile(path):
            print(f"  {label:<26} absent")
            continue
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if path.endswith(".json"):
            new_text, removed, base_url = strip_claude(text)
            if new_text is None:
                print(f"  {label:<26} not a JSON object; left alone, check it by hand")
                continue
            note = f" (was {base_url})" if base_url else ""
        else:
            new_text, removed = strip_codex(text)
            note = ""
        if not removed:
            print(f"  {label:<26} clean")
            continue
        found = True
        what = ", ".join(removed) + note
        if check:
            print(f"  {label:<26} WOULD remove {what}")
        else:
            backup = rewrite(path, new_text, stamp)
            print(f"  {label:<26} removed {what}  (backup: {backup})")
    return 1 if (check and found) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
