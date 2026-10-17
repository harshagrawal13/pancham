#!/usr/bin/env python3
"""One-off: put a folder of .pancham notations into your cloud account.

  python3 server/import_notations.py ~/Documents/Pancham --email you@example.com

Signs in the way the app does (it emails a code, you type it), then saves each notation as a new
private notation named after its file, in the folder it sits in. Anything already there (same folder
and name) is skipped, so running it twice is harmless. Nothing is read from or written to the repo,
and the originals are not touched. Set CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET if the server
is behind a Cloudflare Access service token.
"""

import argparse
import getpass
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

DEFAULT_AUTH = "https://pancham.harsh-agrawal.com"
DEFAULT_REST = "https://pancham-api.harsh-agrawal.com"


def _call(method, url, body=None, token=None, extra=None):
    headers = {"Content-Type": "application/json", "User-Agent": "pancham-import/1", **(extra or {})}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, method=method, headers=headers,
                                 data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        with e:
            raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"message": raw[:200].decode(errors="replace")}


def access_headers():
    cid, secret = os.environ.get("CF_ACCESS_CLIENT_ID"), os.environ.get("CF_ACCESS_CLIENT_SECRET")
    return {"CF-Access-Client-Id": cid, "CF-Access-Client-Secret": secret} if cid and secret else {}


def notation_files(folder):
    """(path, folder name) for notations at the top of `folder` and one level down. Backups
    (.bak*) and other extensions are ignored."""
    folder = Path(folder).expanduser()
    out = []
    for item in sorted(folder.iterdir()):
        if item.name.startswith("."):
            continue
        if item.is_dir():
            out += [(f, item.name) for f in sorted(item.iterdir()) if f.suffix.lower() in (".pancham", ".json")]
        elif item.suffix.lower() in (".pancham", ".json"):
            out.append((item, ""))
    return out


def import_folder(rest_url, token, folder, extra=None, say=print):
    """Save each notation not already in the account. Returns (imported, skipped, failed)."""
    code, existing = _call("GET", f"{rest_url}/docs?select=name,folder,deleted", token=token, extra=extra)
    if code != 200:
        raise SystemExit(f"couldn't list your notations ({code}): {existing}")
    have = {(d["folder"], d["name"]) for d in existing if not d["deleted"]}
    imported = skipped = failed = 0
    for path, sub in notation_files(folder):
        name = path.stem
        if (sub, name) in have:
            skipped += 1
            say(f"  skip    {sub + '/' if sub else ''}{name} (already there)")
            continue
        try:
            content = json.loads(path.read_text())
            assert isinstance(content, dict)
        except (ValueError, AssertionError, OSError):
            failed += 1
            say(f"  FAILED  {path.name}: not a notation file")
            continue
        code, body = _call("POST", f"{rest_url}/rpc/save_revision", token=token, extra=extra, body={
            "p_doc": str(uuid.uuid4()), "p_base": 0, "p_name": name, "p_folder": sub, "p_content": content,
            "p_note": "imported from an earlier library"})
        if code == 200:
            imported += 1
            say(f"  added   {sub + '/' if sub else ''}{name}")
        else:
            failed += 1
            say(f"  FAILED  {path.name}: {(body or {}).get('message', code)}")
    return imported, skipped, failed


def sign_in(auth_url, email, extra=None):
    code, body = _call("POST", f"{auth_url}/auth/v1/otp", {"email": email}, extra=extra)
    if code != 200:
        raise SystemExit(f"couldn't send a code: {(body or {}).get('msg', code)}")
    typed = getpass.getpass(f"A code was sent to {email}. Enter it: ").strip()
    code, body = _call("POST", f"{auth_url}/auth/v1/verify", {"email": email, "token": typed}, extra=extra)
    if code != 200:
        raise SystemExit(f"sign-in failed: {(body or {}).get('msg', code)}")
    return body["access_token"]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("folder")
    p.add_argument("--email", required=True)
    p.add_argument("--auth-url", default=DEFAULT_AUTH)
    p.add_argument("--rest-url", default=DEFAULT_REST)
    args = p.parse_args(argv)
    extra = access_headers()
    token = sign_in(args.auth_url.rstrip("/"), args.email, extra)
    i, s, f = import_folder(args.rest_url.rstrip("/"), token, args.folder, extra)
    print(f"done: {i} added, {s} skipped, {f} failed")
    return 1 if f else 0


if __name__ == "__main__":
    sys.exit(main())
