"""The API contract against a real Postgres and PostgREST built from db/migrations, never kamaji.

Skips unless `brew install postgresql@18 postgrest dbmate` has been run.
"""

import subprocess
import sys
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import auth as A  # noqa: E402
import stack  # noqa: E402

ALICE, BOB, ADMIN = "alice@example.com", "bob@example.com", "admin@example.com"


def token(email, admin=False, exp_in=3600):
    now = int(time.time())
    return A.sign_jwt({"sub": A.account_id(email), "email": email, "admin": admin, "iat": now, "exp": now + exp_in},
                      stack.SECRET)


def comp(title="Yaman", cells=("S", "R")):
    return {"title": title, "raga": "Yaman", "sections": [{"name": "Sthayi", "lines": [{"type": "notation", "cells": list(cells)}]}]}


@unittest.skipUnless(stack.available(), "needs postgresql@18, postgrest and dbmate (brew install ...)")
class Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = stack.Stack().start()
        cls.alice, cls.bob, cls.admin = token(ALICE), token(BOB), token(ADMIN, admin=True)

    @classmethod
    def tearDownClass(cls):
        cls.s.stop()

    def save(self, tok, doc, base, name="Yaman", folder="", content=None, **kw):
        body = {"p_doc": doc, "p_base": base, "p_name": name, "p_folder": folder,
                "p_content": content if content is not None else comp(), **kw}
        return self.s.rest("POST", "/rpc/save_revision", tok, body)

    def new_doc(self, tok, **kw):
        doc = str(uuid.uuid4())
        status, body = self.save(tok, doc, 0, **kw)
        self.assertEqual(status, 200, body)
        return doc

    # --- migrations --------------------------------------------------------------
    def test_migrations_roll_back_and_apply_again(self):
        self.s.dbmate("rollback")
        self.assertIn("Pending: 1", self.s.dbmate("status"))
        self.s.dbmate("up")
        self.assertIn("Pending: 0", self.s.dbmate("status"))
        self.s.psql("pancham", "notify pgrst, 'reload schema'")
        time.sleep(0.5)
        self.assertEqual(self.save(self.alice, str(uuid.uuid4()), 0)[0], 200)

    # --- who gets in -------------------------------------------------------------
    def test_without_a_token_nothing_is_seen_or_written(self):
        self.new_doc(self.admin, p_scope="global")
        self.assertEqual(self.s.rest("GET", "/docs"), (200, []))
        self.assertEqual(self.s.rest("GET", "/revisions"), (200, []))
        status, body = self.save(None, str(uuid.uuid4()), 0)
        self.assertEqual((status, body["message"]), (401, "sign in first"))

    def test_an_expired_or_forged_token_is_refused(self):
        # (PostgREST tolerates about 30 seconds of clock skew, so "expired" means well past that.)
        status, body = self.s.rest("GET", "/docs", token(ALICE, exp_in=-3600))
        self.assertEqual((status, body["code"]), (401, "PGRST303"))
        forged = A.sign_jwt({"sub": A.account_id(ALICE), "admin": True, "exp": int(time.time()) + 99}, "x" * 40)
        self.assertEqual(self.s.rest("GET", "/docs", forged)[0], 401)

    # --- private notations -------------------------------------------------------
    def test_a_notation_is_made_then_changed_and_each_save_is_a_revision(self):
        doc = self.new_doc(self.alice, content=comp(cells=("S",)))
        status, r2 = self.save(self.alice, doc, 1, content=comp(cells=("S", "R")))
        self.assertEqual((status, r2["rev"], r2["changed"]), (200, 2, True))
        _, history = self.s.rest("GET", f"/revisions?doc_id=eq.{doc}&select=rev,seq&order=rev.desc", self.alice)
        self.assertEqual([h["rev"] for h in history], [2, 1])
        self.assertLess(history[1]["seq"], history[0]["seq"])
        _, heads = self.s.rest("GET", f"/docs?id=eq.{doc}", self.alice)
        self.assertEqual((heads[0]["rev"], heads[0]["scope"], heads[0]["content"]["sections"][0]["lines"][0]["cells"]),
                         (2, "private", ["S", "R"]))

    def test_a_delete_or_rename_without_content_keeps_the_content(self):
        doc = self.new_doc(self.alice, name="Keep me", content=comp("Keep me", cells=("S", "R", "G")))
        body = {"p_doc": doc, "p_base": 1, "p_name": "Kept", "p_folder": "", "p_deleted": True}
        status, r = self.s.rest("POST", "/rpc/save_revision", self.alice, body)      # no p_content at all
        self.assertEqual((status, r["rev"]), (200, 2))
        _, head = self.s.rest("GET", f"/docs?id=eq.{doc}&select=name,deleted,content", self.alice)
        self.assertEqual((head[0]["name"], head[0]["deleted"], head[0]["content"]["title"]), ("Kept", True, "Keep me"))
        status, body = self.s.rest("POST", "/rpc/save_revision", self.alice,
                                   {"p_doc": str(uuid.uuid4()), "p_base": 0, "p_name": "x", "p_folder": ""})
        self.assertEqual((status, body["message"]), (400, "content is required to create a notation"))

    def test_saving_what_is_already_there_changes_nothing(self):
        doc = self.new_doc(self.alice)
        status, r = self.save(self.alice, doc, 1)
        self.assertEqual((status, r["rev"], r["changed"]), (200, 1, False))
        _, history = self.s.rest("GET", f"/revisions?doc_id=eq.{doc}&select=rev", self.alice)
        self.assertEqual(len(history), 1)

    def test_a_rename_a_move_and_a_delete_are_revisions_and_a_delete_can_be_undone(self):
        doc = self.new_doc(self.alice, name="Yaman")
        self.assertEqual(self.save(self.alice, doc, 1, name="Raag Yaman")[1]["rev"], 2)
        self.assertEqual(self.save(self.alice, doc, 2, name="Raag Yaman", folder="Evening")[1]["rev"], 3)
        self.assertEqual(self.save(self.alice, doc, 3, name="Raag Yaman", folder="Evening", p_deleted=True)[1]["rev"], 4)
        _, head = self.s.rest("GET", f"/docs?id=eq.{doc}&select=rev,name,folder,deleted", self.alice)
        self.assertEqual(head, [{"rev": 4, "name": "Raag Yaman", "folder": "Evening", "deleted": True}])
        # undo: save the live revision's content again, as a new revision
        _, old = self.s.rest("GET", f"/revisions?doc_id=eq.{doc}&rev=eq.3&select=content", self.alice)
        status, r = self.save(self.alice, doc, 4, name="Raag Yaman", folder="Evening", content=old[0]["content"],
                              p_note="restored from revision 3")
        self.assertEqual((status, r["rev"]), (200, 5))
        _, history = self.s.rest("GET", f"/revisions?doc_id=eq.{doc}&select=rev,deleted,note&order=rev.asc", self.alice)
        self.assertEqual([h["rev"] for h in history], [1, 2, 3, 4, 5])
        self.assertEqual(history[4], {"rev": 5, "deleted": False, "note": "restored from revision 3"})

    def test_a_stale_save_is_a_conflict_that_names_the_newer_revision_and_writes_nothing(self):
        doc = self.new_doc(self.alice)
        self.assertEqual(self.save(self.alice, doc, 1, content=comp(cells=("S", "R", "G")))[0], 200)
        status, body = self.save(self.alice, doc, 1, content=comp(cells=("X",)))
        self.assertEqual((status, body["code"], body["details"]), (409, "PT409", "2"))
        _, history = self.s.rest("GET", f"/revisions?doc_id=eq.{doc}&select=rev", self.alice)
        self.assertEqual(len(history), 2)

    def test_creating_with_a_base_or_changing_a_missing_one_is_a_404(self):
        self.assertEqual(self.save(self.alice, str(uuid.uuid4()), 3)[0], 404)

    def test_bad_input_is_a_400(self):
        self.assertEqual(self.save(self.alice, str(uuid.uuid4()), 0, name="")[0], 400)
        self.assertEqual(self.save(self.alice, str(uuid.uuid4()), 0, name="x" * 201)[0], 400)
        self.assertEqual(self.save(self.alice, str(uuid.uuid4()), 0, content=[1, 2])[0], 400)
        self.assertEqual(self.save(self.alice, str(uuid.uuid4()), 0, p_scope="public")[0], 400)

    def test_a_private_notation_is_invisible_and_untouchable_to_everyone_else(self):
        doc = self.new_doc(self.alice, content=comp("Alice only"))
        for tok in (self.bob, self.admin):                   # even an admin: global is theirs, not private
            self.assertEqual(self.s.rest("GET", f"/docs?id=eq.{doc}", tok), (200, []))
            self.assertEqual(self.s.rest("GET", f"/revisions?doc_id=eq.{doc}", tok), (200, []))
            self.assertEqual(self.save(tok, doc, 1, content=comp("mine now"))[0], 404)
            self.assertEqual(self.save(tok, doc, 0, content=comp("mine now"))[0], 409)   # the id is taken
        _, head = self.s.rest("GET", f"/docs?id=eq.{doc}&select=content", self.alice)
        self.assertEqual(head[0]["content"]["title"], "Alice only")

    def test_everyones_list_is_only_their_own_plus_global(self):
        a, b = self.new_doc(self.alice), self.new_doc(self.bob)
        _, seen = self.s.rest("GET", "/docs?select=id,scope", self.alice)
        ids = {d["id"] for d in seen if d["scope"] == "private"}
        self.assertIn(a, ids)
        self.assertNotIn(b, ids)

    # --- global notations --------------------------------------------------------
    def test_only_an_admin_makes_a_global_notation(self):
        status, _ = self.save(self.alice, str(uuid.uuid4()), 0, p_scope="global")
        self.assertEqual(status, 403)
        doc = self.new_doc(self.admin, p_scope="global", content=comp("For everyone"))
        _, seen = self.s.rest("GET", f"/docs?id=eq.{doc}&select=scope,content", self.alice)
        self.assertEqual(seen[0]["scope"], "global")

    def test_everyone_signed_in_reads_a_global_notation_but_only_an_admin_changes_it(self):
        doc = self.new_doc(self.admin, p_scope="global", content=comp("For everyone"))
        for tok in (self.alice, self.bob):
            _, seen = self.s.rest("GET", f"/docs?id=eq.{doc}&select=content", tok)
            self.assertEqual(seen[0]["content"]["title"], "For everyone")
            status, body = self.save(tok, doc, 1, content=comp("defaced"))
            self.assertEqual((status, body["message"]), (403, "only admins change global notations"))
        self.assertEqual(self.save(self.admin, doc, 1, content=comp("v2"))[0], 200)
        self.assertEqual(self.save(token(ADMIN, admin=False), doc, 2, content=comp("v3"))[0], 403)  # the flag, not the person

    def test_a_scope_cannot_be_changed_after_the_fact(self):
        doc = self.new_doc(self.alice)
        status, r = self.save(self.alice, doc, 1, content=comp("x"), p_scope="global")      # ignored on update
        self.assertEqual(status, 200)
        _, d = self.s.rest("GET", f"/docs?id=eq.{doc}&select=scope", self.alice)
        self.assertEqual(d[0]["scope"], "private")
        self.assertGreaterEqual(self.s.rest("PATCH", f"/docs?id=eq.{doc}", self.alice, {"scope": "global"})[0], 400)

    def test_adding_a_global_notation_to_my_library_is_a_private_copy_that_remembers_where_it_came_from(self):
        g = self.new_doc(self.admin, p_scope="global", content=comp("Shared"))
        mine = str(uuid.uuid4())
        status, _ = self.save(self.alice, mine, 0, content=comp("Shared"), p_forked_from=g)
        self.assertEqual(status, 200)
        _, d = self.s.rest("GET", f"/docs?id=eq.{mine}&select=scope,forked_from", self.alice)
        self.assertEqual(d, [{"scope": "private", "forked_from": g}])
        self.assertEqual(self.save(self.alice, mine, 1, content=comp("My take"))[0], 200)
        _, orig = self.s.rest("GET", f"/docs?id=eq.{g}&select=content", self.alice)
        self.assertEqual(orig[0]["content"]["title"], "Shared")

    # --- history can't be rewritten ----------------------------------------------
    def test_no_one_can_edit_or_remove_a_revision_through_the_api(self):
        doc = self.new_doc(self.alice)
        for tok in (self.alice, self.admin):
            self.assertIn(self.s.rest("PATCH", f"/revisions?doc_id=eq.{doc}", tok, {"name": "forged"})[0], (401, 403))
            self.assertIn(self.s.rest("DELETE", f"/revisions?doc_id=eq.{doc}", tok)[0], (401, 403))
            self.assertIn(self.s.rest("POST", "/revisions", tok, {"doc_id": doc, "rev": 9, "name": "x"})[0], (401, 403))
            self.assertGreaterEqual(self.s.rest("DELETE", f"/docs?id=eq.{doc}", tok)[0], 400)   # a join view: not deletable at all
        _, history = self.s.rest("GET", f"/revisions?doc_id=eq.{doc}&select=name", self.alice)
        self.assertEqual(history, [{"name": "Yaman"}])

    def test_even_the_database_owner_cannot_rewrite_history_by_accident(self):
        doc = self.new_doc(self.alice)
        for sql in (f"update public.revisions set name = 'x' where doc_id = '{doc}'",
                    f"delete from public.revisions where doc_id = '{doc}'",
                    "truncate public.revisions",
                    f"delete from public.documents where id = '{doc}'",
                    "truncate public.documents cascade",
                    f"update public.documents set scope = 'global' where id = '{doc}'",
                    f"update public.documents set head_rev = 0 where id = '{doc}'"):
            with self.assertRaises(subprocess.CalledProcessError, msg=sql):
                self.s.psql("pancham", sql)
        _, history = self.s.rest("GET", f"/revisions?doc_id=eq.{doc}&select=rev", self.alice)
        self.assertEqual(len(history), 1)

    # --- the sync feed -----------------------------------------------------------
    def test_the_feed_returns_each_notations_newest_revision_after_a_cursor_in_order(self):
        a, b = self.new_doc(self.alice, name="A"), self.new_doc(self.alice, name="B")
        _, before = self.s.rest("GET", "/docs?select=seq&order=seq.desc&limit=1", self.alice)
        cursor = before[0]["seq"]
        self.assertEqual(self.save(self.alice, a, 1, name="A", content=comp(cells=("G",)))[0], 200)
        self.assertEqual(self.save(self.alice, a, 2, name="A", content=comp(cells=("G", "M")))[0], 200)
        c = self.new_doc(self.alice, name="C")
        _, feed = self.s.rest("GET", f"/docs?seq=gt.{cursor}&order=seq.asc&select=id,rev,name,seq,content", self.alice)
        self.assertEqual([(d["name"], d["rev"]) for d in feed], [("A", 3), ("C", 1)])    # B unchanged: absent
        self.assertEqual(feed[0]["content"]["sections"][0]["lines"][0]["cells"], ["G", "M"])
        self.assertLess(feed[0]["seq"], feed[1]["seq"])
        _, nothing = self.s.rest("GET", f"/docs?seq=gt.{feed[1]['seq']}&select=id", self.alice)
        self.assertEqual(nothing, [])

    def test_a_listing_without_content_is_cheap_and_complete(self):
        self.new_doc(self.alice, name="Listed")
        _, listing = self.s.rest("GET", "/docs?select=id,scope,rev,name,folder,deleted,updated_at", self.alice)
        self.assertTrue(listing)
        self.assertNotIn("content", listing[0])

    def test_seq_follows_commit_order_under_concurrent_saves(self):
        import threading
        docs = [str(uuid.uuid4()) for _ in range(12)]
        results = []

        def go(d):
            results.append(self.save(self.alice, d, 0)[0])

        threads = [threading.Thread(target=go, args=(d,)) for d in docs]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(results, [200] * 12)
        _, rows = self.s.rest("GET", "/revisions?select=seq,created_at&order=seq.asc", self.alice)
        stamps = [r["created_at"] for r in rows]
        self.assertEqual(stamps, sorted(stamps))

    # --- sign-in and the database agree ------------------------------------------
    def test_a_token_from_the_sign_in_server_is_what_the_database_trusts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            auth = A.Auth(f"{tmp}/a.sqlite", stack.SECRET, allowed_emails=[ALICE], admin_emails=[ADMIN])
            try:
                _, code = auth.issue_code(ALICE)
                tok = auth.verify_code(ALICE, code)["access_token"]
                _, code = auth.issue_code(ADMIN)
                admin_tok = auth.verify_code(ADMIN, code)["access_token"]
            finally:
                auth.close()
        self.assertEqual(self.save(tok, str(uuid.uuid4()), 0, p_scope="global")[0], 403)
        self.assertEqual(self.save(admin_tok, str(uuid.uuid4()), 0, p_scope="global")[0], 200)
        doc = str(uuid.uuid4())
        self.assertEqual(self.save(tok, doc, 0)[0], 200)
        owner = self.s.psql("pancham", f"select owner from public.documents where id = '{doc}'").strip()
        self.assertEqual(owner, A.account_id(ALICE))
        _, seen = self.s.rest("GET", f"/docs?id=eq.{doc}", tok)
        self.assertNotIn("owner", seen[0])                       # ids are derived from emails: never exposed


if __name__ == "__main__":
    unittest.main()
