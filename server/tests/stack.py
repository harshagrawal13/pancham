"""A throwaway Postgres + PostgREST built from db/migrations, never kamaji.

Everything lives in a temp dir and is gone afterwards. Tests skip (not fail) unless
`brew install postgresql@18 postgrest dbmate` has been run. The roles are made here the way
kamaji-server's add-app makes them, since the migration expects them to exist.
"""

import getpass
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SECRET = "test-secret-test-secret-test-secret-0123456789"
USER = getpass.getuser()


def find(name):
    for d in ("/opt/homebrew/opt/postgresql@18/bin", "/opt/homebrew/bin", "/usr/local/bin"):
        p = Path(d) / name
        if p.exists():
            return str(p)
    return shutil.which(name)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def available():
    return all(find(t) for t in ("initdb", "pg_ctl", "psql", "postgrest", "dbmate"))


class Stack:
    def start(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pn-"))
        self.env = {**os.environ, "LC_ALL": "en_US.UTF-8"}      # macOS postmaster won't start without a locale
        self.pg_port, self.rest_port = free_port(), free_port()
        self.postgrest = None
        try:
            self._run("initdb", "-D", self.tmp / "data", "-U", USER, "-E", "UTF8", "--auth-local=trust",
                      "--auth-host=scram-sha-256", "--no-instructions")
            self._run("pg_ctl", "-D", self.tmp / "data", "-l", self.tmp / "pg.log", "-w", "start", "-o",
                      f"-p {self.pg_port} -k {self.tmp} -c listen_addresses=127.0.0.1")
            self.psql("postgres", "create database pancham", "create role pancham_anon nologin",
                      "create role pancham_authenticator login noinherit password 'test'",
                      "grant pancham_anon to pancham_authenticator",
                      "revoke all on database pancham from public",
                      "grant connect on database pancham to pancham_authenticator")
            self.dbmate("up")
            conf = self.tmp / "postgrest.conf"
            conf.write_text("\n".join([
                f'db-uri = "postgres://pancham_authenticator:test@127.0.0.1:{self.pg_port}/pancham"',
                'db-schemas = "api"', 'db-anon-role = "pancham_anon"', "db-max-rows = 1000",
                'server-host = "127.0.0.1"', f"server-port = {self.rest_port}", 'openapi-mode = "disabled"',
                f'jwt-secret = "{SECRET}"']))
            self.rest_log = open(self.tmp / "postgrest.log", "w")
            self.postgrest = subprocess.Popen([find("postgrest"), str(conf)], stdout=subprocess.DEVNULL,
                                              stderr=self.rest_log, env=self.env)
            self._wait_ready()
        except Exception:
            self.stop()
            raise
        return self

    def stop(self):
        if self.postgrest:
            self.postgrest.terminate()
            self.postgrest.wait(10)
            self.rest_log.close()
        subprocess.run([find("pg_ctl"), "-D", str(self.tmp / "data"), "-m", "fast", "-w", "stop"],
                       env=self.env, capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self, tool, *args):
        return subprocess.run([find(tool), *map(str, args)], env=self.env, check=True,
                              capture_output=True, text=True).stdout

    def psql(self, db, *sql, as_user=None):
        args = ["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", str(self.tmp), "-p", str(self.pg_port),
                "-d", db, "-U", as_user or USER]
        for s in sql:
            args += ["-c", s]
        return self._run("psql", *args)

    def url(self):
        return f"postgres://{USER}@:{self.pg_port}/pancham?socket={self.tmp}&sslmode=disable"

    def dbmate(self, *args):
        return self._run("dbmate", "--url", self.url(), "--migrations-dir", ROOT / "db/migrations",
                         "--no-dump-schema", *args)

    def _wait_ready(self):
        for _ in range(100):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.rest_port}/docs?limit=0", timeout=1).read()
                return
            except urllib.error.HTTPError as e:
                e.close()
                return
            except OSError:
                if self.postgrest.poll() is not None:
                    raise RuntimeError("postgrest exited: " + (self.tmp / "postgrest.log").read_text())
                time.sleep(0.1)
        raise RuntimeError("postgrest never came up")

    def rest(self, method, path, token=None, body=None, headers=None):
        """(status, parsed body) of a request to the throwaway PostgREST."""
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.rest_port}{path}", method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {}),
                     **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                raw = r.read()
                return r.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            with e:
                raw = e.read()
                return e.code, json.loads(raw) if raw else None
