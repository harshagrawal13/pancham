#!/usr/bin/env python3
"""A throwaway copy of Pancham's whole backend on this Mac, never kamaji: Postgres built from
db/migrations, PostgREST, and the sign-in server. For the app's integration tests and for trying
the app by hand.

  python3 server/dev_stack.py --admin you@example.com [--allow friend@example.com]

prints one JSON line when it is ready:

  {"auth": "http://127.0.0.1:P", "rest": "http://127.0.0.1:Q", "codes": "/tmp/pn-.../codes"}

then runs until stdin closes or it is interrupted, and deletes everything. Nobody is emailed: the code
a sign-in would have sent is written to <codes>/<email>.txt. To point the app at it, ALWAYS give the run
its own data folder, or it will mix this server's notations into your real cache for the same email:

  open Pancham.app --env PANCHAM_AUTH_URL=http://127.0.0.1:P --env PANCHAM_REST_URL=http://127.0.0.1:Q \\
                   --env PANCHAM_DATA_DIR=/tmp/pancham-dev
"""

import argparse
import json
import re
import signal
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "tests"))
import auth as A  # noqa: E402
import server as S  # noqa: E402
import stack  # noqa: E402


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--admin", action="append", default=[])
    p.add_argument("--allow", action="append", default=[])
    args = p.parse_args(argv)
    if not args.admin and not args.allow:
        sys.exit("give --admin and/or --allow an email, or nobody can sign in")
    if not stack.available():
        sys.exit("needs postgresql@18, postgrest and dbmate: brew install postgresql@18 postgrest dbmate")

    A.RESEND_AFTER_S = 0        # tests sign the same email in on several "devices" in a row
    pg = stack.Stack().start()
    tmp = tempfile.TemporaryDirectory(prefix="pn-auth-")
    codes = Path(tmp.name) / "codes"
    codes.mkdir()
    auth = A.Auth(str(Path(tmp.name) / "auth.sqlite"), stack.SECRET, allowed_emails=args.allow, admin_emails=args.admin)

    def write_code(to, subject, text):
        (codes / (re.sub(r"[^a-z0-9@._-]", "_", to.lower()) + ".txt")).write_text(text.split("Your code for Pancham is ")[1][:6])
        return True

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), S.make_handler(auth, send_email=write_code,
                                                                 log=lambda m: print(m, file=sys.stderr, flush=True)))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(json.dumps({"auth": f"http://127.0.0.1:{httpd.server_address[1]}",
                      "rest": f"http://127.0.0.1:{pg.rest_port}", "codes": str(codes)}), flush=True)

    done = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: done.set())
    signal.signal(signal.SIGINT, lambda *_: done.set())
    threading.Thread(target=lambda: (sys.stdin.read(), done.set()), daemon=True).start()
    try:
        done.wait()
    finally:
        httpd.shutdown()
        auth.close()
        pg.stop()
        tmp.cleanup()


if __name__ == "__main__":
    main()
