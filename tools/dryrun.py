#!/usr/bin/env python3
"""Fixture-only CLI/native regression checks; no live screen or real history."""

import argparse
import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import types
import unittest
from unittest import mock
import uuid
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
NATIVE_BINARY = None


def load_source(path):
    loader = importlib.machinery.SourceFileLoader("rewind_fixture_" + uuid.uuid4().hex, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def image_fixture():
    def chunk(kind, content):
        return (struct.pack(">I", len(content)) + kind + content
                + struct.pack(">I", zlib.crc32(kind + content) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\x00" + b"\xff\xff\xff" * 64) * 64))
            + chunk(b"IEND", b""))


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.home = ROOT / "native" / ".build" / "cli-fixtures" / uuid.uuid4().hex
        self.home.mkdir(parents=True, mode=0o700)
        self.addCleanup(shutil.rmtree, self.home)
        self.environment = dict(
            os.environ, REWIND_HOME=str(self.home), REWIND_INTERVAL="4",
            REWIND_WIDTH="1280", REWIND_QUALITY="60", REWIND_FP_GRID="32",
            REWIND_SAME_MEAN="0.5", REWIND_SAME_MAX="12", REWIND_MAX_ERRORS="2",
        )
        with mock.patch.dict(os.environ, self.environment):
            self.rewind = load_source(ROOT / "rewind")
        self.rewind.ensure_dirs()
        self.rewind.run = mock.Mock(side_effect=AssertionError("unexpected external CLI command"))
        original_db = self.rewind.db

        def tracked_db():
            connection = original_db()
            self.addCleanup(connection.close)
            return connection

        self.rewind.db = tracked_db

    def db(self):
        return self.rewind.db()

    def invoke(self, function, **arguments):
        output, error = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            code = function(types.SimpleNamespace(**arguments))
        return code, output.getvalue(), error.getvalue()

    @contextlib.contextmanager
    def capture_fixture(self, fingerprint=None):
        image = image_fixture()

        def fake_run(arguments, **kwargs):
            executable = arguments[0]
            if executable == "screencapture":
                Path(arguments[-1]).write_bytes(image)
            elif executable == "sips":
                Path(arguments[arguments.index("--out") + 1]).write_bytes(image)
            else:
                raise AssertionError("unexpected fixture command: " + executable)
            return subprocess.CompletedProcess(arguments, 0, "", "")

        with mock.patch.object(self.rewind, "run", side_effect=fake_run), \
             mock.patch.object(self.rewind, "fingerprint", return_value=fingerprint or "32" * 1024), \
             mock.patch.object(self.rewind, "screen_context", return_value={
                 "app": "Fixture Mail", "bundle": "fixture.mail", "title": "Quarterly ledger"
             }), \
             mock.patch.object(self.rewind, "ocr_text", return_value=("Quarterly ledger fixture invoice", 1, 0.99)) as ocr:
            yield ocr

    def insert(self, connection, text="Quarterly ledger fixture invoice", timestamp=100,
               app="Fixture Mail", title="Quarterly ledger"):
        directory = self.home / "frames" / "fixture"
        directory.mkdir(exist_ok=True)
        name = f"fixture/{timestamp}-{uuid.uuid4().hex}.jpg"
        image = image_fixture()
        (self.home / "frames" / name).write_bytes(image)
        cursor = connection.execute(
            "INSERT INTO frames(ts,until_ts,app,bundle,title,path,bytes,fingerprint,lines,confidence) "
            "VALUES(?,?,?,?,?,?,?,?,?,?)",
            (timestamp, timestamp, app, "fixture.mail", title, name, len(image), "32" * 1024, 1, 0.99))
        connection.execute("INSERT INTO frames_fts(rowid,text,app,title) VALUES(?,?,?,?)",
                           (cursor.lastrowid, text, app, title))
        self.rewind.bump(connection, "shots_new")
        connection.commit()
        return cursor.lastrowid, name

    def search(self, query, **options):
        arguments = dict(query=[query], app=None, since=None, limit=20)
        arguments.update(options)
        return self.invoke(self.rewind.cmd_search, **arguments)


class CLIRegressionTests(FixtureCase):
    def test_capture_stores_fixture_with_context_text_and_image(self):
        connection = self.db()
        with self.capture_fixture():
            kind, identifier = self.rewind.capture_once(connection)
        self.assertEqual(kind, "new")
        row = connection.execute("SELECT * FROM frames WHERE id=?", (identifier,)).fetchone()
        self.assertEqual(row["app"], "Fixture Mail")
        self.assertEqual(row["bundle"], "fixture.mail")
        self.assertEqual(row["lines"], 1)
        self.assertGreater(row["bytes"], 0)
        self.assertTrue((self.home / "frames" / row["path"]).is_file())
        self.assertIn("Quarterly ledger", connection.execute(
            "SELECT text FROM frames_fts WHERE rowid=?", (identifier,)).fetchone()[0])

    def test_unchanged_screen_skips_ocr_and_extends_time(self):
        connection = self.db()
        with self.capture_fixture() as ocr, mock.patch.object(self.rewind.time, "time", side_effect=[100, 104]):
            kind, identifier = self.rewind.capture_once(connection)
            second_kind, second_id = self.rewind.capture_once(connection)
        self.assertEqual((kind, second_kind, identifier, second_id), ("new", "same", identifier, identifier))
        self.assertEqual(ocr.call_count, 1)
        row = connection.execute("SELECT ts,until_ts FROM frames").fetchone()
        self.assertEqual(tuple(row), (100, 104))
        self.assertEqual(self.rewind.counter(connection, "shots_new"), 1)
        self.assertEqual(self.rewind.counter(connection, "shots_same"), 1)

    def test_small_window_and_broad_change_thresholds(self):
        previous = bytes([100] * 1024)
        noise = bytes([102] * 10 + [100] * 1014)
        small = bytearray(previous)
        small[512] += 32
        self.assertTrue(self.rewind.is_same_screen(previous.hex(), noise.hex()))
        self.assertFalse(self.rewind.is_same_screen(previous.hex(), small.hex()))
        self.assertFalse(self.rewind.is_same_screen(previous.hex(), bytes([101] * 1024).hex()))
        self.assertLessEqual(self.rewind.SAME_MEAN, 2)
        self.assertLessEqual(self.rewind.SAME_MAX, 20)
        self.assertGreaterEqual(self.rewind.FP_GRID, 32)
        self.assertFalse(self.rewind.is_same_screen("0000", "0100"))

    def test_missing_fingerprint_is_a_change(self):
        self.assertEqual(self.rewind.fp_delta(None, "00"), (999, 999))
        self.assertFalse(self.rewind.is_same_screen("", ""))
        self.assertFalse(self.rewind.is_same_screen("00", "0000"))
        connection = self.db()
        with self.capture_fixture(), mock.patch.object(self.rewind, "fingerprint", return_value=None):
            self.assertEqual(self.rewind.capture_once(connection)[0], "new")
            self.assertEqual(self.rewind.capture_once(connection)[0], "new")

    def test_false_successful_screencapture_exit_is_loud(self):
        connection = self.db()
        with mock.patch.object(self.rewind, "run", return_value=subprocess.CompletedProcess(
                ["screencapture"], 0, "", "fixture permission denied")):
            kind, message = self.rewind.capture_once(connection)
        self.assertEqual(kind, "error")
        self.assertIn("wrote nothing", message)
        self.assertIn("fixture permission denied", message)
        self.assertEqual(connection.execute("SELECT count(*) FROM frames").fetchone()[0], 0)

    def test_downscale_failure_is_not_indexed(self):
        connection = self.db()

        def fail_scaling(arguments, **kwargs):
            if arguments[0] == "screencapture":
                Path(arguments[-1]).write_bytes(image_fixture())
                return subprocess.CompletedProcess(arguments, 0, "", "")
            return subprocess.CompletedProcess(arguments, 1, "", "fixture failure")

        with mock.patch.object(self.rewind, "run", side_effect=fail_scaling):
            self.assertEqual(self.rewind.capture_once(connection), ("error", "sips downscale failed"))
        self.assertEqual(connection.execute("SELECT count(*) FROM frames").fetchone()[0], 0)

    def test_search_matches_and_highlights_content_storing_fts(self):
        self.insert(self.db())
        code, output, _ = self.search("ledger")
        self.assertEqual(code, 0)
        self.assertIn("[ledger]", output)
        self.assertIn("1 match(es)", output)

    def test_fts_query_operators_app_since_and_limits(self):
        connection = self.db()
        self.insert(connection, timestamp=100, text="quarterly ledger café")
        self.insert(connection, timestamp=200, text="quarterly budget invoice", app="Fixture Notes", title="Budget")
        self.assertIn("1 match(es)", self.search('"quarterly ledger"')[1])
        self.assertIn("2 match(es)", self.search("quarterly OR invoice")[1])
        self.assertIn("1 match(es)", self.search("quarterly NOT budget")[1])
        self.assertIn("1 match(es)", self.search("cafe")[1])
        self.assertIn("1 match(es)", self.search("quarter*", app="Notes")[1])
        self.assertIn("1 match(es)", self.search("quarter*", limit=1)[1])
        with mock.patch.object(self.rewind, "parse_since", return_value=150):
            output = self.search("quarter*", since="fixture")[1]
        self.assertIn("Fixture Notes", output)
        self.assertNotIn("Fixture Mail", output)

    def test_nonexistent_query_and_invalid_query_have_distinct_exit_codes(self):
        self.insert(self.db())
        code, output, _ = self.search("zzzznotarealtokenzzzz")
        self.assertEqual(code, 1)
        self.assertIn("no matches", output)
        self.assertNotIn("Traceback", output)
        code, output, _ = self.search('"unterminated')
        self.assertEqual(code, 2)
        self.assertIn("bad query", output)

    def test_timeline_embeds_fixture_text_and_never_opens_window(self):
        self.insert(self.db())
        destination = self.home / "timeline.html"
        code, _, _ = self.invoke(self.rewind.cmd_timeline, since="invalid", limit=400, out=str(destination), open=False)
        self.assertEqual(code, 0)
        html = destination.read_text()
        self.assertNotIn("__DATA__", html)
        match = re.search(r"const DATA = (\[.*?\]);", html, re.S)
        self.assertIsNotNone(match)
        data = json.loads(match.group(1))
        self.assertEqual(len(data), 1)
        self.assertIn("fixture invoice", data[0]["text"])
        self.assertTrue(data[0]["img"].startswith("file://" + str(self.home)))

    def test_prune_dry_run_never_deletes_images(self):
        connection = self.db()
        _, name = self.insert(connection)
        code, output, _ = self.invoke(self.rewind.cmd_prune, days=0, yes=False)
        self.assertEqual(code, 0)
        self.assertIn("would drop", output)
        self.assertTrue((self.home / "frames" / name).exists())
        self.assertEqual(connection.execute("SELECT count(*) FROM frames_fts").fetchone()[0], 1)

    def test_prune_removes_pixels_but_keeps_text_rows_and_counters(self):
        connection = self.db()
        identifier, name = self.insert(connection)
        code, _, _ = self.invoke(self.rewind.cmd_prune, days=0, yes=True)
        self.assertEqual(code, 0)
        self.assertFalse((self.home / "frames" / name).exists())
        row = connection.execute("SELECT id,path,bytes FROM frames").fetchone()
        self.assertEqual(tuple(row), (identifier, None, 0))
        self.assertEqual(self.rewind.counter(connection, "shots_new"), 1)
        self.assertEqual(self.search("ledger")[0], 0)
        self.assertIn("[ledger]", self.search("ledger")[1])

    def test_daemon_repeated_failures_are_bounded_and_explained(self):
        with mock.patch.object(self.rewind, "capture_once", return_value=("error", "fixture capture failed")), \
             mock.patch.object(self.rewind.time, "sleep"):
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                result = self.rewind.capture_loop(1)
        self.assertEqual(result, 1)
        self.assertIn("giving up after 2", output.getvalue())
        self.assertFalse((self.home / "capture.pid").exists())

    def test_daemon_repeated_exceptions_are_bounded_and_explained(self):
        with mock.patch.object(self.rewind, "capture_once", side_effect=RuntimeError("fixture exception")), \
             mock.patch.object(self.rewind.time, "sleep"):
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                result = self.rewind.capture_loop(1)
        self.assertEqual(result, 1)
        self.assertIn("giving up after 2", output.getvalue())
        self.assertIn("fixture exception", output.getvalue())

    def test_cli_cannot_capture_while_native_owns_index(self):
        with (self.home / "native-capture.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, _, error = self.invoke(self.rewind.cmd_capture)
            self.assertEqual(code, 1)
            self.assertIn("another Rewind capture process", error)
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                self.assertEqual(self.rewind.capture_loop(1), 1)
        self.assertFalse((self.home / "capture.pid").exists())

    def test_stats_uses_shots_not_elapsed_wall_clock(self):
        connection = self.db()
        self.insert(connection, timestamp=1)
        self.rewind.bump(connection, "shots_same", 39)
        connection.commit()
        code, output, _ = self.invoke(self.rewind.cmd_stats)
        self.assertEqual(code, 0)
        self.assertIn("40 (1 stored, 39 deduped)", output)
        self.assertIn("98% of shots", output)
        self.assertIn("per 24h of capture", output)

    def test_contentless_cli_recovery_uses_only_generated_fixture(self):
        connection = self.db()
        identifier, _ = self.insert(connection)
        connection.executescript("""
            DROP TABLE frames_fts;
            CREATE VIRTUAL TABLE frames_fts USING fts5(text, app, title, content='', tokenize='unicode61');
        """)
        connection.execute("INSERT INTO frames_fts(rowid,text,app,title) VALUES(?,?,?,?)",
                           (identifier, "old inaccessible fixture", "Fixture Mail", "Ledger"))
        connection.commit()
        with mock.patch.object(self.rewind, "ocr_text", return_value=("Recovered fixture words", 1, 0.9)):
            self.rewind.migrate(connection)
        self.assertEqual(connection.execute("SELECT text FROM frames_fts").fetchone()[0], "Recovered fixture words")
        self.assertNotIn("content=''", connection.execute(
            "SELECT sql FROM sqlite_master WHERE name='frames_fts'").fetchone()[0])

    def test_since_and_default_algorithms_are_unchanged(self):
        with mock.patch.object(self.rewind.time, "time", return_value=200000):
            self.assertEqual(self.rewind.parse_since("2d"), 27200)
            self.assertEqual(self.rewind.parse_since(".5h"), 198200)
            self.assertEqual(self.rewind.parse_since("nonsense"), 0)
        self.assertEqual(self.rewind.INTERVAL, 4)
        self.assertEqual(self.rewind.WIDTH, 1280)
        self.assertEqual(self.rewind.QUALITY, 60)

    def test_capture_ocr_index_search_sources_have_no_network_client(self):
        source = (ROOT / "rewind").read_text()
        self.assertNotRegex(source, r"(?m)^\s*(?:import|from)\s+(?:urllib|requests|socket|http)")
        for path in (ROOT / "native" / "Sources").rglob("*.swift"):
            self.assertNotRegex(path.read_text(), r"\b(?:URLSession|NWConnection|URLRequest)\b", str(path))


class AgentBridgeTests(FixtureCase):
    def load_agent(self, variant):
        stub = types.ModuleType("agents.basic_agent")
        stub.BasicAgent = type("BasicAgent", (), {"__init__": lambda self, *args: None})
        package = types.ModuleType("agents")
        path = ROOT / "rapp_rewind" / variant / "rapp_rewind_agent.py"
        with mock.patch.dict(sys.modules, {"agents": package, "agents.basic_agent": stub}):
            agent = load_source(path)
        agent._CANDIDATES = []
        agent._NATIVE_APPS = []
        return agent

    def fake_app(self, bundle_id="io.rapp.rewind"):
        app = self.home / ("Fixture-" + uuid.uuid4().hex + ".app")
        binary = app / "Contents" / "MacOS" / "RAPPRewind"
        binary.parent.mkdir(parents=True)
        binary.write_text("fixture executable — must never actually run\n")
        binary.chmod(0o700)
        with (app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
        return app, binary

    def test_both_agents_keep_all_actions_and_prune_is_always_dry_run(self):
        for variant in ("singleton", "twin/agents"):
            agent = self.load_agent(variant)
            instance = agent.RappRewindAgent()
            self.assertEqual(set(instance.ACTIONS), {"doctor", "search", "stats", "capture", "timeline", "prune", "bench"})
            with mock.patch.object(agent, "_run", return_value=("fixture preview", None)) as run:
                output = instance.perform(action="prune", days=10, confirm=True)
            self.assertEqual(run.call_args.args[0], ["prune", "--days", "10"])
            self.assertIn("DRY RUN", output)

    def test_native_discovery_validates_bundle_identity(self):
        agent = self.load_agent("singleton")
        wrong, _ = self.fake_app(bundle_id="fixture.other")
        good, binary = self.fake_app()
        agent._NATIVE_APPS = [str(wrong), str(good)]
        self.assertEqual(agent._native(), (str(binary), str(good)))

    def test_native_bridge_checks_gatekeeper_and_passes_bounded_arguments(self):
        for variant in ("singleton", "twin/agents"):
            agent = self.load_agent(variant)
            app, binary = self.fake_app()
            agent._NATIVE_APPS = [str(app)]
            calls = []

            def fake_run(arguments, **kwargs):
                calls.append(arguments)
                return subprocess.CompletedProcess(arguments, 0, "fixture local result", "")

            with mock.patch.dict(os.environ, {"REWIND_CLI": ""}), mock.patch.object(agent.subprocess, "run", side_effect=fake_run):
                result = agent.RappRewindAgent().perform(action="search", query="quarterly ledger", limit=12)
            self.assertEqual(result, "fixture local result")
            self.assertEqual(calls[0], ["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
            self.assertEqual(calls[1], [str(binary), "--rewind-command", "search", "quarterly", "ledger", "--limit", "12"])

    def test_rejected_native_app_does_not_fall_back_to_headless_capture(self):
        agent = self.load_agent("singleton")
        app, _ = self.fake_app()
        agent._NATIVE_APPS = [str(app)]
        with mock.patch.dict(os.environ, {"REWIND_CLI": ""}), mock.patch.object(
                agent.subprocess, "run", return_value=subprocess.CompletedProcess([], 3, "", "rejected")) as run:
            result = agent.RappRewindAgent().perform(action="capture")
        self.assertIn("macOS has not approved", result)
        self.assertEqual(run.call_count, 1)

    def test_explicit_cli_override_preserves_legacy_backend(self):
        agent = self.load_agent("singleton")
        cli = self.home / "rewind-fixture"
        cli.write_text("fixture only\n")
        cli.chmod(0o700)
        agent._CANDIDATES = [str(cli)]
        app, _ = self.fake_app()
        agent._NATIVE_APPS = [str(app)]
        with mock.patch.dict(os.environ, {"REWIND_CLI": str(cli)}), mock.patch.object(
                agent.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "fixture stats", "")) as run:
            result = agent.RappRewindAgent().perform(action="stats")
        self.assertEqual(result, "fixture stats")
        self.assertEqual(run.call_args.args[0], [str(cli), "stats"])


class NativeInteroperabilityTests(FixtureCase):
    def native(self, *arguments):
        if NATIVE_BINARY is None:
            self.skipTest("pass --native-binary native/.build/debug/RAPPRewind for native interoperability checks")
        return subprocess.run([str(NATIVE_BINARY), *arguments], capture_output=True, text=True,
                              timeout=60, env=self.environment, cwd=str(ROOT / "native"))

    def test_native_self_check_uses_no_screen_or_history(self):
        result = self.native("--self-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["fts5"])
        self.assertFalse(data["captureStarted"])
        self.assertFalse(data["permissionRequested"])
        self.assertFalse(data["historyOpened"])
        self.assertFalse((self.home / "index.sqlite3").exists())

    def test_native_search_reads_existing_cli_fixture_without_migration(self):
        connection = self.db()
        identifier, image = self.insert(connection)
        before = connection.execute("SELECT sql FROM sqlite_master WHERE name='frames'").fetchone()[0]
        result = self.native("--rewind-command", "search", "ledger", "--app", "Mail")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"#{identifier}", result.stdout)
        self.assertIn("[ledger]", result.stdout)
        self.assertEqual(connection.execute("SELECT sql FROM sqlite_master WHERE name='frames'").fetchone()[0], before)
        self.assertTrue((self.home / "frames" / image).is_file())
        self.assertEqual(connection.execute("SELECT COUNT(*) FROM frames").fetchone()[0], 1)

    def test_native_prune_is_a_non_destructive_preview(self):
        _, image = self.insert(self.db())
        result = self.native("--rewind-command", "prune", "--days", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY RUN", result.stdout)
        self.assertTrue((self.home / "frames" / image).exists())
        rejected = self.native("--rewind-command", "prune", "--days", "0", "--yes")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertTrue((self.home / "frames" / image).exists())

    def test_native_query_exit_codes_do_not_hide_errors(self):
        self.insert(self.db())
        missing = self.native("--rewind-command", "search", "zzzznotarealtokenzzzz")
        self.assertEqual(missing.returncode, 1)
        invalid = self.native("--rewind-command", "search", '"unterminated')
        self.assertEqual(invalid.returncode, 2)
        self.assertIn("SQLite", invalid.stderr)

    def test_native_benchmark_uses_only_generated_pixels(self):
        result = self.native("--rewind-command", "bench")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertFalse(output["capturePerformed"])
        self.assertFalse(output["indexOpened"])
        self.assertGreater(output["jpegBytes"], 0)
        self.assertFalse((self.home / "index.sqlite3").exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-binary", type=Path, help="optionally check the built native executable against CLI fixtures")
    arguments = parser.parse_args()
    if arguments.native_binary:
        NATIVE_BINARY = arguments.native_binary.resolve()
        if not NATIVE_BINARY.is_file():
            parser.error("native binary does not exist; run swift build -j 2 in native first")
    print("Fixture-only checks: no live capture; generated databases live under native/.build/cli-fixtures.", flush=True)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
