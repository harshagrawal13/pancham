"""Sign-in for Pancham: one-time codes by email, long-lived sessions, and the short-lived
JWTs that PostgREST checks itself.

Ported from jiji's server/auth.js, which has run the same design on kamaji since October.
The one-time code goes to the person's email; they type it into the app; the app gets

  * an access token: an HS256 JWT, an hour long, signed with the `jwt-secret` PostgREST
    also holds. Row level security reads who is asking, and whether they are an admin,
    from its claims (db/migrations/*_init.sql, "Who is asking");
  * a refresh token: the session itself, 90 days from its last use.

State here is DISPOSABLE on purpose. An account's id is not stored: it is derived from the
email (a UUIDv5), so the notations in Postgres belong to an email address and survive losing
this file entirely. What lives here is only codes in flight and refresh tokens; losing them
means signing in again.

Who may sign in is a list given at start-up, never a table: an empty list lets nobody in.
Stdlib only.
"""

import base64
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import threading
import time
import uuid

# Fixed forever: changing it would change every account's id and orphan every notation.
ACCOUNT_NAMESPACE = uuid.UUID("395c186a-7971-4122-b7fd-d34c213344e6")
ACCESS_TTL_S = 3600
CODE_TTL_S = 30 * 60
RESEND_AFTER_S = 60
# Wrong tries are counted per EMAIL, not per code (asking for a new code mustn't reset them). Ten a
# quarter of an hour is 40 guesses an hour against a million codes; the window is short so that
# someone hammering an address can't keep its owner locked out for long.
FAIL_WINDOW_S = 15 * 60
MAX_FAILS_PER_WINDOW = 10
# A few codes can be live at once, so a stranger asking for codes can't invalidate the one the
# owner just received (every one of them is emailed to the owner anyway).
MAX_LIVE_CODES = 5
# A refresh token unused for this long is dead. It SLIDES: each refresh starts the window again,
# so a Mac that opens Pancham now and then never signs out; one left in a drawer stops working.
REFRESH_TTL_S = 90 * 86400
PRUNE_EVERY_S = 3600
PRUNE_KEEP_S = 86400
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class AuthError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def normalize_email(raw):
    return str(raw or "").strip().lower()


def account_id(email):
    return str(uuid.uuid5(ACCOUNT_NAMESPACE, normalize_email(email)))


def _b64url(data):
    if not isinstance(data, bytes):
        data = json.dumps(data, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64url(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def sign_jwt(claims, secret):
    """An HS256 JWT PostgREST accepts. `role` is always pancham_anon: the database tells
    people apart by the other claims, never by extra Postgres roles."""
    head = _b64url({"alg": "HS256", "typ": "JWT"}) + "." + _b64url({"role": "pancham_anon", **claims})
    sig = hmac.new(secret.encode(), head.encode(), hashlib.sha256).digest()
    return head + "." + _b64url(sig)


def verify_jwt(token, secret, now=None):
    """The claims of a token we signed and that has not expired, else None."""
    try:
        head_b64, body_b64, sig_b64 = str(token).split(".")
        head = json.loads(_unb64url(head_b64))
        if not isinstance(head, dict) or head.get("alg") != "HS256":
            return None
        want = hmac.new(secret.encode(), f"{head_b64}.{body_b64}".encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(want, _unb64url(sig_b64)):
            return None
        claims = json.loads(_unb64url(body_b64))
        if not isinstance(claims, dict) or not isinstance(claims.get("exp"), (int, float)):
            return None
        return claims if claims["exp"] > (now if now is not None else time.time()) else None
    except Exception:           # anything malformed (bad base64, bad JSON, wrong shape) is just "no"
        return None


def _hash(s):
    return hashlib.sha256(s.encode()).hexdigest()


class Auth:
    def __init__(self, db_file, secret, allowed_emails=(), admin_emails=()):
        if len(secret or "") < 32:
            raise ValueError("auth: the JWT secret must be at least 32 characters")
        self.secret = secret
        self.admins = {normalize_email(e) for e in admin_emails if normalize_email(e)}
        # An admin may always sign in. An empty list lets NOBODY in (jiji's lets everybody in; a
        # private app should fail closed).
        self.allowed = {normalize_email(e) for e in allowed_emails if normalize_email(e)} | self.admins
        self.lock = threading.Lock()
        self.db = sqlite3.connect(db_file, check_same_thread=False, isolation_level=None)
        self.db.executescript("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS otp_codes (
                email TEXT NOT NULL, code_hash TEXT NOT NULL, expires_at REAL NOT NULL, sent_at REAL NOT NULL,
                PRIMARY KEY (email, code_hash));
            CREATE TABLE IF NOT EXISTS otp_failures (
                email TEXT PRIMARY KEY, fails INTEGER NOT NULL, since REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS sessions (
                refresh_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, email TEXT NOT NULL,
                last_used REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);""")
        self.last_prune = 0.0

    def close(self):
        self.db.close()

    def is_allowed(self, email):
        return email in self.allowed

    def is_admin(self, email):
        return email in self.admins

    def _prune(self, now):
        """Remove what can never be used again, at most once an hour."""
        if now - self.last_prune < PRUNE_EVERY_S:
            return
        self.last_prune = now
        self.db.execute("DELETE FROM sessions WHERE (revoked = 1 AND last_used < ?) OR last_used < ?",
                        (now - PRUNE_KEEP_S, now - REFRESH_TTL_S - PRUNE_KEEP_S))

    # --- codes ------------------------------------------------------------------
    def issue_code(self, raw_email, now=None, by_hand=False):
        """A new six-digit code for an allowed email. `by_hand`: auth_cli.py on kamaji, for when
        email can't reach someone; it skips the resend limit and clears a lockout."""
        now = time.time() if now is None else now
        email = normalize_email(raw_email)
        if not EMAIL_RE.match(email):
            raise AuthError(400, "validation_failed", "That doesn't look like an email address.")
        if not self.is_allowed(email):
            raise AuthError(403, "email_not_allowed", "That email isn't on the list for Pancham.")
        with self.lock:
            last = self.db.execute("SELECT MAX(sent_at) FROM otp_codes WHERE email = ?", (email,)).fetchone()[0]
            if not by_hand and last is not None and now - last < RESEND_AFTER_S:
                raise AuthError(429, "over_email_send_rate_limit", "Too many codes too quickly. Give it a minute.")
            if by_hand:
                self.db.execute("DELETE FROM otp_failures WHERE email = ?", (email,))
            code = f"{secrets.randbelow(1_000_000):06d}"
            self.db.execute("DELETE FROM otp_codes WHERE email = ? AND expires_at < ?", (email, now))
            self.db.execute(
                """DELETE FROM otp_codes WHERE email = ? AND code_hash NOT IN
                   (SELECT code_hash FROM otp_codes WHERE email = ? ORDER BY sent_at DESC LIMIT ?)""",
                (email, email, MAX_LIVE_CODES - 1))
            self.db.execute("INSERT OR REPLACE INTO otp_codes (email, code_hash, expires_at, sent_at) VALUES (?, ?, ?, ?)",
                            (email, _hash(f"{email}:{code}"), now + CODE_TTL_S, now))
        return email, code

    def verify_code(self, raw_email, code, now=None):
        now = time.time() if now is None else now
        email = normalize_email(raw_email)

        def fail():
            return AuthError(403, "otp_expired", "That code has expired or is wrong.")

        with self.lock:
            live = [r[0] for r in self.db.execute(
                "SELECT code_hash FROM otp_codes WHERE email = ? AND expires_at >= ?", (email, now))]
            if not live:
                raise fail()
            failed = self.db.execute("SELECT fails, since FROM otp_failures WHERE email = ?", (email,)).fetchone()
            recent = failed and now - failed[1] < FAIL_WINDOW_S
            if recent and failed[0] >= MAX_FAILS_PER_WINDOW:
                raise fail()                      # locked: even the right code is refused until the window passes
            tried = _hash(f"{email}:{str(code or '').strip()}")
            if not any([hmac.compare_digest(h, tried) for h in live]):        # no short-circuit on the first match
                if recent:
                    self.db.execute("UPDATE otp_failures SET fails = fails + 1 WHERE email = ?", (email,))
                else:
                    self.db.execute("INSERT OR REPLACE INTO otp_failures (email, fails, since) VALUES (?, 1, ?)",
                                    (email, now))
                raise fail()
            self.db.execute("DELETE FROM otp_codes WHERE email = ?", (email,))
            self.db.execute("DELETE FROM otp_failures WHERE email = ?", (email,))
            # A code is only ever issued to an allowed email, but the list may have changed since.
            if not self.is_allowed(email):
                raise fail()
            return self._start_session(email, now)

    # --- sessions ---------------------------------------------------------------
    def _start_session(self, email, now):
        self._prune(now)
        refresh = secrets.token_urlsafe(32)
        self.db.execute("INSERT INTO sessions (refresh_hash, user_id, email, last_used) VALUES (?, ?, ?, ?)",
                        (_hash(refresh), account_id(email), email, now))
        return self._tokens(email, refresh, now)

    def _tokens(self, email, refresh, now):
        uid, admin, now_s = account_id(email), self.is_admin(email), int(now)
        return {
            "access_token": sign_jwt({"sub": uid, "email": email, "admin": admin,
                                      "iat": now_s, "exp": now_s + ACCESS_TTL_S}, self.secret),
            "token_type": "bearer",
            "expires_in": ACCESS_TTL_S,
            "expires_at": now_s + ACCESS_TTL_S,
            "refresh_token": refresh,
            "user": {"id": uid, "email": email, "admin": admin},
        }

    def refresh(self, refresh_token, now=None):
        """A new access token for a session, and the SAME refresh token back. It is not rotated:
        rotation made a refresh whose answer never arrived (a dropped connection, a crash) leave the
        app holding a spent token, which signs the person out. What rotation buys, noticing a stolen
        token, is not a threat a private app has; sign-out, the list and the 90 days still end one."""
        now = time.time() if now is None else now
        h = _hash(refresh_token or "")

        def fail():
            return AuthError(400, "refresh_token_not_found", "Invalid refresh token")

        with self.lock:
            s = self.db.execute("SELECT user_id, email, last_used, revoked FROM sessions WHERE refresh_hash = ?",
                                (h,)).fetchone()
            if not s or s[3]:
                raise fail()
            if now - s[2] > REFRESH_TTL_S:
                self.db.execute("UPDATE sessions SET revoked = 1 WHERE refresh_hash = ?", (h,))
                raise fail()
            # The list is asked again here, not only when a code is sent: taking an address off it
            # ends every session that account holds, on every device, at its next refresh.
            if not self.is_allowed(s[1]):
                self.db.execute("UPDATE sessions SET revoked = 1 WHERE user_id = ?", (s[0],))
                raise fail()
            self.db.execute("UPDATE sessions SET last_used = ? WHERE refresh_hash = ?", (now, h))
            return self._tokens(s[1], refresh_token, now)

    def sign_out(self, access_token=None, refresh_token=None):
        """End ONE session: the one whose refresh token is given, so signing out on one Mac leaves the
        others signed in. (With only an access token there is no way to tell which session it came
        from, so that ends all of the account's.) The access token itself dies at its expiry:
        PostgREST checks signatures, not a revocation list."""
        with self.lock:
            if refresh_token:
                self.db.execute("UPDATE sessions SET revoked = 1 WHERE refresh_hash = ?", (_hash(refresh_token),))
                return
            user_id = (verify_jwt(access_token, self.secret) or {}).get("sub") if access_token else None
            if user_id:
                self.db.execute("UPDATE sessions SET revoked = 1 WHERE user_id = ?", (user_id,))
