"""Sign-in: the codes, the sessions, the JWTs, and the HTTP routes. No database needed."""

import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import auth as A  # noqa: E402
import server as S  # noqa: E402

SECRET = "test-secret-test-secret-test-secret-0123456789"
OWNER, FRIEND = "owner@example.com", "friend@example.com"


def make_auth(tmp, allowed=(FRIEND,), admins=(OWNER,), name="auth.sqlite"):
    return A.Auth(str(Path(tmp) / name), SECRET, allowed_emails=allowed, admin_emails=admins)


def hmac_sig(signing_input):
    import hashlib
    import hmac
    return hmac.new(SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()


class AuthCore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.auth = make_auth(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.auth.close)

    def test_the_list_fails_closed(self):
        empty = make_auth(self.tmp.name, allowed=(), admins=(), name="empty.sqlite")
        with self.assertRaises(A.AuthError) as cm:
            empty.issue_code(OWNER)
        self.assertEqual(cm.exception.status, 403)
        empty.close()

    def test_an_unlisted_email_gets_no_code(self):
        with self.assertRaises(A.AuthError) as cm:
            self.auth.issue_code("stranger@example.com")
        self.assertEqual((cm.exception.status, cm.exception.code), (403, "email_not_allowed"))

    def test_a_bad_address_is_a_validation_error(self):
        with self.assertRaises(A.AuthError) as cm:
            self.auth.issue_code("not an email")
        self.assertEqual(cm.exception.status, 400)

    def test_a_code_signs_in_once_and_case_does_not_matter(self):
        _, code = self.auth.issue_code(" Owner@Example.com ")
        t = self.auth.verify_code("OWNER@example.com", code)
        self.assertEqual(t["user"]["email"], OWNER)
        self.assertTrue(t["user"]["admin"])
        with self.assertRaises(A.AuthError):
            self.auth.verify_code(OWNER, code)

    def test_the_token_names_the_account_and_whether_it_is_an_admin(self):
        _, code = self.auth.issue_code(FRIEND)
        t = self.auth.verify_code(FRIEND, code)
        claims = A.verify_jwt(t["access_token"], SECRET)
        self.assertEqual(claims["sub"], A.account_id(FRIEND))
        self.assertEqual(claims["role"], "pancham_anon")
        self.assertFalse(claims["admin"])
        self.assertEqual(claims["exp"] - claims["iat"], A.ACCESS_TTL_S)

    def test_the_account_id_depends_only_on_the_email(self):
        self.assertEqual(A.account_id("A@b.co"), A.account_id(" a@B.CO"))
        self.assertNotEqual(A.account_id("a@b.co"), A.account_id("c@b.co"))
        self.assertEqual(A.account_id("owner@example.com"), A.account_id("owner@example.com"))

    def test_a_wrong_code_is_refused_and_ten_wrong_tries_lock_the_address_for_a_while(self):
        _, code = self.auth.issue_code(OWNER, now=1000)
        wrong = "000000" if code != "000000" else "111111"
        for _ in range(A.MAX_FAILS_PER_WINDOW):
            with self.assertRaises(A.AuthError):
                self.auth.verify_code(OWNER, wrong, now=1001)
        with self.assertRaises(A.AuthError):               # locked: even the right one is refused
            self.auth.verify_code(OWNER, code, now=1002)
        self.assertIn("access_token", self.auth.verify_code(OWNER, code, now=1001 + A.FAIL_WINDOW_S + 1))

    def test_asking_for_new_codes_does_not_reset_the_failure_count(self):
        now = 1000.0
        for i in range(A.MAX_FAILS_PER_WINDOW):
            self.auth.issue_code(OWNER, now=now)
            with self.assertRaises(A.AuthError):
                self.auth.verify_code(OWNER, "x", now=now)
            now += A.RESEND_AFTER_S + 1
        _, code = self.auth.issue_code(OWNER, now=now)
        with self.assertRaises(A.AuthError):               # locked out: the right code is refused too
            self.auth.verify_code(OWNER, code, now=now)
        # passing a code on by hand is the way back in
        _, code = self.auth.issue_code(OWNER, now=now, by_hand=True)
        self.assertIn("access_token", self.auth.verify_code(OWNER, code, now=now))

    def test_a_code_expires(self):
        _, code = self.auth.issue_code(OWNER, now=1000)
        with self.assertRaises(A.AuthError):
            self.auth.verify_code(OWNER, code, now=1000 + A.CODE_TTL_S + 1)

    def test_codes_cannot_be_requested_faster_than_once_a_minute(self):
        self.auth.issue_code(OWNER, now=1000)
        with self.assertRaises(A.AuthError) as cm:
            self.auth.issue_code(OWNER, now=1000 + A.RESEND_AFTER_S - 1)
        self.assertEqual(cm.exception.status, 429)
        self.auth.issue_code(OWNER, now=1000 + A.RESEND_AFTER_S + 1)

    def test_asking_for_a_new_code_does_not_invalidate_the_one_the_owner_has(self):
        _, first = self.auth.issue_code(OWNER, now=1000)
        _, second = self.auth.issue_code(OWNER, now=2000)       # e.g. a stranger asking; both go to the owner
        self.assertIn("access_token", self.auth.verify_code(OWNER, first, now=2001))
        with self.assertRaises(A.AuthError):                    # a code works once; signing in clears the rest
            self.auth.verify_code(OWNER, second, now=2002)

    def test_only_the_newest_few_codes_stay_live(self):
        codes = [self.auth.issue_code(OWNER, now=1000 + i * 100)[1] for i in range(A.MAX_LIVE_CODES + 2)]
        oldest, newest = codes[0], codes[-1]
        if oldest not in codes[2:]:
            with self.assertRaises(A.AuthError):
                self.auth.verify_code(OWNER, oldest, now=1000 + 7 * 100)
        self.assertIn("access_token", self.auth.verify_code(OWNER, newest, now=1000 + 7 * 100))

    def test_refresh_keeps_the_same_refresh_token_and_gives_a_new_access_token(self):
        _, code = self.auth.issue_code(OWNER, now=1000)
        t = self.auth.verify_code(OWNER, code, now=1000)
        r = self.auth.refresh(t["refresh_token"], now=5000)
        self.assertEqual(r["refresh_token"], t["refresh_token"])
        self.assertGreater(r["expires_at"], t["expires_at"])

    def test_a_refresh_token_unused_for_ninety_days_is_dead_but_use_slides_the_window(self):
        _, code = self.auth.issue_code(OWNER, now=0)
        t = self.auth.verify_code(OWNER, code, now=0)
        day = 86400
        for d in (80, 160, 240):                           # each within 90 days of the last use
            self.auth.refresh(t["refresh_token"], now=d * day)
        with self.assertRaises(A.AuthError):
            self.auth.refresh(t["refresh_token"], now=(240 + 91) * day)
        with self.assertRaises(A.AuthError):               # and stays dead if the clock goes back
            self.auth.refresh(t["refresh_token"], now=240 * day)

    def test_an_unknown_refresh_token_is_refused(self):
        with self.assertRaises(A.AuthError):
            self.auth.refresh("nope")

    def test_removing_an_email_ends_its_sessions_at_the_next_refresh(self):
        _, code = self.auth.issue_code(FRIEND, now=1000)
        t = self.auth.verify_code(FRIEND, code, now=1000)
        self.auth.allowed.discard(FRIEND)
        with self.assertRaises(A.AuthError):
            self.auth.refresh(t["refresh_token"], now=1001)

    def test_sign_out_ends_only_that_session(self):
        _, c1 = self.auth.issue_code(OWNER, now=1000)
        a = self.auth.verify_code(OWNER, c1, now=1000)
        _, c2 = self.auth.issue_code(OWNER, now=2000)
        b = self.auth.verify_code(OWNER, c2, now=2000)
        self.auth.sign_out(refresh_token=a["refresh_token"])       # no live access token needed
        with self.assertRaises(A.AuthError):
            self.auth.refresh(a["refresh_token"], now=2001)
        self.assertIn("access_token", self.auth.refresh(b["refresh_token"], now=2001))   # the other Mac is still in
        _, c3 = self.auth.issue_code(OWNER)                          # real time, so the access token is live
        c = self.auth.verify_code(OWNER, c3)
        self.auth.sign_out(access_token=c["access_token"])          # access token alone: all of the account's
        for t in (b, c):
            with self.assertRaises(A.AuthError):
                self.auth.refresh(t["refresh_token"])

    def test_jwt_tampering_expiry_and_alg_none_are_rejected(self):
        tok = A.sign_jwt({"sub": "x", "exp": 2000}, SECRET)
        self.assertEqual(A.verify_jwt(tok, SECRET, now=1000)["sub"], "x")
        self.assertIsNone(A.verify_jwt(tok, SECRET, now=2001))
        self.assertIsNone(A.verify_jwt(tok, SECRET + "x", now=1000))
        head, body, sig = tok.split(".")
        forged = A._b64url({"role": "pancham_anon", "sub": "x", "admin": True, "exp": 2000})
        self.assertIsNone(A.verify_jwt(f"{head}.{forged}.{sig}", SECRET, now=1000))
        none_head = A._b64url({"alg": "none", "typ": "JWT"})
        self.assertIsNone(A.verify_jwt(f"{none_head}.{body}.", SECRET, now=1000))

    def test_malformed_tokens_never_raise(self):
        for bad in ("", "a.b", "a.b.c", "....", "x" * 50, None):
            self.assertIsNone(A.verify_jwt(bad, SECRET))
        for header in ([1, 2], "str", 5, None):               # a header that isn't a JSON object
            head = A._b64url(json.dumps(header).encode())
            body = A._b64url({"exp": 9999999999})
            sig = A._b64url(hmac_sig(f"{head}.{body}"))
            self.assertIsNone(A.verify_jwt(f"{head}.{body}.{sig}", SECRET, now=1))
        head, body = A._b64url({"alg": "HS256"}), A._b64url([1, 2])           # claims that aren't an object
        self.assertIsNone(A.verify_jwt(f"{head}.{body}.{A._b64url(hmac_sig(f'{head}.{body}'))}", SECRET, now=1))
        body = A._b64url({"exp": "tomorrow"})
        self.assertIsNone(A.verify_jwt(f"{head}.{body}.{A._b64url(hmac_sig(f'{head}.{body}'))}", SECRET, now=1))

    def test_a_short_secret_is_refused(self):
        with self.assertRaises(ValueError):
            A.Auth(":memory:", "short", allowed_emails=[OWNER])


class Routes(unittest.TestCase):
    """The HTTP surface, on an ephemeral port, with the email sender replaced by a recorder."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.auth = make_auth(self.tmp.name)
        self.sent, self.send_ok = [], True

        def send(to, subject, text):
            self.sent.append((to, subject, text))
            return self.send_ok

        handler = S.make_handler(self.auth, send_email=send, log=lambda m: None)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.auth.close)
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, body=None, headers=None, raw=None):
        req = urllib.request.Request(self.base + path, method="POST",
                                     data=raw if raw is not None else json.dumps(body or {}).encode(),
                                     headers={"Content-Type": "application/json", **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                data = r.read()
                return r.status, json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read() or b"null")

    def code_from_email(self):
        return self.sent[-1][2].split("Your code for Pancham is ")[1][:6]

    def test_the_whole_sign_in_by_email(self):
        status, _ = self.post("/auth/v1/otp", {"email": OWNER})
        self.assertEqual(status, 200)
        self.assertEqual(self.sent[0][0], OWNER)
        self.assertIn("Pancham", self.sent[0][1])
        status, tokens = self.post("/auth/v1/verify", {"email": OWNER, "token": self.code_from_email()})
        self.assertEqual(status, 200)
        self.assertTrue(tokens["user"]["admin"])
        status, again = self.post("/auth/v1/token?grant_type=refresh_token", {"refresh_token": tokens["refresh_token"]})
        self.assertEqual(status, 200)
        self.assertEqual(again["user"]["id"], tokens["user"]["id"])
        status, _ = self.post("/auth/v1/logout", {"refresh_token": tokens["refresh_token"]})
        self.assertEqual(status, 204)
        status, body = self.post("/auth/v1/token?grant_type=refresh_token", {"refresh_token": tokens["refresh_token"]})
        self.assertEqual((status, body["error_code"]), (400, "refresh_token_not_found"))

    def test_a_stranger_is_refused_and_nothing_is_sent(self):
        status, body = self.post("/auth/v1/otp", {"email": "stranger@example.com"})
        self.assertEqual((status, body["error_code"]), (403, "email_not_allowed"))
        self.assertEqual(self.sent, [])

    def test_a_failed_send_is_a_503_but_the_code_still_works_when_passed_on_by_hand(self):
        self.send_ok = False
        status, body = self.post("/auth/v1/otp", {"email": OWNER})
        self.assertEqual((status, body["error_code"]), (503, "email_send_failed"))
        _, code = self.auth.issue_code(OWNER, by_hand=True)
        status, _ = self.post("/auth/v1/verify", {"email": OWNER, "token": code})
        self.assertEqual(status, 200)

    def test_the_wrong_code_is_a_403(self):
        self.post("/auth/v1/otp", {"email": OWNER})
        right = self.code_from_email()
        status, body = self.post("/auth/v1/verify", {"email": OWNER, "token": "000000" if right != "000000" else "111111"})
        self.assertEqual((status, body["error_code"]), (403, "otp_expired"))

    def test_rate_limited_resend_is_a_429(self):
        self.post("/auth/v1/otp", {"email": OWNER})
        status, body = self.post("/auth/v1/otp", {"email": OWNER})
        self.assertEqual((status, body["error_code"]), (429, "over_email_send_rate_limit"))

    def test_hostile_headers_get_an_answer_not_a_hang_or_a_500(self):
        import socket
        host, port = self.httpd.server_address
        for header in ("-1", "abc", "9999999999999999999999"):
            with socket.create_connection((host, port), timeout=5) as c:
                c.sendall(f"POST /auth/v1/otp HTTP/1.1\r\nHost: x\r\nContent-Length: {header}\r\n\r\n".encode())
                reply = c.recv(4096).decode()
            self.assertRegex(reply, r"^HTTP/1.1 (400|413) ", header)
        # a malformed bearer on logout is a clean 204, not a 500
        head = A._b64url(json.dumps([1]).encode())
        self.assertEqual(self.post("/auth/v1/logout", {}, headers={"Authorization": f"Bearer {head}.e30.e30"})[0], 204)

    def test_bad_requests(self):
        self.assertEqual(self.post("/auth/v1/otp", raw=b"{not json")[0], 400)
        self.assertEqual(self.post("/auth/v1/otp", raw=b"[1,2]")[0], 400)
        self.assertEqual(self.post("/auth/v1/otp", raw=b"x" * (S.MAX_BODY + 1))[0], 413)
        self.assertEqual(self.post("/auth/v1/nope")[0], 404)
        self.assertEqual(self.post("/elsewhere")[0], 404)
        self.assertEqual(self.post("/auth/v1/token?grant_type=password", {"email": OWNER})[0], 400)

    def test_health(self):
        with urllib.request.urlopen(self.base + "/health", timeout=5) as r:
            self.assertEqual(json.loads(r.read()), {"ok": True})

    def test_the_server_will_not_start_with_nobody_allowed(self):
        with self.assertRaises(SystemExit):
            S.build({}, data_dir=self.tmp.name, postgrest_conf="/nonexistent", warn=False)

    def test_the_cli_and_the_server_read_the_same_settings(self):
        import os
        import auth_cli
        env_file = Path(self.tmp.name) / ".env"
        env_file.write_text("PANCHAM_ADMIN_EMAILS=from-file@example.com\nPANCHAM_JWT_SECRET=file-secret-file-secret-file-secret-0000\n")
        os.environ["PANCHAM_JWT_SECRET"] = SECRET           # the environment wins over the file
        self.addCleanup(os.environ.pop, "PANCHAM_JWT_SECRET", None)
        self.assertEqual(S.load_env(env_file)["PANCHAM_JWT_SECRET"], SECRET)
        data_dir = Path(self.tmp.name) / "cli-data"
        rc = auth_cli.main(["code", "from-file@example.com", "--data-dir", str(data_dir),
                            "--env-file", str(env_file), "--postgrest-conf", "/nonexistent"])
        self.assertEqual(rc, 0)
        self.assertEqual(oct(data_dir.stat().st_mode & 0o777), "0o700")

    def test_the_env_file_parser(self):
        p = Path(self.tmp.name) / ".env"
        p.write_text('# comment\nA=1\nB = "two words"\n  C=\'x\'\nbad line\nD=a=b\n')
        self.assertEqual(S.load_env_file(p), {"A": "1", "B": "two words", "C": "x", "D": "a=b"})
        self.assertEqual(S.load_env_file(Path(self.tmp.name) / "missing"), {})


if __name__ == "__main__":
    unittest.main()
