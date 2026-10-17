#!/usr/bin/env python3
"""Sign-in by hand, on kamaji, for when email can't reach someone:

  python3 server/auth_cli.py code <email>     print a one-time code (30 minutes, once)
  python3 server/auth_cli.py id <email>       the account id that email signs in as

Resend's sandbox sender delivers only to the Resend account's owner, so until
PANCHAM_AUTH_EMAIL_FROM names a verified domain this is how anyone else gets a code. It writes into
the same auth.sqlite the running server reads (WAL, so both can have it open), and takes the same
--admin / --allow / --data-dir / --postgrest-conf / --env-file flags as server.py, so it can't
disagree with the server about the list or the secret.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import server  # noqa: E402
from auth import AuthError, account_id  # noqa: E402


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("cmd", choices=["code", "id"])
    p.add_argument("email")
    p.add_argument("--data-dir", default=str(server.DEFAULT_DATA))
    p.add_argument("--postgrest-conf", default=str(server.DEFAULT_CONF))
    p.add_argument("--env-file", default=str(server.DEFAULT_ENV))
    p.add_argument("--admin", action="append", default=[])
    p.add_argument("--allow", action="append", default=[])
    args = p.parse_args(argv)
    if args.cmd == "id":
        print(account_id(args.email))
        return 0
    auth, _ = server.build(server.load_env(args.env_file), admin=args.admin, allow=args.allow,
                           data_dir=args.data_dir, postgrest_conf=args.postgrest_conf, warn=False)
    try:
        email, code = auth.issue_code(args.email, by_hand=True)
        print(f"{code}   for {email}: works for 30 minutes, once")
        return 0
    except AuthError as e:
        print(f"✗ {e.message}", file=sys.stderr)
        return 1
    finally:
        auth.close()


if __name__ == "__main__":
    sys.exit(main())
