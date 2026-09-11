"""Reclaim hub KV bridge.

Reuses the local hub client's call() (mTLS), so no credentials or key paths live in this repo.
The value travels on stdin, never on the command line (no 32 KB argument limit).

usage: python hubkv.py <hub client .py> get <key>        exit 3 when the key does not exist
       python hubkv.py <hub client .py> append <key>     lines to append on stdin

append is additive: it reads the current value and writes it back with the new lines added.
If the read fails for any reason other than "not found", nothing is written.
"""
import importlib.util
import json
import sys
import urllib.error


def load(path):
    spec = importlib.util.spec_from_file_location("reclaim_hubclient", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def get(mod, key):
    try:
        body = json.loads(mod.call("GET", "/kv/" + key))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    if isinstance(body, dict):
        if "value" in body:
            return body["value"]
        data = body.get("data")
        if isinstance(data, dict) and "value" in data:
            return data["value"]
    raise RuntimeError("unexpected hub response shape for key " + key)


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    mod, cmd, key = load(argv[1]), argv[2], argv[3]
    if cmd == "get":
        value = get(mod, key)
        if value is None:
            sys.exit(3)
        sys.stdout.write(value)
        return
    if cmd == "append":
        add = sys.stdin.read().lstrip("﻿").strip("\r\n")
        if not add:
            return
        current = get(mod, key)
        new = add if not current else current.rstrip("\r\n") + "\n" + add
        mod.call("PUT", "/kv/" + key, {"value": new})
        print("appended %d line(s); key now holds %d" % (len(add.split("\n")), len(new.split("\n"))))
        return
    sys.exit("unknown command: " + cmd)


main(sys.argv)
