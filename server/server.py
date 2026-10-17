#!/usr/bin/env python3
"""Pancham's sign-in server, on kamaji at pancham.harsh-agrawal.com (8005).

It answers only /auth/v1/*; everything else Pancham does goes straight to PostgREST at
pancham-api.harsh-agrawal.com with the access token this hands out (see auth.py). Cloudflare
Access sits in front of both hostnames and cloudflared checks its token, so this server never
sees a request that Access refused.

  POST /auth/v1/otp                          {email}                -> 200 {}   emails a six-digit code
  POST /auth/v1/verify                       {email, token}         -> 200 {access_token, refresh_token, user, ...}
  POST /auth/v1/token?grant_type=refresh_token  {refresh_token}     -> 200 {access_token, ...}
  POST /auth/v1/logout                       {refresh_token}        -> 204   (or Authorization: Bearer <access>)
  GET  /health                                                      -> 200 ok

Errors are {"error_code": "...", "msg": "..."}.

Who may sign in is the --admin / --allow list. Email goes out through Resend (RESEND_API_KEY) or any SMTP account such as Gmail with an app
password (PANCHAM_SMTP_*), plus PANCHAM_AUTH_EMAIL_FROM, all in server/.env; until a sender domain is verified, Resend delivers only to
the account's owner, and `python3 server/auth_cli.py code <email>` on kamaji passes a code on by hand.
"""

import argparse
import json
import os
import re
import smtplib
import ssl
import sys
from email.message import EmailMessage
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from auth import Auth, AuthError  # noqa: E402

MAX_BODY = 8192
HOME = Path.home()
DEFAULT_DATA = HOME / "Developer/personal/kamaji-data/pancham"
DEFAULT_CONF = HOME / ".config/postgrest/pancham.conf"
DEFAULT_ENV = Path(__file__).resolve().parent / ".env"


def load_env_file(path):
    """KEY=value lines, '#' comments, optional quotes. Missing file: nothing."""
    env = {}
    try:
        text = Path(path).read_text()
    except FileNotFoundError:
        return env
    for line in text.splitlines():
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
        if m and not line.lstrip().startswith("#"):
            v = m.group(2)
            env[m.group(1)] = v[1:-1] if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"" else v
    return env


def load_env(env_file):
    """The settings both server.py and auth_cli.py run with: the env file, overridden by PANCHAM_* and
    RESEND_* in the environment. One function, so the two can't disagree about the list or the secret."""
    return {**load_env_file(env_file),
            **{k: v for k, v in os.environ.items() if k.startswith(("PANCHAM_", "RESEND_"))}}


def resolve_jwt_secret(env, conf_path):
    """The one secret PostgREST also holds: PANCHAM_JWT_SECRET if set (the dev stack), else the
    `jwt-secret` line of pancham's PostgREST conf. Never copied anywhere else."""
    if env.get("PANCHAM_JWT_SECRET"):
        return env["PANCHAM_JWT_SECRET"]
    try:
        m = re.search(r'^\s*jwt-secret\s*=\s*"([^"]+)"', Path(conf_path).read_text(), re.M)
    except FileNotFoundError:
        m = None
    if not m:
        raise SystemExit(f"no jwt-secret in {conf_path} (and no PANCHAM_JWT_SECRET)")
    return m.group(1)


def resend_sender(api_key, sender):
    """send(to, subject, text) -> bool, through Resend's HTTP API."""
    def send(to, subject, text):
        req = urllib.request.Request(
            "https://api.resend.com/emails",
            data=json.dumps({"from": sender, "to": [to], "subject": subject, "text": text}).encode(),
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
                     # Cloudflare, which fronts Resend, refuses Python-urllib's default User-Agent.
                     "User-Agent": "pancham-server/1"},
            method="POST")
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return 200 <= r.status < 300
        except (urllib.error.URLError, TimeoutError, OSError):
            return False
    return send


def smtp_sender(host, port, user, password, sender, tls=True):
    """send(to, subject, text) -> bool, over plain SMTP: works with a Gmail account and an app password
    (smtp.gmail.com:587), or any other mail provider. STARTTLS unless `tls` is off (tests only)."""
    def send(to, subject, text):
        msg = EmailMessage()
        msg["From"], msg["To"], msg["Subject"] = sender, to, subject
        msg.set_content(text)
        try:
            with smtplib.SMTP(host, port, timeout=15) as s:
                if tls:
                    s.starttls(context=ssl.create_default_context())
                if user:
                    s.login(user, password)
                s.send_message(msg)
            return True
        except (smtplib.SMTPException, OSError):
            return False
    return send


def mask(email):
    return re.sub(r"^(.).*(@.*)$", r"\1…\2", email)


def make_handler(auth, *, send_email, log):
    class Handler(BaseHTTPRequestHandler):
        server_version = "pancham"
        protocol_version = "HTTP/1.1"
        timeout = 15            # a connection that goes quiet is dropped, not kept for a thread forever

        def log_message(self, fmt, *args):          # one line per request, no query strings
            log(f"{self.command} {self.path.split('?')[0]} -> {args[1] if len(args) > 1 else ''}")

        def _send(self, status, body=None):
            data = b"" if body is None else json.dumps(body).encode()
            self.send_response(status)
            if status != 204:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            if status >= 400:
                # An error may leave a request body unread; don't try to parse it as the next request.
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            self.wfile.write(data)

        def _body(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                raise AuthError(400, "validation_failed", "bad Content-Length")
            if n < 0:
                raise AuthError(400, "validation_failed", "bad Content-Length")
            if n > MAX_BODY:
                raise AuthError(413, "payload_too_large", "request too large")
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                raise AuthError(400, "validation_failed", "body must be JSON")
            if not isinstance(body, dict):
                raise AuthError(400, "validation_failed", "body must be a JSON object")
            return body

        def do_GET(self):
            if self.path == "/health":
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error_code": "not_found", "msg": "not found"})

        def do_POST(self):
            u = urllib.parse.urlparse(self.path)
            try:
                if not u.path.startswith("/auth/v1/"):
                    raise AuthError(404, "not_found", "not found")
                route = u.path[len("/auth/v1/"):]
                body = self._body()
                bearer = re.sub(r"^Bearer\s+", "", self.headers.get("Authorization", ""), flags=re.I)
                if route == "logout":
                    auth.sign_out(access_token=bearer or None, refresh_token=body.get("refresh_token"))
                    return self._send(204)
                if route == "otp":
                    email, code = auth.issue_code(body.get("email"))
                    sent = bool(send_email) and send_email(
                        email, f"Your Pancham code: {code}",
                        f"Your code for Pancham is {code}\n\nIt works for 30 minutes, once. "
                        "If you didn't ask for it, ignore this email.\n\n— Pancham")
                    log(f"sign-in code for {mask(email)}: "
                        + ("emailed" if sent else "NOT emailed; run `python3 server/auth_cli.py code <email>` on kamaji"))
                    if not sent:
                        raise AuthError(503, "email_send_failed", "Couldn't send the email. Ask the administrator for a code.")
                    return self._send(200, {})
                if route == "verify":
                    return self._send(200, auth.verify_code(body.get("email"), body.get("token")))
                if route == "token":
                    if u.query and urllib.parse.parse_qs(u.query).get("grant_type") != ["refresh_token"]:
                        raise AuthError(400, "validation_failed", "unsupported grant_type")
                    return self._send(200, auth.refresh(body.get("refresh_token")))
                raise AuthError(404, "not_found", "not found")
            except AuthError as e:
                self._send(e.status, {"error_code": e.code, "msg": e.message})
            except Exception as e:                       # never leak internals to the caller
                log(f"error: {type(e).__name__}: {e}")
                self._send(500, {"error_code": "server_error", "msg": "Something went wrong."})

    return Handler


def build(env, *, admin=(), allow=(), data_dir, postgrest_conf, warn=True):
    """The Auth and the email sender, from explicit settings (the command line and the env file)."""
    admins = [e for e in (list(admin) + env.get("PANCHAM_ADMIN_EMAILS", "").split(",")) if e.strip()]
    allowed = [e for e in (list(allow) + env.get("PANCHAM_AUTH_EMAILS", "").split(",")) if e.strip()]
    if not admins and not allowed:
        raise SystemExit("no --admin or --allow emails: nobody could sign in")
    data_dir = Path(data_dir).expanduser()
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    data_dir.chmod(0o700)         # codes' hashes and sessions live here: nobody else on the Mac reads it
    send = None
    if env.get("RESEND_API_KEY") and env.get("PANCHAM_AUTH_EMAIL_FROM"):
        send = resend_sender(env["RESEND_API_KEY"], env["PANCHAM_AUTH_EMAIL_FROM"])
    elif env.get("PANCHAM_SMTP_HOST") and env.get("PANCHAM_AUTH_EMAIL_FROM"):
        send = smtp_sender(env["PANCHAM_SMTP_HOST"], int(env.get("PANCHAM_SMTP_PORT") or 587),
                           env.get("PANCHAM_SMTP_USER", ""), env.get("PANCHAM_SMTP_PASSWORD", ""),
                           env["PANCHAM_AUTH_EMAIL_FROM"], tls=env.get("PANCHAM_SMTP_TLS", "1") != "0")
    elif warn:
        print("warning: no email provider set (RESEND_API_KEY, or PANCHAM_SMTP_HOST) with PANCHAM_AUTH_EMAIL_FROM; "
              "codes can only be passed on by hand", file=sys.stderr)
    auth = Auth(str(data_dir / "auth.sqlite"), resolve_jwt_secret(env, postgrest_conf),
                allowed_emails=allowed, admin_emails=admins)
    return auth, send


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8005)
    p.add_argument("--data-dir", default=str(DEFAULT_DATA), help="where auth.sqlite lives")
    p.add_argument("--postgrest-conf", default=str(DEFAULT_CONF))
    p.add_argument("--env-file", default=str(DEFAULT_ENV))
    p.add_argument("--admin", action="append", default=[], help="an email that may sign in and manage global notations")
    p.add_argument("--allow", action="append", default=[], help="an email that may sign in")
    args = p.parse_args(argv)
    auth, send = build(load_env(args.env_file), admin=args.admin, allow=args.allow,
                       data_dir=args.data_dir, postgrest_conf=args.postgrest_conf)
    httpd = ThreadingHTTPServer((args.host, args.port),
                                make_handler(auth, send_email=send, log=print))
    print(f"pancham sign-in on http://{args.host}:{args.port}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
