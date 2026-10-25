"""Tests for the local Pi-hole integration harness.

Run with:
    python3 -m unittest discover -s scripts/integration/tests -v

The Docker interactions use a fake ``docker`` executable on ``PATH``. No daemon,
container, network or volume is created by these tests.
"""

from __future__ import annotations

import contextlib
import html
import http.server
import io
import json
import os
import re
import shutil
import signal
import socketserver
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse
from unittest import mock

INTEGRATION_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(INTEGRATION_DIR))

import harness  # noqa: E402

COMPOSE_PROJECT_LABEL = "com.docker.compose.project"

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time

SCENARIO = json.load(open(os.environ["FAKE_DOCKER_SCENARIO"], encoding="utf-8"))
LOG = os.environ.get("FAKE_DOCKER_LOG")
ARGS = sys.argv[1:]
if LOG:
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(ARGS) + "\n")


def die(message, code=1):
    sys.stderr.write(message + "\n")
    raise SystemExit(code)


def lookup_failed(kind):
    failure = SCENARIO.get("lookup_failure")
    return failure is True or failure == kind


def compose_failed(subcommand):
    failure = SCENARIO.get("compose_failure")
    return failure is True or failure == subcommand or (
        isinstance(failure, list) and subcommand in failure
    )


def write_after_up_resources():
    marker_path = SCENARIO.get("resources_after_up")
    if not marker_path:
        return
    state_path = os.path.join(
        os.environ["HARNESS_WORKTREE"],
        ".integration",
        "manual",
        os.environ["HARNESS_PROJECT"],
        "state.json",
    )
    with open(state_path, encoding="utf-8") as handle:
        state = json.load(handle)
    labels = {
        "com.holeberry.integration.project": state["project"],
        "com.holeberry.integration.run-id": state["run_id"],
        "com.holeberry.integration.worktree": state["worktree"],
        "com.holeberry.integration.owner": state["ownership_token"],
        "com.docker.compose.project": state["project"],
    }
    with open(marker_path, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "containers": {"container-up": labels},
                "networks": {"network-up": labels},
                "volumes": {"volume-up": labels},
            },
            handle,
        )


def resources(kind):
    merged = dict(SCENARIO.get(kind, {}))
    marker_path = SCENARIO.get("resources_after_up")
    if marker_path and os.path.exists(marker_path):
        with open(marker_path, encoding="utf-8") as handle:
            merged.update(json.load(handle).get(kind, {}))
    return merged


def selected(kind):
    filter_arg = ""
    if "--filter" in ARGS:
        filter_arg = ARGS[ARGS.index("--filter") + 1]
    available = resources(kind)
    if not filter_arg.startswith("label="):
        return list(available)
    expression = filter_arg[len("label="):]
    key, separator, value = expression.partition("=")
    if not separator:
        return []
    return [resource_id for resource_id, labels in available.items() if labels.get(key) == value]


def before_remove(resource_id):
    delay = SCENARIO.get("remove_delay", {}).get(resource_id)
    if delay is None:
        return
    if resource_id in SCENARIO.get("spawn_child", []):
        child_delay = float(SCENARIO.get("spawn_child_delay", 30))
        child = subprocess.Popen(
            [sys.executable, "-c", f"import time; time.sleep({child_delay})"]
        )
        pid_file = SCENARIO.get("spawn_pid_file")
        if pid_file:
            with open(pid_file, "a", encoding="utf-8") as handle:
                handle.write(str(child.pid) + "\n")
    time.sleep(float(delay))


if ARGS[:2] == ["context", "inspect"]:
    if SCENARIO.get("context_failure"):
        die("fake docker: cannot resolve the local endpoint")
    print(SCENARIO.get("endpoint", "unix:///var/run/docker.sock"))
    raise SystemExit(0)

if ARGS[:1] == ["ps"]:
    if lookup_failed("containers"):
        die(SCENARIO.get("lookup_stderr") or "fake docker: Cannot connect to the Docker daemon")
    if SCENARIO.get("huge_lookup"):
        sys.stdout.write("A" * int(SCENARIO.get("huge_lookup_bytes", 400000)) + "\n")
        raise SystemExit(0)
    for resource_id in selected("containers"):
        print(resource_id)
    raise SystemExit(0)

if ARGS[:1] == ["info"]:
    if SCENARIO.get("daemon_failure"):
        die("fake docker: Cannot connect to the Docker daemon")
    print("27.0.0")
    raise SystemExit(0)

if ARGS[:2] == ["network", "ls"]:
    if lookup_failed("networks"):
        die(SCENARIO.get("lookup_stderr") or "fake docker: Cannot connect to the Docker daemon")
    for resource_id in selected("networks"):
        print(resource_id)
    raise SystemExit(0)

if ARGS[:2] == ["volume", "ls"]:
    if lookup_failed("volumes"):
        die(SCENARIO.get("lookup_stderr") or "fake docker: Cannot connect to the Docker daemon")
    for resource_id in selected("volumes"):
        print(resource_id)
    raise SystemExit(0)

if ARGS[:3] == ["inspect", "--type", "container"]:
    resource_id = ARGS[-1]
    labels = resources("containers").get(resource_id)
    if labels is None:
        die("fake docker: no such container " + resource_id)
    print(json.dumps(labels))
    raise SystemExit(0)

if ARGS[:2] == ["network", "inspect"]:
    resource_id = ARGS[-1]
    if any("{{.Name}}" in argument for argument in ARGS):
        if SCENARIO.get("named_networks", {}).get(resource_id):
            print(resource_id)
            raise SystemExit(0)
        die("Error response from daemon: network " + resource_id + " not found")
    labels = resources("networks").get(resource_id)
    if labels is None:
        die("fake docker: no such network " + resource_id)
    print(json.dumps(labels))
    raise SystemExit(0)

if ARGS[:2] == ["volume", "inspect"]:
    resource_id = ARGS[-1]
    if any("{{.Name}}" in argument for argument in ARGS):
        if SCENARIO.get("named_volumes", {}).get(resource_id):
            print(resource_id)
            raise SystemExit(0)
        die("Error response from daemon: get " + resource_id + ": no such volume")
    labels = resources("volumes").get(resource_id)
    if labels is None:
        die("fake docker: no such volume " + resource_id)
    print(json.dumps(labels))
    raise SystemExit(0)

if ARGS[:2] == ["image", "inspect"]:
    image = ARGS[-1]
    identifiers = SCENARIO.get("image_ids", {})
    if image in SCENARIO.get("missing_images", []) or image not in identifiers:
        die("fake docker: no such image: " + image)
    print(identifiers[image])
    raise SystemExit(0)

if ARGS[:1] == ["rm"]:
    resource_id = ARGS[-1]
    before_remove(resource_id)
    if resource_id in SCENARIO.get("remove_failure", []):
        die("fake docker: cannot remove " + resource_id)
    raise SystemExit(0)

if ARGS[:2] == ["network", "rm"]:
    resource_id = ARGS[-1]
    before_remove(resource_id)
    if resource_id in SCENARIO.get("remove_failure", []):
        die("fake docker: cannot remove " + resource_id)
    raise SystemExit(0)

if ARGS[:2] == ["volume", "rm"]:
    resource_id = ARGS[-1]
    before_remove(resource_id)
    if resource_id in SCENARIO.get("remove_failure", []):
        die("fake docker: cannot remove " + resource_id)
    raise SystemExit(0)

if ARGS[:1] == ["compose"]:
    rest = ARGS[1:]
    position = 0
    while position < len(rest) and rest[position].startswith("-"):
        if rest[position] in {"--file", "-f", "--project-name", "-p", "--project-directory"}:
            position += 2
        else:
            position += 1
    subcommand = rest[position] if position < len(rest) else ""
    arguments = rest[position + 1:]
    if subcommand == "up":
        write_after_up_resources()
    if compose_failed(subcommand):
        die("fake docker compose: " + subcommand + " failed")
    if subcommand == "config" and "--images" in arguments:
        for image in SCENARIO.get("compose_images", []):
            print(image)
        raise SystemExit(0)
    if subcommand == "pull":
        print("pulled")
        raise SystemExit(0)
    if subcommand == "up":
        print("started")
        raise SystemExit(0)
    if subcommand == "ps":
        sys.stdout.write(SCENARIO.get("compose_ps", ""))
        raise SystemExit(0)
    if subcommand == "logs":
        sys.stdout.write(SCENARIO.get("compose_logs", ""))
        raise SystemExit(0)
    if subcommand == "port":
        ports = SCENARIO.get("compose_ports", {})
        service = arguments[0] if arguments else ""
        if service in ports:
            print(ports[service])
            raise SystemExit(0)
        die("fake docker compose: no published port for " + service)
    if subcommand == "exec":
        joined = " ".join(arguments)
        if "gravity.db" in joined:
            if SCENARIO.get("gravity_query_failure"):
                die(SCENARIO.get("gravity_query_stderr", "fake sqlite failed"))
            sys.stdout.write(SCENARIO.get("gravity_rows", ""))
            raise SystemExit(0)
        if "setupVars.conf" in joined:
            delay = SCENARIO.get("exec_delay")
            if delay:
                time.sleep(float(delay))
            if SCENARIO.get("compose_exec_failure") == "setupvars":
                sys.stderr.write(
                    SCENARIO.get("compose_exec_stderr", "fake docker: exec failed") + "\n"
                )
                raise SystemExit(1)
            sys.stdout.write(SCENARIO.get("v5_setup_vars", "WEBPASSWORD=fake-token\n"))
            raise SystemExit(0)
        if "dig" in arguments:
            sys.stdout.write(SCENARIO.get("dig_output", ""))
            raise SystemExit(0)
        print("executed")
        raise SystemExit(0)
    print("compose " + subcommand)
    raise SystemExit(0)

die("fake docker: unsupported command: " + " ".join(ARGS))
'''


class BrokenSink:
    """A text sink that fails on every write."""

    def write(self, text):  # noqa: ARG002
        raise BrokenPipeError("sink is closed")

    def flush(self):
        raise BrokenPipeError("sink is closed")


class DelayedSink:
    """A text sink whose writes take longer than the supervisor's deadline."""

    def __init__(self, delay):
        self.delay = delay
        self.text = []

    def write(self, text):
        time.sleep(self.delay)
        self.text.append(text)

    def flush(self):
        pass


class _FixtureApiState:
    """Bounded local stand-in for the v5 and v6 HTTP APIs."""

    def __init__(self):
        self.v5_token = "LEGACYTOKENSECRET0123456789abcdef0123456789abcdef"
        self.v6_password = "v6-fixture-secret"
        self.v6_sid = "SIDVALUE1234567890"
        self.allow = ["allowed.holeberry.test", "xn--bcher-kva.holeberry.test"]
        self.deny = ["denied.holeberry.test"]
        self.regex_deny = [r"(^|\.)regex\.holeberry\.test$"]
        self.blocking = "enabled"
        self.logouts = 0
        self.logout_status = 204
        self.auth_requests = 0
        self.delay = 0.0
        self.rotate_sids = False
        self.issued_sids = set()
        self.delete_count = 0
        self.delete_hook = None
        self.logout_failures = set()
        self.logout_delays = {}
        self.lock = threading.Lock()

    def issue_sid(self):
        if not self.rotate_sids:
            self.issued_sids.add(self.v6_sid)
            return self.v6_sid
        sid = f"SID-{len(self.issued_sids) + 1}"
        self.issued_sids.add(sid)
        return sid



class _FixtureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # noqa: ARG002
        pass

    def _write(self, status, payload):
        delay = getattr(self.server.state, "delay", 0.0)
        if delay:
            time.sleep(delay)
        try:
            if status == 204:
                self.send_response(204)
                self.end_headers()
                return
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _v5(self, query):
        state = self.server.state
        if query.get("auth", [""])[0] != state.v5_token:
            self._write(200, {})
            return
        if "list" in query:
            name = query["list"][0]
            values = {
                "white": state.allow,
                "black": state.deny,
                "regex_black": state.regex_deny,
            }.get(name, [])
            self._write(200, {"data": [{"domain": domain, "type": name} for domain in values]})
            return
        if "status" in query:
            self._write(200, {"status": state.blocking})
            return
        self._write(200, {})

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        state = self.server.state
        if parsed.path == "/admin/api.php":
            self._v5(query)
            return
        if self.headers.get("X-FTL-SID") != state.v6_sid:
            self._write(401, {"error": {"key": "unauthorized"}})
            return
        if parsed.path == "/api/dns/blocking":
            self._write(200, {"blocking": state.blocking, "timer": None})
            return
        parts = parsed.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "domains":
            values = {
                ("allow", "exact"): state.allow,
                ("deny", "exact"): state.deny,
                ("deny", "regex"): state.regex_deny,
            }.get((parts[2], parts[3]), [])
            self._write(
                200,
                {"domains": [{"domain": domain, "type": parts[2]} for domain in values]},
            )
            return
        self._write(404, {"error": "not found"})

    def do_POST(self):
        state = self.server.state
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(min(length, 4096))
        if urlparse(self.path).path == "/api/auth":
            try:
                payload = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                payload = {}
            if payload.get("password") != state.v6_password:
                self._write(401, {"error": {"key": "unauthorized"}})
                return
            with state.lock:
                state.auth_requests += 1
            sid = state.issue_sid()
            self._write(200, {"session": {"sid": sid, "csrf": "CSRFVALUE"}})
            return
        self._write(404, {"error": "not found"})

    def do_DELETE(self):
        state = self.server.state
        if urlparse(self.path).path == "/api/auth":
            sid = self.headers.get("X-FTL-SID")
            if sid not in state.issued_sids:
                self._write(401, {"error": {"key": "unauthorized"}})
                return
            with state.lock:
                index = state.delete_count
                state.delete_count += 1
                state.logouts += 1
            if state.delete_hook is not None:
                state.delete_hook(index)
            if index in state.logout_failures:
                self._write(500, {"error": "logout failed"})
                return
            delay = state.logout_delays.get(index, 0.0)
            if delay:
                time.sleep(delay)
            self._write(state.logout_status, {"error": "logout failed"})
            return
        self._write(404, {"error": "not found"})


class _FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class _SlowBodyHandler(http.server.BaseHTTPRequestHandler):
    """Send a valid JSON body one byte at a time to exercise body deadlines."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # noqa: ARG002
        pass

    def do_GET(self):
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            for byte in body:
                self.wfile.write(bytes([byte]))
                self.wfile.flush()
                time.sleep(self.server.delay)
        except (BrokenPipeError, ConnectionResetError):
            pass


class _SlowBodyServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class _RawResponseHandler(socketserver.BaseRequestHandler):
    """Drip a complete raw HTTP response one byte at a time."""

    def handle(self):
        self.request.settimeout(5)
        try:
            self.request.recv(4096)
        except OSError:
            return
        for byte in self.server.payload:
            try:
                self.request.sendall(bytes([byte]))
            except (BrokenPipeError, ConnectionResetError):
                self.server.closed.set()
                return
            if self.server.delay:
                time.sleep(self.server.delay)
        try:
            while self.request.recv(1024):
                pass
        except OSError:
            pass
        self.server.closed.set()


class _RawResponseServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class LateFailureSink:
    """A sink that fails only when it sees a chosen marker line."""

    def __init__(self, marker):
        self.marker = marker
        self.text = []

    def write(self, text):
        if self.marker in text:
            raise BrokenPipeError("late sink failure")
        self.text.append(text)

    def flush(self):
        pass


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="holeberry harness test "))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

        self.worktree = self.tmp / "work tree"
        self.worktree.mkdir()

        self.bin_dir = self.tmp / "fake bin"
        self.bin_dir.mkdir()
        docker = self.bin_dir / "docker"
        docker.write_text(FAKE_DOCKER, encoding="utf-8")
        docker.chmod(0o755)

        self.scenario_path = self.tmp / "scenario.json"
        self.docker_log_path = self.tmp / "docker.log"
        self.write_scenario()

        self.env_patch = mock.patch.dict(
            os.environ,
            {
                "PATH": str(self.bin_dir) + os.pathsep + os.environ.get("PATH", ""),
                "FAKE_DOCKER_SCENARIO": str(self.scenario_path),
                "FAKE_DOCKER_LOG": str(self.docker_log_path),
            },
        )
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    # ------------------------------------------------------------------ helpers

    def secrets(self):
        return {
            "v5_password": "v5-fixture-secret",
            "v6_password": "v6-fixture-secret",
        }

    @contextlib.contextmanager
    def fixture_api(self):
        state = _FixtureApiState()
        server = _FixtureServer(("127.0.0.1", 0), _FixtureHandler)
        server.state = state
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield state, f"http://127.0.0.1:{server.server_address[1]}"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2.0)

    def compose_env(self, state, secrets):
        env = dict(os.environ)
        env.update(
            {
                "DOCKER_HOST": "unix:///var/run/docker.sock",
                "HARNESS_PROJECT": state["project"],
                "HARNESS_RUN_ID": state["run_id"],
                "HARNESS_WORKTREE": state["worktree"],
                "HARNESS_OWNER": state["ownership_token"],
                "HARNESS_V5_PASSWORD": secrets["v5_password"],
                "HARNESS_V6_PASSWORD": secrets["v6_password"],
                "HARNESS_V5_PORT": str(state["ports"]["v5"]),
                "HARNESS_V6_PORT": str(state["ports"]["v6"]),
            }
        )
        return env

    def allocate(self, project=None):
        return harness.allocate_manual(
            worktree=self.worktree,
            project=project,
            secrets=self.secrets(),
        )

    def write_scenario(self, *, containers=None, networks=None, volumes=None, **extra):
        scenario = {
            "endpoint": "unix:///var/run/docker.sock",
            "containers": containers or {},
            "networks": networks or {},
            "volumes": volumes or {},
        }
        scenario.update(extra)
        self.scenario_path.write_text(json.dumps(scenario), encoding="utf-8")

    def labels(self, allocation, **overrides):
        state = allocation.state
        labels = {
            harness.LABEL_PROJECT: state["project"],
            harness.LABEL_RUN_ID: state["run_id"],
            harness.LABEL_WORKTREE: state["worktree"],
            harness.LABEL_OWNER: state["ownership_token"],
            COMPOSE_PROJECT_LABEL: state["project"],
        }
        labels.update(overrides)
        return labels

    def teardown(self, project, env=None, **kwargs):
        stdout = io.StringIO()
        stderr = io.StringIO()
        summary = harness.teardown_project(
            project,
            worktree=self.worktree,
            env={} if env is None else env,
            stdout=stdout,
            stderr=stderr,
            **kwargs,
        )
        return summary, stdout.getvalue(), stderr.getvalue()

    def docker_calls(self):
        if not self.docker_log_path.exists():
            return []
        return [
            json.loads(line)
            for line in self.docker_log_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def mutations(self):
        mutations = []
        for args in self.docker_calls():
            if not args:
                continue
            if args[0] == "rm":
                mutations.append(args)
            elif len(args) > 1 and args[0] in {"network", "volume"} and args[1] in {"rm", "prune"}:
                mutations.append(args)
            elif args[0] in {"system", "container"} and any(part in {"prune", "rm"} for part in args):
                mutations.append(args)
        return mutations

    def inspected_ids(self):
        return {args[-1] for args in self.docker_calls() if "inspect" in args}

    def rewrite_state(self, allocation, **changes):
        state = dict(allocation.state)
        state.update(changes)
        allocation.state_path.write_text(json.dumps(state), encoding="utf-8")
        os.chmod(allocation.state_path, 0o600)

    def assert_redacted(self, text, secret):
        from urllib.parse import quote, quote_plus
        from xml.sax.saxutils import escape

        encodings = {
            secret,
            quote(secret, safe=""),
            quote_plus(secret),
            json.dumps(secret)[1:-1],
            json.dumps(secret, ensure_ascii=False)[1:-1],
            escape(secret),
            re.sub(r"%[0-9A-F]{2}", lambda match: match.group(0).lower(), quote(secret, safe="")),
        }
        for encoding in encodings:
            self.assertNotIn(encoding, text)
        self.assertNotIn("LEGACYTOKEN", text)
        self.assertNotIn("SIDVALUE123", text)
        self.assertNotIn("SIDCOOKIE456", text)
        self.assertNotIn("BEARERTOKEN789", text)
        self.assertIn(harness.REDACTED, text)

    # -------------------------------------------------------------------- tests

    def test_rejects_unowned_project(self):
        allocation = self.allocate("holeberry-unowned-manual")
        project = allocation.state["project"]
        good = self.labels(allocation)
        wrong_owner = self.labels(allocation, **{harness.LABEL_OWNER: "0" * 32})
        missing_owner = {
            key: value for key, value in good.items() if key != harness.LABEL_OWNER
        }
        compose_only = {COMPOSE_PROJECT_LABEL: project}
        self.write_scenario(
            containers={"container-a": good, "container-compose-only": compose_only},
            networks={
                "network-a": good,
                "network-b": wrong_owner,
                "network-compose-only": compose_only,
            },
            volumes={
                "volume-a": good,
                "volume-b": missing_owner,
                "volume-compose-only": compose_only,
            },
        )

        with self.assertRaises(harness.OwnershipError) as context:
            self.teardown(project)

        self.assertEqual(self.mutations(), [])
        self.assertTrue(allocation.state_path.exists())
        self.assertIn("ownership", str(context.exception))
        self.assertTrue(
            {
                "container-a",
                "container-compose-only",
                "network-a",
                "network-b",
                "network-compose-only",
                "volume-a",
                "volume-b",
                "volume-compose-only",
            }
            <= self.inspected_ids()
        )
        ps_filters = [
            args[args.index("--filter") + 1]
            for args in self.docker_calls()
            if args and args[0] == "ps" and "--filter" in args
        ]
        self.assertIn(f"label={harness.LABEL_PROJECT}={project}", ps_filters)
        self.assertIn(f"label={COMPOSE_PROJECT_LABEL}={project}", ps_filters)

        # A Compose member whose harness project label points at another project is mixed.
        second = self.allocate("holeberry-mixed-manual")
        self.docker_log_path.unlink(missing_ok=True)
        foreign_project = self.labels(
            second, **{harness.LABEL_PROJECT: "holeberry-foreign-manual"}
        )
        self.write_scenario(containers={"container-c": foreign_project})
        with self.assertRaises(harness.OwnershipError):
            self.teardown(second.state["project"])
        self.assertEqual(self.mutations(), [])
        self.assertTrue(second.state_path.exists())

    def test_rejects_changed_state_project(self):
        allocation = self.allocate("holeberry-state-manual")
        self.rewrite_state(allocation, project="holeberry-changed-manual")

        with self.assertRaises(harness.StateError):
            self.teardown(allocation.state["project"])
        self.assertEqual(self.docker_calls(), [])
        self.assertTrue(allocation.state_path.exists())

        worktree_state = self.allocate("holeberry-worktree-manual")
        self.rewrite_state(worktree_state, worktree=str(self.tmp / "other worktree"))
        with self.assertRaises(harness.StateError):
            self.teardown(worktree_state.state["project"])
        self.assertEqual(self.mutations(), [])
        self.assertTrue(worktree_state.state_path.exists())

        schema_state = self.allocate("holeberry-schema-manual")
        self.rewrite_state(schema_state, schema_version=99)
        with self.assertRaises(harness.StateError):
            self.teardown(schema_state.state["project"])
        self.assertTrue(schema_state.state_path.exists())

        symlink_state = self.allocate("holeberry-symlink-manual")
        target = self.tmp / "outside-state.json"
        target.write_text(json.dumps(symlink_state.state), encoding="utf-8")
        symlink_state.state_path.unlink()
        symlink_state.state_path.symlink_to(target)
        with self.assertRaises(harness.StateError):
            self.teardown(symlink_state.state["project"])
        self.assertEqual(self.mutations(), [])
        self.assertTrue(symlink_state.state_path.is_symlink())

        directory_state = self.allocate("holeberry-dir-link-manual")
        moved_runtime = self.tmp / "moved manual runtime"
        directory_state.runtime_dir.rename(moved_runtime)
        directory_state.runtime_dir.symlink_to(moved_runtime, target_is_directory=True)
        with self.assertRaises(harness.StateError):
            self.teardown(directory_state.state["project"])
        self.assertEqual(self.mutations(), [])

        run_state = harness.allocate_run(worktree=self.worktree, secrets=self.secrets())
        tampered_project = f"holeberry-run-{'b' * 8}"
        self.rewrite_state(run_state, project=tampered_project)
        self.docker_log_path.unlink(missing_ok=True)
        with self.assertRaises(harness.StateError):
            self.teardown(tampered_project)
        self.assertEqual(self.docker_calls(), [])
        self.assertTrue(run_state.state_path.exists())
        with self.assertRaises(harness.StateError):
            self.teardown(run_state.state["project"])
        self.assertEqual(self.docker_calls(), [])
        self.assertTrue(run_state.state_path.exists())

    def test_missing_project_is_noop(self):
        allocation = self.allocate("holeberry-empty-manual")
        summary, _, _ = self.teardown(allocation.state["project"])
        self.assertEqual(summary["containers"], [])
        self.assertEqual(summary["networks"], [])
        self.assertEqual(summary["volumes"], [])
        self.assertFalse(allocation.state_path.exists())
        self.assertEqual(self.mutations(), [])

        absent_summary, _, _ = self.teardown("holeberry-absent-manual")
        self.assertEqual(absent_summary["containers"], [])
        self.assertEqual(self.mutations(), [])

        # A failed lookup is not proof of absence.
        lookup_state = self.allocate("holeberry-lookup-manual")
        self.write_scenario(lookup_failure="containers")
        with self.assertRaises(harness.HarnessError):
            self.teardown(lookup_state.state["project"])
        self.assertTrue(lookup_state.state_path.exists())
        self.assertEqual(self.mutations(), [])

        self.docker_log_path.unlink(missing_ok=True)
        self.write_scenario(lookup_failure="networks")
        with self.assertRaises(harness.HarnessError):
            self.teardown("holeberry-absent-lookup-manual")
        self.assertEqual(self.mutations(), [])

        context_state = self.allocate("holeberry-context-manual")
        self.write_scenario(context_failure=True)
        self.docker_log_path.unlink(missing_ok=True)
        with self.assertRaises(harness.PreflightError):
            self.teardown(context_state.state["project"])
        self.assertTrue(context_state.state_path.exists())
        self.assertEqual(self.mutations(), [])
        self.assertEqual(len(self.docker_calls()), 1)

        self.docker_log_path.unlink(missing_ok=True)
        for endpoint in (
            "ssh://remote.example:22",
            "tcp://10.0.0.5:2375",
            "tcp://127.0.0.1:2375",
            "npipe:////./pipe/docker_engine",
        ):
            with self.assertRaises(harness.PreflightError):
                self.teardown("holeberry-remote-manual", env={"DOCKER_HOST": endpoint})
        self.assertEqual(self.docker_calls(), [])
        self.assertEqual(self.mutations(), [])

        unix_state = self.allocate("holeberry-unix-manual")
        self.write_scenario()
        summary, _, _ = self.teardown(
            unix_state.state["project"],
            env={"DOCKER_HOST": "unix:///var/run/docker.sock"},
        )
        self.assertEqual(summary["containers"], [])
        self.assertFalse(unix_state.state_path.exists())

        daemon_state = self.allocate("holeberry-daemon-manual")
        self.write_scenario(daemon_failure=True)
        with self.assertRaises(harness.PreflightError) as context:
            self.teardown(daemon_state.state["project"])
        self.assertIn("daemon is unavailable", str(context.exception))
        self.assertTrue(daemon_state.state_path.exists())
        self.assertEqual(self.mutations(), [])

    def test_chunk_boundary_and_url_redaction(self):
        secret = "Fixture+Secret/With=Spaces & café"
        emitter = self.tmp / "emit.py"
        emitter.write_text(
            textwrap.dedent(
                """\
                import json
                import re
                import sys
                import time
                from urllib.parse import quote, quote_plus
                from xml.sax.saxutils import escape

                secret = sys.argv[1]
                limit = int(sys.argv[2])

                def write(text):
                    sys.stdout.write(text)
                    sys.stdout.flush()

                lower_url = re.sub(
                    r"%[0-9A-F]{2}",
                    lambda match: match.group(0).lower(),
                    quote(secret, safe=""),
                )
                write("split-" + secret[:4])
                time.sleep(0.05)
                write(secret[4:] + "\\n")
                write("url=" + quote(secret, safe="") + "\\n")
                write("url-lower=" + lower_url + "\\n")
                write("form=" + quote_plus(secret) + "\\n")
                write("json=" + json.dumps(secret) + "\\n")
                write("xml=" + escape(secret) + "\\n")
                write("legacy=https://pihole/admin/api.php?auth=LEGACYTOKEN&x=1\\n")
                write('{"sid": "SIDVALUE123", "status": "enabled"}\\n')
                write("Cookie: SID=SIDCOOKIE456; theme=auto\\n")
                write("Authorization: Bearer BEARERTOKEN789\\n")
                write("X" * (limit + 1024) + "\\n")
                write("after-oversized\\n")
                write("tail-" + secret)
                """
            ),
            encoding="utf-8",
        )

        stdout = io.StringIO()
        stderr = io.StringIO()
        log_path = self.tmp / "redaction.log"
        status = harness.run_supervised(
            [sys.executable, str(emitter), secret, str(harness.MAX_RECORD_BYTES)],
            timeout=10,
            log_path=log_path,
            secrets=[secret],
            stdout=stdout,
            stderr=stderr,
        )
        self.assertEqual(status, 0)
        output = stdout.getvalue()
        self.assert_redacted(output, secret)
        self.assertIn(harness.OMITTED_MARKER, output)
        self.assertNotIn("X" * 1000, output)
        self.assertIn("after-oversized", output)
        self.assertIn("tail-", output)
        self.assert_redacted(log_path.read_text(encoding="utf-8"), secret)

        # An oversized record ending at EOF is also replaced exactly once.
        stdout = io.StringIO()
        eof_log = self.tmp / "oversized-eof.log"
        status = harness.run_supervised(
            [
                sys.executable,
                "-c",
                "import sys; sys.stdout.write('Y' * 70000)",
            ],
            timeout=10,
            log_path=eof_log,
            stdout=stdout,
            stderr=io.StringIO(),
        )
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue().count(harness.OMITTED_MARKER), 1)
        self.assertNotIn("Y" * 1000, stdout.getvalue())
        self.assertIn(harness.OMITTED_MARKER, eof_log.read_text(encoding="utf-8"))

    def test_command_exit_survives_logging(self):
        command = [
            sys.executable,
            "-c",
            "import sys; print('one'); print('two'); sys.stderr.write('err\\n'); raise SystemExit(7)",
        ]

        stdout = io.StringIO()
        stderr = io.StringIO()
        log_path = self.tmp / "run.log"
        status = harness.run_supervised(
            command,
            timeout=10,
            log_path=log_path,
            stdout=stdout,
            stderr=stderr,
        )
        self.assertEqual(status, 7)
        self.assertIn("one", stdout.getvalue())
        self.assertIn("err", stderr.getvalue())
        log_text = log_path.read_text(encoding="utf-8")
        self.assertIn("one", log_text)
        self.assertIn("two", log_text)
        self.assertIn("err", log_text)

        broken_log = self.tmp / "missing dir" / "run.log"
        stdout = io.StringIO()
        stderr = io.StringIO()
        status = harness.run_supervised(
            command,
            timeout=10,
            log_path=broken_log,
            stdout=stdout,
            stderr=stderr,
        )
        self.assertEqual(status, 7)
        self.assertIn("one", stdout.getvalue())
        self.assertIn("sink=log", stderr.getvalue())

        sink_only = [
            sys.executable,
            "-c",
            "print('sink-only')",
        ]
        status = harness.run_supervised(
            sink_only,
            timeout=10,
            log_path=broken_log,
            stdout=io.StringIO(),
            stderr=io.StringIO(),
        )
        self.assertEqual(status, 1)

        working_log = self.tmp / "broken-stdout.log"
        stderr = io.StringIO()
        status = harness.run_supervised(
            sink_only,
            timeout=10,
            log_path=working_log,
            stdout=BrokenSink(),
            stderr=stderr,
        )
        self.assertEqual(status, 1)
        self.assertIn("sink=stdout", stderr.getvalue())
        log_text = working_log.read_text(encoding="utf-8")
        self.assertIn("sink-only", log_text)
        self.assertIn("phase=command", log_text)

        # A stalled sink must not let a successful child produce a success line.
        delayed_log = self.tmp / "delayed-final.log"
        delayed_status = harness.run_supervised(
            [sys.executable, "-c", "print('final-check')"],
            timeout=5,
            log_path=delayed_log,
            stdout=DelayedSink(1.5),
            stderr=io.StringIO(),
        )
        self.assertEqual(delayed_status, 1)
        log_text = delayed_log.read_text(encoding="utf-8")
        self.assertIn("final-check", log_text)
        self.assertIn("phase=command", log_text)
        self.assertIn("status=failed", log_text)
        self.assertIn("exit=1", log_text)

    def test_timeout_terminates_owned_child(self):
        script = self.tmp / "timeout-child.py"
        script.write_text(
            textwrap.dedent(
                """\
                import os
                import signal
                import subprocess
                import sys
                import time

                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                child = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
                    ]
                )
                with open(sys.argv[1], "w", encoding="utf-8") as handle:
                    handle.write(f"{os.getpid()} {child.pid}\\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                while True:
                    time.sleep(1)
                """
            ),
            encoding="utf-8",
        )
        pid_file = self.tmp / "owned-pids.txt"
        sentinel = subprocess.Popen(["sleep", "30"])
        self.addCleanup(self._stop_process, sentinel)

        started = time.monotonic()
        status = harness.run_supervised(
            [sys.executable, str(script), str(pid_file)],
            timeout=0.5,
            log_path=self.tmp / "timeout.log",
            stdout=io.StringIO(),
            stderr=io.StringIO(),
            termination_grace=0.5,
        )
        elapsed = time.monotonic() - started

        self.assertEqual(status, 124)
        self.assertLess(elapsed, 10)
        self.assertIsNone(sentinel.poll())
        pids = [int(part) for part in pid_file.read_text(encoding="utf-8").split()]
        self.assertEqual(len(pids), 2)
        for pid in pids:
            self.assertTrue(self._wait_until_gone(pid, timeout=5), f"pid {pid} survived")
        self.addCleanup(self._kill_if_alive, pids)

    def test_paths_and_runs_are_isolated(self):
        first = self.allocate("holeberry-paths-one")
        second = self.allocate("holeberry-paths-two")
        self.assertNotEqual(first.runtime_dir, second.runtime_dir)
        runtime_root = harness.canonical_worktree(self.worktree) / ".integration"
        self.assertIn(runtime_root, first.runtime_dir.parents)
        self.assertEqual(first.runtime_dir.parent, runtime_root / "manual")
        self.assertEqual(
            stat.S_IMODE(first.runtime_dir.stat().st_mode),
            0o700,
        )
        self.assertEqual(stat.S_IMODE(first.state_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(first.secrets_path.stat().st_mode), 0o600)
        self.assertIn(" ", str(first.state_path))
        self.assertNotIn("v5-fixture-secret", first.state_path.read_text(encoding="utf-8"))
        self.assertEqual(
            json.loads(first.secrets_path.read_text(encoding="utf-8"))["v5_password"],
            "v5-fixture-secret",
        )
        state = json.loads(first.state_path.read_text(encoding="utf-8"))
        for key in (
            "schema_version",
            "run_id",
            "worktree",
            "project",
            "ownership_token",
            "artifact_directory",
            "urls",
        ):
            self.assertIn(key, state)

        other_worktree = self.tmp / "other worktree"
        other_worktree.mkdir()
        default_project = harness.default_manual_project(self.worktree)
        self.assertEqual(default_project, harness.default_manual_project(self.worktree))
        self.assertNotEqual(default_project, harness.default_manual_project(other_worktree))
        self.assertTrue(default_project.startswith("holeberry-"))
        harness.validate_project_name(default_project)
        with self.assertRaises(harness.StateError):
            self.allocate(first.state["project"])

        for invalid in ("", "holeberry-", "Holeberry-test", "other", "holeberry-../escape", "x" * 70):
            with self.assertRaises(harness.StateError):
                harness.validate_project_name(invalid)

        concurrent_project = "holeberry-concurrent-manual"

        def attempt(_):
            try:
                return self.allocate(concurrent_project)
            except harness.StateError as error:
                return error

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, range(2)))
        self.assertEqual(
            sum(isinstance(result, harness.Allocation) for result in results),
            1,
        )

        runs = [harness.allocate_run(worktree=self.worktree, secrets=self.secrets()) for _ in range(3)]
        self.assertEqual(len({run.runtime_dir for run in runs}), 3)
        self.assertEqual(len({run.state["project"] for run in runs}), 3)
        for run in runs:
            self.assertEqual(run.runtime_dir.parent, runtime_root / "runs")
            self.assertEqual(run.state["mode"], "automatic")
            self.assertEqual(stat.S_IMODE(run.runtime_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(run.secrets_path.stat().st_mode), 0o600)
            self.assertTrue(run.artifact_directory.is_dir())
            self.assertTrue(0 < run.state["ports"]["v5"] < 65536)
            self.assertTrue(0 < run.state["ports"]["v6"] < 65536)

        custom = self.tmp / "custom artifacts dir"
        custom_allocation = harness.allocate_run(
            worktree=self.worktree,
            artifacts=custom,
            secrets=self.secrets(),
        )
        self.assertEqual(custom_allocation.artifact_directory, custom.resolve())
        self.assertEqual(custom_allocation.state["artifact_directory"], str(custom.resolve()))
        self.assertEqual(stat.S_IMODE(custom.stat().st_mode), 0o700)
        self.assertIn(runtime_root, custom_allocation.runtime_dir.parents)

        existing = self.tmp / "existing artifacts"
        existing.mkdir()
        sentinel = existing / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        with self.assertRaises(harness.StateError):
            harness.allocate_run(worktree=self.worktree, artifacts=existing, secrets=self.secrets())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

        with self.assertRaises(harness.StateError):
            harness.allocate_run(
                worktree=self.worktree,
                artifacts=self.tmp / "missing parent" / "artifacts",
                secrets=self.secrets(),
            )

    def test_teardown_removes_only_validated_project_resources(self):
        allocation = self.allocate("holeberry-remove-manual")
        labels = self.labels(allocation)
        self.write_scenario(
            containers={"container-a": labels, "container-b": labels},
            networks={"network-a": labels},
            volumes={"volume-a": labels, "volume-b": labels},
        )

        summary, _, _ = self.teardown(allocation.state["project"])

        self.assertEqual(summary["containers"], ["container-a", "container-b"])
        self.assertEqual(summary["networks"], ["network-a"])
        self.assertEqual(summary["volumes"], ["volume-a", "volume-b"])
        self.assertFalse(allocation.state_path.exists())
        self.assertEqual(
            self.mutations(),
            [
                ["rm", "--force", "container-a"],
                ["rm", "--force", "container-b"],
                ["network", "rm", "network-a"],
                ["volume", "rm", "volume-a"],
                ["volume", "rm", "volume-b"],
            ],
        )

    def test_teardown_failure_retains_state(self):
        allocation = self.allocate("holeberry-cleanup-manual")
        labels = self.labels(allocation)
        self.write_scenario(
            containers={"container-a": labels},
            networks={"network-a": labels},
            volumes={"volume-a": labels},
            remove_failure=["container-a"],
        )

        with self.assertRaises(harness.HarnessError) as context:
            self.teardown(allocation.state["project"])

        self.assertTrue(allocation.state_path.exists())
        self.assertTrue(allocation.secrets_path.exists())
        self.assertIn("container-a", str(context.exception))
        mutations = self.mutations()
        self.assertIn(["rm", "--force", "container-a"], mutations)
        self.assertTrue(
            any(args[:2] == ["network", "rm"] for args in mutations),
            "teardown should still attempt the remaining owned resources",
        )
        self.assertTrue(
            any(args[:2] == ["volume", "rm"] for args in mutations),
            "teardown should still attempt the remaining owned resources",
        )

    def test_lifecycle_diagnostics_redact_registered_secrets(self):
        leak = "fixture-visible-secret"
        allocation = harness.allocate_manual(
            worktree=self.worktree,
            project="holeberry-secret-manual",
            secrets={"v5_password": leak, "v6_password": "v6-other-secret"},
        )
        project = allocation.state["project"]

        tainted = self.labels(allocation, **{harness.LABEL_WORKTREE: f"worktree-{leak}"})
        self.write_scenario(containers={"container-a": tainted})
        stdout = io.StringIO()
        stderr = io.StringIO()
        with self.assertRaises(harness.OwnershipError) as context:
            harness.teardown_project(
                project,
                worktree=self.worktree,
                env={},
                stdout=stdout,
                stderr=stderr,
            )
        combined = stdout.getvalue() + stderr.getvalue() + str(context.exception)
        self.assertNotIn(leak, combined)
        self.assertIn(harness.REDACTED, combined)
        self.assertEqual(self.mutations(), [])
        self.assertTrue(allocation.state_path.exists())

        self.write_scenario(
            lookup_failure="containers",
            lookup_stderr=f"lookup failed with {leak}",
        )
        self.docker_log_path.unlink(missing_ok=True)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with self.assertRaises(harness.HarnessError) as context:
            harness.teardown_project(
                project,
                worktree=self.worktree,
                env={},
                stdout=stdout,
                stderr=stderr,
            )
        combined = stdout.getvalue() + stderr.getvalue() + str(context.exception)
        self.assertNotIn(leak, combined)
        self.assertIn(harness.REDACTED, combined)
        self.assertEqual(self.mutations(), [])
        self.assertTrue(allocation.state_path.exists())

        allocation.secrets_path.unlink()
        self.docker_log_path.unlink(missing_ok=True)
        with self.assertRaises(harness.StateError):
            self.teardown(project)
        self.assertEqual(self.docker_calls(), [])
        self.assertTrue(allocation.state_path.exists())

    def test_docker_lookup_capture_is_bounded(self):
        allocation = self.allocate("holeberry-capture-manual")
        self.write_scenario(huge_lookup=True, huge_lookup_bytes=400000)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with self.assertRaises(harness.HarnessError) as context:
            harness.teardown_project(
                allocation.state["project"],
                worktree=self.worktree,
                env={},
                stdout=stdout,
                stderr=stderr,
            )
        message = str(context.exception)
        self.assertIn("output", message.lower())
        self.assertLess(len(message), 2000)
        self.assertEqual(self.mutations(), [])
        self.assertTrue(allocation.state_path.exists())

    def test_docker_timeout_precedence_and_cleanup_continues(self):
        allocation = self.allocate("holeberry-timeout-manual")
        good = self.labels(allocation)
        self.write_scenario(
            containers={
                "container-fail": good,
                "container-slow": good,
                "container-after": good,
            },
            networks={"network-a": good},
            volumes={"volume-a": good},
            remove_failure=["container-fail"],
            remove_delay={"container-slow": 2.0},
        )
        with mock.patch.object(harness, "DOCKER_OPERATION_TIMEOUT", 0.2), mock.patch.object(
            harness, "DOCKER_TERMINATION_GRACE", 0.1, create=True
        ):
            with self.assertRaises(harness.HarnessError) as context:
                self.teardown(allocation.state["project"])
        self.assertEqual(context.exception.exit_code, 1)
        message = str(context.exception)
        self.assertIn("container-fail", message)
        self.assertIn("container-slow", message)
        mutations = self.mutations()
        self.assertIn(["rm", "--force", "container-after"], mutations)
        self.assertTrue(any(args[:2] == ["network", "rm"] for args in mutations))
        self.assertTrue(any(args[:2] == ["volume", "rm"] for args in mutations))
        self.assertTrue(allocation.state_path.exists())

        timeout_only = self.allocate("holeberry-timeout-only-manual")
        labels = self.labels(timeout_only)
        self.docker_log_path.unlink(missing_ok=True)
        self.write_scenario(
            containers={"container-slow": labels},
            networks={"network-a": labels},
            volumes={"volume-a": labels},
            remove_delay={"container-slow": 2.0},
        )
        with mock.patch.object(harness, "DOCKER_OPERATION_TIMEOUT", 0.2), mock.patch.object(
            harness, "DOCKER_TERMINATION_GRACE", 0.1, create=True
        ):
            with self.assertRaises(harness.HarnessError) as context:
                self.teardown(timeout_only.state["project"])
        self.assertEqual(context.exception.exit_code, 124)
        mutations = self.mutations()
        self.assertTrue(any(args[:2] == ["network", "rm"] for args in mutations))
        self.assertTrue(any(args[:2] == ["volume", "rm"] for args in mutations))
        self.assertTrue(timeout_only.state_path.exists())

    def test_docker_supervision_kills_descendants(self):
        allocation = self.allocate("holeberry-descendant-manual")
        labels = self.labels(allocation)
        pid_file = self.tmp / "docker-descendants.txt"
        self.write_scenario(
            containers={"container-spawner": labels},
            remove_delay={"container-spawner": 5.0},
            spawn_child=["container-spawner"],
            spawn_child_delay=2.0,
            spawn_pid_file=str(pid_file),
        )
        started = time.monotonic()
        with mock.patch.object(harness, "DOCKER_OPERATION_TIMEOUT", 0.2), mock.patch.object(
            harness, "DOCKER_TERMINATION_GRACE", 0.1, create=True
        ):
            with self.assertRaises(harness.HarnessError) as context:
                self.teardown(allocation.state["project"])
        elapsed = time.monotonic() - started
        self.assertEqual(context.exception.exit_code, 124)
        self.assertLess(elapsed, 4.0)
        self.assertTrue(allocation.state_path.exists())
        pids = [
            int(line)
            for line in pid_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        self.assertEqual(len(pids), 1)
        self.assertTrue(self._wait_until_gone(pids[0], timeout=5))
        self.addCleanup(self._kill_if_alive, pids)

    def test_delayed_sink_keeps_deadline_bounded(self):
        stdout = DelayedSink(0.7)
        stderr = io.StringIO()
        command = [
            sys.executable,
            "-c",
            "import time; print('hello', flush=True); time.sleep(0.3)",
        ]
        started = time.monotonic()
        status = harness.run_supervised(
            command,
            timeout=0.1,
            log_path=self.tmp / "delayed-sink.log",
            stdout=stdout,
            stderr=stderr,
            termination_grace=0.1,
        )
        elapsed = time.monotonic() - started
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 3.0)
        self.assertIn("hello", "".join(stdout.text))

    def test_blocked_sink_keeps_deadline_bounded(self):
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b"x" * 65536)
        except BlockingIOError:
            pass
        os.set_blocking(write_fd, True)
        blocked = os.fdopen(write_fd, "w", encoding="utf-8")
        self.addCleanup(self._close_quietly, blocked)
        stderr = io.StringIO()
        command = [
            sys.executable,
            "-c",
            "import time; print('blocked', flush=True); time.sleep(0.5)",
        ]
        started = time.monotonic()
        try:
            status = harness.run_supervised(
                command,
                timeout=0.1,
                log_path=self.tmp / "blocked-sink.log",
                stdout=blocked,
                stderr=stderr,
                termination_grace=0.1,
            )
        finally:
            os.close(read_fd)
        elapsed = time.monotonic() - started
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 4.0)
        self.assertIn("sink=stdout", stderr.getvalue())

    def test_teardown_output_failure_returns_nonzero(self):
        allocation = self.allocate("holeberry-output-manual")
        self.write_scenario()
        stderr = io.StringIO()
        with self.assertRaises(harness.HarnessError) as context:
            harness.teardown_project(
                allocation.state["project"],
                worktree=self.worktree,
                env={},
                stdout=DelayedSink(1.5),
                stderr=stderr,
            )
        self.assertEqual(context.exception.exit_code, 1)
        self.assertIn("output", str(context.exception).lower())
        self.assertFalse(allocation.state_path.exists())
        self.assertIn("sink=stdout", stderr.getvalue())

    def test_healthy_output_burst_delivers_all_lines(self):
        command = [
            sys.executable,
            "-c",
            "import sys\n"
            "for index in range(1000):\n"
            "    print(f'line-{index:04d}')\n",
        ]
        stdout = io.StringIO()
        stderr = io.StringIO()
        log_path = self.tmp / "burst.log"
        status = harness.run_supervised(
            command,
            timeout=30,
            log_path=log_path,
            stdout=stdout,
            stderr=stderr,
        )
        expected = [f"line-{index:04d}" for index in range(1000)]
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue().splitlines(), expected)
        self.assertEqual(log_path.read_text(encoding="utf-8").splitlines()[:1000], expected)

    def test_closeable_blocked_sink_close_is_bounded(self):
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b"x" * 65536)
        except BlockingIOError:
            pass
        os.set_blocking(write_fd, True)
        stream = os.fdopen(write_fd, "w", encoding="utf-8")
        sink = harness.OutputSink("log", stream=stream, closeable=True)
        self.assertTrue(sink.write("blocked\n"))
        time.sleep(0.1)

        closed = False
        lock = threading.Lock()

        def close_reader():
            nonlocal closed
            with lock:
                if closed:
                    return
                closed = True
            try:
                os.close(read_fd)
            except OSError:
                pass

        timer = threading.Timer(0.5, close_reader)
        timer.start()
        started = time.monotonic()
        try:
            sink.close(0.05)
            elapsed = time.monotonic() - started
        finally:
            timer.cancel()
            close_reader()
            sink.close(1.0)
        timer.join(1.0)
        self.assertLess(elapsed, 0.2)

    def test_lifecycle_redaction_boundaries(self):
        leak = "boundary-secret-" + "X" * 40
        allocation = harness.allocate_manual(
            worktree=self.worktree,
            project="holeberry-boundary-manual",
            secrets={"v5_password": leak, "v6_password": "v6-other-secret"},
        )
        project = allocation.state["project"]

        # Docker detail: the secret straddles the 300-character display cutoff.
        self.write_scenario(
            lookup_failure="containers",
            lookup_stderr="A" * 280 + leak + " tail",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with self.assertRaises(harness.HarnessError) as context:
            harness.teardown_project(
                project,
                worktree=self.worktree,
                env={},
                stdout=stdout,
                stderr=stderr,
            )
        combined = stdout.getvalue() + stderr.getvalue() + str(context.exception)
        self.assertNotIn(leak[:20], combined)
        self.assertIn(harness.REDACTED, combined)

        # Ownership label: the secret straddles the 120-character display cutoff.
        self.write_scenario(
            containers={
                "container-a": self.labels(
                    allocation,
                    **{harness.LABEL_WORKTREE: "W" * 100 + leak + " tail"},
                )
            }
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with self.assertRaises(harness.OwnershipError) as context:
            harness.teardown_project(
                project,
                worktree=self.worktree,
                env={},
                stdout=stdout,
                stderr=stderr,
            )
        combined = stdout.getvalue() + stderr.getvalue() + str(context.exception)
        self.assertNotIn(leak[:20], combined)
        self.assertIn(harness.REDACTED, combined)

        # Capture boundary: the secret is inside an incomplete captured record.
        self.write_scenario(
            lookup_failure="containers",
            lookup_stderr=(
                "A" * 280 + leak + "B" * (harness.MAX_CAPTURE_BYTES + 1000)
            ),
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with self.assertRaises(harness.HarnessError) as context:
            harness.teardown_project(
                project,
                worktree=self.worktree,
                env={},
                stdout=stdout,
                stderr=stderr,
            )
        combined = stdout.getvalue() + stderr.getvalue() + str(context.exception)
        self.assertNotIn(leak[:20], combined)
        self.assertIn("truncated", combined.lower())
        self.assertTrue(allocation.state_path.exists())

    # ------------------------------------------------- Task 2 preparation

    def test_ready_requires_authenticated_fixture_data(self):
        with self.fixture_api() as (api, base_url):
            registry = harness.SecretRegistry(
                [api.v5_token, api.v6_password, api.v6_sid]
            )

            status, payload = harness._http_json(
                "GET",
                f"{base_url}/admin/api.php?auth=wrong-token&list=white",
                registry=registry,
                timeout=2.0,
            )
            self.assertEqual(status, 200)
            self.assertEqual(payload, {})
            with self.assertRaises(harness._NotReady):
                harness._v5_fixture_data(
                    base_url, "wrong-token", registry=registry, timeout=2.0
                )
            with self.assertRaises(harness._NotReady):
                harness._v5_authenticated_status(
                    base_url, "wrong-token", registry=registry, timeout=2.0
                )

            data = harness._v5_fixture_data(
                base_url, api.v5_token, registry=registry, timeout=2.0
            )
            self.assertEqual(set(data["allow"]), set(api.allow))
            self.assertEqual(set(data["deny"]), set(api.deny))
            self.assertEqual(set(data["regex_deny"]), set(api.regex_deny))
            idn_domains = harness._v5_domains(
                {
                    "data": [
                        {
                            "domain": (
                                "b&#252;cher-kva.holeberry.test "
                                "(xn--bcher-kva.holeberry.test)"
                            )
                        }
                    ]
                },
                list_name="white",
            )
            self.assertIn("xn--bcher-kva.holeberry.test", idn_domains)
            self.assertEqual(harness._parse_v5_timestamp(1792959430), 1792959430.0)
            self.assertEqual(harness._parse_v5_timestamp("1792959430"), 1792959430.0)
            self.assertEqual(
                harness._parse_v5_timestamp("1970-01-01 00:00:10"), 10.0
            )
            harness._v5_authenticated_status(
                base_url, api.v5_token, registry=registry, timeout=2.0
            )

            readiness = harness._V6Readiness(
                base_url, api.v6_password, registry=registry
            )
            sid = readiness.session(timeout=2.0)
            self.assertEqual(sid, api.v6_sid)
            self.assertEqual(readiness.session(timeout=2.0), sid)
            self.assertEqual(api.auth_requests, 1)
            harness._v6_authenticated_status(
                base_url, sid, registry=registry, timeout=2.0
            )
            v6_data = harness._v6_fixture_data(
                base_url, sid, registry=registry, timeout=2.0
            )
            self.assertEqual(set(v6_data["allow"]), set(api.allow))
            self.assertEqual(set(v6_data["deny"]), set(api.deny))
            self.assertIsNone(readiness.close(timeout=2.0))
            self.assertEqual(api.logouts, 1)

            failed = harness._V6Readiness(
                base_url, api.v6_password, registry=registry
            )
            sid = failed.session(timeout=2.0)
            api.deny = []
            with self.assertRaises(harness._NotReady):
                harness._v6_fixture_data(
                    base_url, sid, registry=registry, timeout=2.0
                )
            self.assertIsNone(failed.close(timeout=2.0))
            self.assertEqual(api.logouts, 2)

            api.logout_status = 500
            broken = harness._V6Readiness(
                base_url, api.v6_password, registry=registry
            )
            broken.session(timeout=2.0)
            logout_error = broken.close(timeout=2.0)
            self.assertIsInstance(logout_error, harness.HarnessError)
            self.assertIn("logout", str(logout_error).lower())
            self.assertEqual(api.logouts, 3)

    def test_seed_success_exit_without_entry_fails(self):
        registry = harness.SecretRegistry()
        log = harness._PhaseLog(io.StringIO(), io.StringIO())
        self.addCleanup(log.finish)
        complete = {
            "allow": harness.FIXTURE_ALLOW_DOMAINS,
            "deny": harness.FIXTURE_DENY_DOMAINS,
            "regex_deny": harness.FIXTURE_REGEX_DENY_DOMAINS,
        }

        with mock.patch.object(harness, "READINESS_POLL_INTERVAL", 0.05):
            with self.assertRaises(harness.HarnessError) as context:
                harness._seed_and_verify(
                    "v5",
                    run_seed=lambda: 0,
                    read_fixtures=lambda: {
                        "allow": (harness.FIXTURE_ALLOW_DOMAINS[0],),
                        "deny": (),
                        "regex_deny": (),
                    },
                    deadline=time.monotonic() + 0.5,
                    registry=registry,
                    log=log,
                    interval=0.05,
                )
            self.assertEqual(context.exception.exit_code, 124)
            self.assertIn("fixture", str(context.exception).lower())

            result = harness._seed_and_verify(
                "v5",
                run_seed=lambda: 0,
                read_fixtures=lambda: complete,
                deadline=time.monotonic() + 0.5,
                registry=registry,
                log=log,
                interval=0.05,
            )
            self.assertEqual(result, complete)

        with self.assertRaises(harness.HarnessError) as context:
            harness._seed_and_verify(
                "v6",
                run_seed=lambda: 7,
                read_fixtures=lambda: self.fail("must not verify after seed failure"),
                deadline=time.monotonic() + 0.5,
                registry=registry,
                log=log,
            )
        self.assertEqual(context.exception.exit_code, 7)
        self.assertIn("seed", str(context.exception).lower())

    def test_readiness_deadline_is_bounded(self):
        registry = harness.SecretRegistry()
        attempts = []

        def never_ready():
            attempts.append(time.monotonic())
            raise harness._NotReady("service is not ready")

        started = time.monotonic()
        with self.assertRaises(harness.HarnessError) as context:
            harness._poll_until(
                never_ready,
                deadline=started + 0.2,
                interval=0.05,
                phase="readiness-v5",
                action="v5 readiness",
                registry=registry,
            )
        elapsed = time.monotonic() - started
        self.assertEqual(context.exception.exit_code, 124)
        self.assertLess(elapsed, 2.0)
        self.assertGreaterEqual(len(attempts), 1)
        self.assertLessEqual(len(attempts), 20)
        self.assertIn("deadline", str(context.exception).lower())

        attempts.clear()

        def eventually_ready():
            attempts.append(time.monotonic())
            if len(attempts) >= 2:
                return "ready"
            raise harness._NotReady("not yet")

        with self.assertRaises(harness.HarnessError) as context:
            harness._poll_until(
                eventually_ready,
                deadline=time.monotonic() + 0.1,
                interval=0.2,
                phase="readiness-v5",
                action="v5 readiness",
                registry=registry,
            )
        self.assertEqual(context.exception.exit_code, 124)
        self.assertEqual(len(attempts), 1)

        self.assertEqual(
            harness._poll_until(
                lambda: "now",
                deadline=time.monotonic() + 1.0,
                interval=0.05,
                phase="readiness-v5",
                action="v5 readiness",
                registry=registry,
            ),
            "now",
        )

    def test_private_v5_token_extraction(self):
        allocation = self.allocate("holeberry-credentials-manual")
        state = allocation.state
        token = "LEGACYTOKEN0123456789abcdef0123456789abcdef0123456789abcdef01"
        self.write_scenario(v5_setup_vars=f"WEBPASSWORD={token}\n")
        compose_env = self.compose_env(state, allocation.secrets)
        registry = harness.SecretRegistry(allocation.secrets)

        extracted = harness._extract_v5_token(
            project=state["project"],
            compose_env=compose_env,
            registry=registry,
            timeout=5.0,
        )
        self.assertEqual(extracted, token)
        self.assertIn(harness.REDACTED, registry.sanitize(f"value {token} value"))
        self.assertNotIn(token, registry.sanitize("x" * 10))

        harness._store_v5_token(state, worktree=self.worktree, token=token)
        stored = json.loads(allocation.secrets_path.read_text(encoding="utf-8"))
        self.assertEqual(stored["v5_token"], token)
        self.assertEqual(stored["v5_password"], self.secrets()["v5_password"])
        self.assertEqual(stored["v6_password"], self.secrets()["v6_password"])
        self.assertEqual(stat.S_IMODE(allocation.secrets_path.stat().st_mode), 0o600)

        self.write_scenario(
            compose_exec_failure="setupvars",
            compose_exec_stderr=f"cannot read setupVars {token}",
        )
        with self.assertRaises(harness.HarnessError) as context:
            harness._extract_v5_token(
                project=state["project"],
                compose_env=compose_env,
                registry=registry,
                timeout=2.0,
            )
        self.assertNotIn(token, str(context.exception))

        self.write_scenario(v5_setup_vars="WEBPASSWORD=" + ("A" * 300000))
        with self.assertRaises(harness.HarnessError) as context:
            harness._extract_v5_token(
                project=state["project"],
                compose_env=compose_env,
                registry=registry,
                timeout=5.0,
            )
        self.assertIn("truncated", str(context.exception).lower())

        self.write_scenario(v5_setup_vars="SOMETHING_ELSE=1\n")
        with self.assertRaises(harness.HarnessError):
            harness._extract_v5_token(
                project=state["project"],
                compose_env=compose_env,
                registry=registry,
                timeout=2.0,
            )

        self.write_scenario(v5_setup_vars=f"WEBPASSWORD={token}\n", exec_delay=2.0)
        started = time.monotonic()
        with self.assertRaises(harness.HarnessError) as context:
            harness._extract_v5_token(
                project=state["project"],
                compose_env=compose_env,
                registry=registry,
                timeout=0.2,
            )
        self.assertEqual(context.exception.exit_code, 124)
        self.assertLess(time.monotonic() - started, 2.0)

    def test_failed_up_retains_safe_evidence_and_cleans_owned_resources(self):
        project = "holeberry-failed-up-manual"
        marker = self.tmp / "resources after up.json"
        image_ids = {
            image: "sha256:" + character * 64
            for image, character in (
                ("pihole/pihole:2024.07.0", "a"),
                ("pihole/pihole:2026.10.0", "b"),
                ("python:3.13-alpine", "c"),
            )
        }
        self.write_scenario(
            endpoint="unix:///var/run/docker.sock",
            resources_after_up=str(marker),
            compose_failure=["up"],
            compose_images=list(image_ids),
            image_ids=image_ids,
            compose_logs=(
                "startup failed "
                f"password={self.secrets()['v6_password']} "
                "auth=LEGACYTOKEN sid=SIDVALUE123\n"
            ),
            compose_ps="NAME STATUS\npihole-v5 exited\n",
            containers={"unrelated-container": {"com.example": "unrelated"}},
        )
        ports = harness.find_free_loopback_ports(2)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ, {"DOCKER_HOST": "unix:///var/run/docker.sock"}, clear=False
        ), mock.patch.object(
            harness, "repo_root", return_value=self.worktree
        ), mock.patch(
            "sys.stdout", stdout
        ), mock.patch(
            "sys.stderr", stderr
        ):
            status = harness.main(
                [
                    "up",
                    "--project",
                    project,
                    "--v5-port",
                    str(ports[0]),
                    "--v6-port",
                    str(ports[1]),
                ]
            )

        self.assertEqual(status, 1)
        combined = stdout.getvalue() + stderr.getvalue()
        self.assertIn("failed", combined)
        self.assertIn("evidence", combined)
        self.assertNotIn(self.secrets()["v5_password"], combined)
        self.assertNotIn(self.secrets()["v6_password"], combined)
        self.assertNotIn("LEGACYTOKEN", combined)
        self.assertNotIn("SIDVALUE123", combined)

        failures = list((self.worktree / ".integration" / "failures").iterdir())
        self.assertEqual(len(failures), 1)
        self.assertTrue(failures[0].is_dir())
        evidence_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(failures[0].iterdir())
            if path.is_file()
        )
        self.assertIn(harness.REDACTED, evidence_text)
        self.assertNotIn(self.secrets()["v6_password"], evidence_text)
        self.assertNotIn("LEGACYTOKEN", evidence_text)
        self.assertNotIn("SIDVALUE123", evidence_text)
        self.assertIn("pihole-v5 exited", evidence_text)

        self.assertFalse((self.worktree / ".integration" / "manual" / project).exists())
        mutations = self.mutations()
        self.assertIn(["rm", "--force", "container-up"], mutations)
        self.assertIn(["network", "rm", "network-up"], mutations)
        self.assertIn(["volume", "rm", "volume-up"], mutations)
        self.assertFalse(any("unrelated-container" in args for args in mutations))

    def test_automatic_test_remains_unavailable(self):
        artifacts = self.tmp / "must not exist"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            status = harness.main(["test", "--artifacts", str(artifacts)])
        self.assertEqual(status, 1)
        self.assertIn("unavailable", stdout.getvalue() + stderr.getvalue())
        self.assertFalse(artifacts.exists())
        self.assertEqual(self.docker_calls(), [])
        self.assertFalse((self.worktree / ".integration").exists())

    def test_supervised_environment_is_forwarded(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        status = harness.run_supervised(
            [
                sys.executable,
                "-c",
                (
                    "import os, sys; "
                    "sys.exit(0 if os.environ.get('HARNESS_PROBE') == 'forwarded' else 3)"
                ),
            ],
            timeout=10,
            log_path=self.tmp / "environment.log",
            env={"HARNESS_PROBE": "forwarded"},
            stdout=stdout,
            stderr=stderr,
        )
        self.assertEqual(status, 0)

    # ------------------------------------------------- Task 2 fix round 1

    def test_failure_evidence_omits_split_capture_and_bounds_logs(self):
        allocation = self.allocate("holeberry-evidence-manual")
        state = allocation.state
        secret = "SYNTHETIC-ROUND-ONE-SECRET-0123456789"
        registry = harness.SecretRegistry([secret])
        compose_env = self.compose_env(state, allocation.secrets)
        base = self.tmp / "evidence logs"
        base.mkdir()
        logs = harness._PhaseLogs(base)
        big_log = logs.next_path("seed-v5")
        big_log.write_text(
            ("Y" * 1000 + "\n") * 100 + secret + "\n", encoding="utf-8"
        )

        truncated = harness.CapturedResult(
            returncode=0,
            stdout=("prefix-ok\n" + ("😀" * 10000) + secret[:20]),
            stderr="",
            stdout_truncated=True,
            stderr_truncated=False,
            timed_out=False,
            interrupted_signal=None,
            elapsed=0.1,
        )

        def fake_docker(arguments, *, env, phase, timeout=None, termination_grace=None):
            if "logs" in arguments:
                return truncated
            return harness.CapturedResult(
                returncode=0,
                stdout="ps-ok\n",
                stderr="",
                stdout_truncated=False,
                stderr_truncated=False,
                timed_out=False,
                interrupted_signal=None,
                elapsed=0.1,
            )

        with mock.patch.object(harness, "_run_docker", side_effect=fake_docker), mock.patch.object(
            Path, "read_text", side_effect=AssertionError("unbounded log read")
        ):
            evidence = harness._collect_failure_evidence(
                state=state,
                primary=harness.HarnessError("startup failed"),
                compose_env=compose_env,
                registry=registry,
                logs=logs,
                worktree=self.worktree,
            )

        evidence_text = {
            path.name: path.read_text(encoding="utf-8")
            for path in evidence.iterdir()
            if path.is_file()
        }
        combined = "\n".join(evidence_text.values())
        self.assertNotIn(secret[:20], combined)
        self.assertNotIn(secret[:12], combined)
        self.assertIn("prefix-ok", evidence_text["container-logs.txt"])
        self.assertIn("ps-ok", evidence_text["compose-ps.txt"])
        for text in evidence_text.values():
            self.assertLessEqual(
                len(text.encode("utf-8")), harness.MAX_EVIDENCE_BYTES + 200
            )

        # The collector must also tolerate unavailable setup/log objects.
        evidence_without_logs = harness._collect_failure_evidence(
            state=state,
            primary=harness.HarnessError("setup failed"),
            compose_env=None,
            registry=registry,
            logs=None,
            worktree=self.worktree,
        )
        self.assertIn(
            "setup failed",
            (evidence_without_logs / "failure.txt").read_text(encoding="utf-8"),
        )

    def test_http_deadline_rejects_slow_body_and_multi_request_expiry(self):
        registry = harness.SecretRegistry()
        server = _SlowBodyServer(("127.0.0.1", 0), _SlowBodyHandler)
        server.delay = 0.04
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            started = time.monotonic()
            with self.assertRaises(harness._NotReady):
                harness._http_json(
                    "GET",
                    f"http://127.0.0.1:{server.server_address[1]}/",
                    registry=registry,
                    timeout=0.08,
                    deadline=time.monotonic() + 0.12,
                )
            self.assertLess(time.monotonic() - started, 1.0)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2.0)

        with self.fixture_api() as (api, base_url):
            api.delay = 0.08
            started = time.monotonic()
            with self.assertRaises(harness._NotReady):
                harness._v5_fixture_data(
                    base_url,
                    api.v5_token,
                    registry=registry,
                    timeout=0.08,
                    deadline=time.monotonic() + 0.15,
                )
            self.assertLess(time.monotonic() - started, 1.0)

        def late_success():
            time.sleep(0.15)
            return "late"

        with self.assertRaises(harness.HarnessError) as context:
            harness._poll_until(
                late_success,
                deadline=time.monotonic() + 0.1,
                interval=0.05,
                phase="readiness-v5",
                action="late success",
                registry=registry,
            )
        self.assertEqual(context.exception.exit_code, 124)

    def test_sigterm_handler_covers_poll_interval(self):
        probe = self.tmp / "sigterm_probe.py"
        probe.write_text(
            textwrap.dedent(
                f"""\
                import os
                import signal
                import sys
                import threading
                import time
                sys.path.insert(0, {str(INTEGRATION_DIR)!r})
                import harness

                def send():
                    time.sleep(0.15)
                    os.kill(os.getpid(), signal.SIGTERM)

                threading.Thread(target=send, daemon=True).start()

                def attempt():
                    raise harness._NotReady("waiting")

                try:
                    with harness._lifecycle_interrupts():
                        harness._poll_until(
                            attempt,
                            deadline=time.monotonic() + 5,
                            interval=1.0,
                            phase="readiness",
                            action="probe",
                            registry=harness.SecretRegistry(),
                        )
                except harness._Interrupted as error:
                    print(f"interrupted={{error.signum}}")
                    raise SystemExit(0)
                raise SystemExit(9)
                """
            ),
            encoding="utf-8",
        )
        result = subprocess.run(
            [sys.executable, str(probe)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("interrupted=15", result.stdout)

    def test_interrupted_up_runs_scoped_cleanup(self):
        project = "holeberry-sigterm-manual"
        marker = self.tmp / "sigterm resources.json"
        image_ids = {
            "pihole/pihole:2024.07.0": "sha256:" + "a" * 64,
            "pihole/pihole:2026.10.0": "sha256:" + "b" * 64,
            "python:3.13-alpine": "sha256:" + "c" * 64,
        }
        self.write_scenario(
            endpoint="unix:///var/run/docker.sock",
            resources_after_up=str(marker),
            compose_images=list(image_ids),
            image_ids=image_ids,
        )
        ports = harness.find_free_loopback_ports(2)
        stdout = io.StringIO()
        stderr = io.StringIO()

        def interrupted_prepare(**kwargs):
            self.assertTrue(harness._request_active_interrupt(15))
            harness._poll_until(
                lambda: (_ for _ in ()).throw(harness._NotReady("waiting")),
                deadline=time.monotonic() + 5,
                interval=0.05,
                phase="readiness-v5",
                action="readiness probe",
                registry=kwargs["registry"],
            )

        with mock.patch.dict(
            os.environ, {"DOCKER_HOST": "unix:///var/run/docker.sock"}, clear=False
        ), mock.patch.object(
            harness, "repo_root", return_value=self.worktree
        ), mock.patch.object(
            harness, "_prepare_allocation", side_effect=interrupted_prepare
        ), mock.patch(
            "sys.stdout", stdout
        ), mock.patch(
            "sys.stderr", stderr
        ):
            status = harness.main(
                [
                    "up",
                    "--project",
                    project,
                    "--v5-port",
                    str(ports[0]),
                    "--v6-port",
                    str(ports[1]),
                ]
            )

        self.assertEqual(status, 143)
        failures = list((self.worktree / ".integration" / "failures").iterdir())
        self.assertEqual(len(failures), 1)
        self.assertTrue((failures[0] / "failure.txt").is_file())
        self.assertFalse((self.worktree / ".integration" / "manual" / project).exists())
        mutations = self.mutations()
        self.assertIn(["rm", "--force", "container-up"], mutations)
        self.assertIn(["network", "rm", "network-up"], mutations)
        self.assertIn(["volume", "rm", "volume-up"], mutations)

    def test_streamed_nonzero_statuses_are_preserved(self):
        registry = harness.SecretRegistry()
        log = harness._PhaseLog(io.StringIO(), io.StringIO())
        self.addCleanup(log.finish)
        base = self.tmp / "status logs"
        base.mkdir()
        logs = harness._PhaseLogs(base)

        for status in (7, 130, 143):
            with self.assertRaises(harness.HarnessError) as context:
                harness._seed_and_verify(
                    "v5",
                    run_seed=lambda status=status: status,
                    read_fixtures=lambda: self.fail("must not verify"),
                    deadline=time.monotonic() + 1,
                    registry=registry,
                    log=log,
                )
            self.assertEqual(context.exception.exit_code, status)

        with mock.patch.object(harness, "_run_streamed", return_value=143):
            with self.assertRaises(harness.HarnessError) as context:
                harness._compose_up(
                    compose_env={"HARNESS_PROJECT": "holeberry-status-manual"},
                    registry=registry,
                    log=log,
                    stdout=io.StringIO(),
                    stderr=io.StringIO(),
                    logs=logs,
                )
        self.assertEqual(context.exception.exit_code, 143)

        with mock.patch.object(
            harness, "_compose_images", return_value=["image:tag"]
        ), mock.patch.object(
            harness, "_inspect_image", return_value=None
        ), mock.patch.object(
            harness, "_run_streamed", return_value=130
        ):
            with self.assertRaises(harness.HarnessError) as context:
                harness._ensure_images(
                    compose_env={"HARNESS_PROJECT": "holeberry-status-manual"},
                    registry=registry,
                    log=log,
                    stdout=io.StringIO(),
                    stderr=io.StringIO(),
                    logs=logs,
                )
        self.assertEqual(context.exception.exit_code, 130)

    def test_failed_allocated_up_setup_and_late_output_failure_cleanup(self):
        project = "holeberry-log-setup-manual"
        self.write_scenario(endpoint="unix:///var/run/docker.sock")
        ports = harness.find_free_loopback_ports(2)
        original_ensure = harness._ensure_private_dir

        def flaky_ensure(path):
            if Path(path).name == "logs":
                raise harness.StateError("log setup failed")
            return original_ensure(path)

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ, {"DOCKER_HOST": "unix:///var/run/docker.sock"}, clear=False
        ), mock.patch.object(
            harness, "repo_root", return_value=self.worktree
        ), mock.patch.object(
            harness, "_ensure_private_dir", side_effect=flaky_ensure
        ), mock.patch.object(
            harness, "teardown_project", wraps=harness.teardown_project
        ) as teardown_mock, mock.patch(
            "sys.stdout", stdout
        ), mock.patch(
            "sys.stderr", stderr
        ):
            status = harness.main(
                [
                    "up",
                    "--project",
                    project,
                    "--v5-port",
                    str(ports[0]),
                    "--v6-port",
                    str(ports[1]),
                ]
            )

        self.assertEqual(status, 1)
        self.assertTrue(teardown_mock.called)
        self.assertFalse((self.worktree / ".integration" / "manual" / project).exists())
        failures = list((self.worktree / ".integration" / "failures").iterdir())
        self.assertEqual(len(failures), 1)
        self.assertTrue((failures[0] / "failure.txt").is_file())

        late_project = "holeberry-late-output-manual"
        late_ports = harness.find_free_loopback_ports(2)
        self.write_scenario(
            endpoint="unix:///var/run/docker.sock",
            resources_after_up=str(self.tmp / "late resources.json"),
            compose_images=["image:tag"],
            image_ids={"image:tag": "sha256:" + "d" * 64},
        )
        late_sink = LateFailureSink("manual-startup")
        late_stdout = io.StringIO()
        late_stderr = io.StringIO()

        def successful_prepare(**kwargs):
            return harness.Prepared(
                fixtures_path=self.tmp / "fixtures.json",
                fixtures={"schema_version": 1, "lanes": {"v5": {}, "v6": {}}},
                durations={},
            )

        with mock.patch.dict(
            os.environ, {"DOCKER_HOST": "unix:///var/run/docker.sock"}, clear=False
        ), mock.patch.object(
            harness, "repo_root", return_value=self.worktree
        ), mock.patch.object(
            harness, "_ensure_images", return_value={}
        ), mock.patch.object(
            harness, "_compose_up"
        ), mock.patch.object(
            harness, "_prepare_allocation", side_effect=successful_prepare
        ), mock.patch.object(
            harness, "teardown_project", wraps=harness.teardown_project
        ) as late_teardown, mock.patch(
            "sys.stdout", late_sink
        ), mock.patch(
            "sys.stderr", late_stderr
        ):
            late_status = harness.main(
                [
                    "up",
                    "--project",
                    late_project,
                    "--v5-port",
                    str(late_ports[0]),
                    "--v6-port",
                    str(late_ports[1]),
                ]
            )

        self.assertEqual(late_status, 1)
        self.assertTrue(late_teardown.called)
        self.assertFalse(
            (self.worktree / ".integration" / "manual" / late_project).exists()
        )
        late_failures = [
            path
            for path in (self.worktree / ".integration" / "failures").iterdir()
            if path.is_dir()
        ]
        self.assertTrue(late_failures)

    def test_gravity_source_verification_requires_sole_fixture(self):
        allocation = self.allocate("holeberry-gravity-manual")
        state = allocation.state
        compose_env = self.compose_env(state, allocation.secrets)
        registry = harness.SecretRegistry(allocation.secrets)
        valid = (
            "source|http://fixture:8080/hosts\n"
            "gravity|gravity.holeberry.test|http://fixture:8080/hosts\n"
        )
        extra = (
            "source|http://fixture:8080/hosts\n"
            "source|https://other.example/list\n"
            "gravity|gravity.holeberry.test|http://fixture:8080/hosts\n"
        )
        missing_gravity = "source|http://fixture:8080/hosts\n"
        wrong_source = (
            "source|http://fixture:8080/hosts\n"
            "gravity|gravity.holeberry.test|https://other.example/list\n"
        )

        harness._validate_gravity_source_rows("v5", valid)
        for output in (extra, missing_gravity, wrong_source):
            with self.assertRaises(harness.HarnessError):
                harness._validate_gravity_source_rows("v5", output)

        log = harness._PhaseLog(io.StringIO(), io.StringIO())
        self.addCleanup(log.finish)
        complete = {
            "allow": harness.FIXTURE_ALLOW_DOMAINS,
            "deny": harness.FIXTURE_DENY_DOMAINS,
            "regex_deny": harness.FIXTURE_REGEX_DENY_DOMAINS,
        }
        harness._seed_and_verify(
            "v5",
            run_seed=lambda: 0,
            read_fixtures=lambda: complete,
            deadline=time.monotonic() + 1,
            registry=registry,
            log=log,
            interval=0.05,
        )
        self.write_scenario(gravity_rows=extra)
        with self.assertRaises(harness.HarnessError):
            harness._verify_gravity_sources(
                "v5",
                compose_env=compose_env,
                registry=registry,
                deadline=time.monotonic() + 5,
            )
        self.write_scenario(gravity_rows=valid)
        harness._verify_gravity_sources(
            "v5",
            compose_env=compose_env,
            registry=registry,
            deadline=time.monotonic() + 5,
        )

        def captured(**overrides):
            values = {
                "returncode": 0,
                "stdout": valid,
                "stderr": "",
                "stdout_truncated": False,
                "stderr_truncated": False,
                "timed_out": False,
                "interrupted_signal": None,
                "elapsed": 0.1,
            }
            values.update(overrides)
            return harness.CapturedResult(**values)

        for returncode in (7, 130, 143):
            with mock.patch.object(
                harness,
                "_run_docker",
                return_value=captured(returncode=returncode, stdout="", stderr="sqlite failed"),
            ):
                with self.assertRaises(harness.HarnessError) as context:
                    harness._verify_gravity_sources(
                        "v5",
                        compose_env=compose_env,
                        registry=registry,
                        deadline=time.monotonic() + 5,
                    )
            self.assertEqual(context.exception.exit_code, returncode)
            self.assertEqual(context.exception.phase, "gravity-v5")

        with mock.patch.object(
            harness,
            "_run_docker",
            return_value=captured(returncode=124, timed_out=True),
        ):
            with self.assertRaises(harness.HarnessError) as context:
                harness._verify_gravity_sources(
                    "v5",
                    compose_env=compose_env,
                    registry=registry,
                    deadline=time.monotonic() + 5,
                )
        self.assertEqual(context.exception.exit_code, 124)

        with mock.patch.object(
            harness,
            "_run_docker",
            return_value=captured(returncode=143, interrupted_signal=15),
        ):
            with self.assertRaises(harness.HarnessError) as context:
                harness._verify_gravity_sources(
                    "v5",
                    compose_env=compose_env,
                    registry=registry,
                    deadline=time.monotonic() + 5,
                )
        self.assertEqual(context.exception.exit_code, 143)

    def test_repeated_preparation_logs_are_retained(self):
        base = self.tmp / "shared logs"
        base.mkdir()
        first = harness._PhaseLogs(base)
        second = harness._PhaseLogs(base)
        self.assertNotEqual(first.directory, second.directory)

        def write(logs, text):
            path = logs.next_path("seed-v5")
            sink = harness.OutputSink.open_log(path)
            self.assertTrue(sink.write(text))
            sink.close(1.0)
            self.assertIsNone(sink.error)
            return path

        first_path = write(first, "first invocation evidence\n")
        second_path = write(second, "second invocation evidence\n")
        self.assertNotEqual(first_path, second_path)
        self.assertEqual(
            first_path.read_text(encoding="utf-8"), "first invocation evidence\n"
        )
        self.assertEqual(
            second_path.read_text(encoding="utf-8"), "second invocation evidence\n"
        )

    # ------------------------------------------------- Task 2 fix round 2

    @staticmethod
    def _raw_payload(status_line, body, content_type="application/json"):
        return (
            status_line
            + f"Content-Type: {content_type}\r\n".encode()
            + f"Content-Length: {len(body)}\r\n\r\n".encode()
            + body
        )

    @contextlib.contextmanager
    def raw_response_server(self, payload, *, delay=0.0):
        server = _RawResponseServer(("127.0.0.1", 0), _RawResponseHandler)
        server.payload = payload
        server.delay = delay
        server.closed = threading.Event()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server, f"http://127.0.0.1:{server.server_address[1]}/"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2.0)

    def _assert_sigalrm_restored(self, handler):
        self.assertEqual(signal.getsignal(signal.SIGALRM), handler)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))

    def test_http_elapsed_deadline_covers_status_headers_and_body(self):
        registry = harness.SecretRegistry()
        slow_payload = self._raw_payload(
            b"HTTP/1.1 200 OK\r\n",
            b'{"ok":true}',
        )
        # One byte every 20 ms for >2 seconds, with gaps below a 0.08 s
        # socket inactivity timeout.
        with self.raw_response_server(slow_payload, delay=0.02) as (server, base_url):
            started = time.monotonic()
            with self.assertRaises(harness._NotReady):
                harness._http_json(
                    "GET",
                    base_url,
                    registry=registry,
                    timeout=0.08,
                    deadline=time.monotonic() + 0.2,
                )
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 0.75)
            self.assertTrue(server.closed.wait(1.0))

            with self.assertRaises(harness.HarnessError) as context:
                harness._poll_until(
                    lambda: harness._http_json(
                        "GET",
                        base_url,
                        registry=registry,
                        timeout=0.08,
                        deadline=time.monotonic() + 0.2,
                    ),
                    deadline=time.monotonic() + 0.25,
                    interval=0.01,
                    phase="readiness-v5",
                    action="header acquisition",
                    registry=registry,
                )
            self.assertEqual(context.exception.exit_code, 124)

    def test_http_alarm_state_restored_on_success_timeout_and_error(self):
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_timer = signal.getitimer(signal.ITIMER_REAL)
        self.assertEqual(previous_timer, (0.0, 0.0))

        def restore():
            signal.setitimer(signal.ITIMER_REAL, 0.0)
            signal.signal(signal.SIGALRM, previous_handler)

        self.addCleanup(restore)
        registry = harness.SecretRegistry()

        normal = self._raw_payload(b"HTTP/1.1 200 OK\r\n", b'{"ok":true}')
        with self.raw_response_server(normal) as (_server, base_url):
            status, payload = harness._http_json(
                "GET", base_url, registry=registry, timeout=2.0
            )
            self.assertEqual(status, 200)
            self.assertEqual(payload, {"ok": True})
            self._assert_sigalrm_restored(previous_handler)

        invalid = self._raw_payload(b"HTTP/1.1 200 OK\r\n", b"not-json")
        with self.raw_response_server(invalid) as (_server, base_url):
            with self.assertRaises(harness._NotReady):
                harness._http_json(
                    "GET", base_url, registry=registry, timeout=2.0
                )
            self._assert_sigalrm_restored(previous_handler)

        slow_secret = "ALARM-BODY-SECRET-0123456789"
        slow_error = self._raw_payload(
            b"HTTP/1.1 500 Internal Server Error\r\n",
            slow_secret.encode(),
        )
        with self.raw_response_server(slow_error, delay=0.02) as (_server, base_url):
            with self.assertRaises(harness._NotReady) as context:
                harness._http_json(
                    "GET",
                    base_url,
                    registry=registry,
                    timeout=0.08,
                    deadline=time.monotonic() + 0.2,
                )
            self.assertNotIn(slow_secret, str(context.exception))
            self._assert_sigalrm_restored(previous_handler)

        slow = self._raw_payload(b"HTTP/1.1 200 OK\r\n", b'{"ok":true}')
        with self.raw_response_server(slow, delay=0.02) as (_server, base_url):
            with self.assertRaises(harness._NotReady):
                harness._http_json(
                    "GET",
                    base_url,
                    registry=registry,
                    timeout=0.08,
                    deadline=time.monotonic() + 0.2,
                )
            self._assert_sigalrm_restored(previous_handler)

            with harness._lifecycle_interrupts():
                timer = threading.Timer(0.05, harness._request_active_interrupt, args=(15,))
                timer.start()
                try:
                    with self.assertRaises(harness._Interrupted):
                        harness._http_json(
                            "GET",
                            base_url,
                            registry=registry,
                            timeout=2.0,
                            deadline=time.monotonic() + 2.0,
                        )
                finally:
                    timer.cancel()
            self._assert_sigalrm_restored(previous_handler)

        def foreign_handler(_signum, _frame):
            pass

        signal.signal(signal.SIGALRM, foreign_handler)
        signal.setitimer(signal.ITIMER_REAL, 10.0)
        try:
            with self.raw_response_server(normal) as (_server, base_url):
                with self.assertRaises(harness.HarnessError):
                    harness._http_json(
                        "GET", base_url, registry=registry, timeout=2.0
                    )
                remaining, _interval = signal.getitimer(signal.ITIMER_REAL)
                self.assertGreater(remaining, 0.0)
                self.assertEqual(signal.getsignal(signal.SIGALRM), foreign_handler)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0.0)
            signal.signal(signal.SIGALRM, previous_handler)

        result = {}

        with self.raw_response_server(normal) as (server, base_url):
            def call_from_thread():
                try:
                    harness._http_json(
                        "GET", base_url, registry=registry, timeout=2.0
                    )
                except BaseException as error:  # noqa: BLE001
                    result["error"] = error

            worker = threading.Thread(target=call_from_thread)
            worker.start()
            worker.join(5.0)
            self.assertFalse(worker.is_alive())
            self.assertIsInstance(result.get("error"), harness.HarnessError)
            self.assertFalse(server.closed.is_set())

    def test_interrupted_prepare_attempts_all_v6_logouts(self):
        with self.fixture_api() as (api, base_url):
            api.rotate_sids = True
            registry = harness.SecretRegistry([api.v6_password])

            def make_v6():
                v6 = harness._V6Readiness(
                    base_url, api.v6_password, registry=registry
                )
                v6.session(timeout=2, deadline=time.monotonic() + 2)
                v6.invalidate()
                v6.session(timeout=2, deadline=time.monotonic() + 2)
                return v6

            v6 = make_v6()
            api.delete_count = 0
            before = api.delete_count
            with harness._lifecycle_interrupts():
                harness._request_active_interrupt(15)
                api.logout_failures = {0, 1}
                with self.assertRaises(harness.HarnessError) as context:
                    harness._finish_preparation(
                        v6=v6,
                        primary=harness.HarnessError(
                            "preparation failed",
                            phase="fixtures-v5",
                            exit_code=7,
                        ),
                    )
            self.assertEqual(context.exception.exit_code, 7)
            self.assertEqual(api.delete_count - before, 2)
            self.assertNotIn("SID-", str(context.exception))

            api.logout_failures = set()
            v6 = make_v6()
            api.delete_count = 0
            before = api.delete_count
            with harness._lifecycle_interrupts():
                harness._request_active_interrupt(15)
                with self.assertRaises(harness.HarnessError) as context:
                    harness._finish_preparation(v6=v6, primary=None)
            self.assertEqual(context.exception.exit_code, 143)
            self.assertEqual(api.delete_count - before, 2)

            api.logout_failures = {0}
            api.delete_hook = (
                lambda index: harness._request_active_interrupt(15)
                if index == 1
                else None
            )
            v6 = make_v6()
            api.delete_count = 0
            before = api.delete_count
            with harness._lifecycle_interrupts():
                with self.assertRaises(harness.HarnessError) as context:
                    harness._finish_preparation(v6=v6, primary=None)
            self.assertEqual(context.exception.exit_code, 1)
            self.assertEqual(api.delete_count - before, 2)
            api.delete_hook = None
            api.logout_failures = set()

            v6 = make_v6()
            api.delete_count = 0
            before = api.delete_count
            harness._finish_preparation(v6=v6, primary=None)
            self.assertEqual(api.delete_count - before, 2)

    def test_sigterm_during_http_still_logs_out_readiness_sessions(self):
        script_path = self.tmp / "sigterm_http_prepare.py"
        sentinel = self.tmp / "caller project sentinel"
        script = r'''
import json
import os
import signal
import socketserver
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, __DIR__)
import harness


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.auth = 0
        self.deletes = 0


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            data += chunk
        line = data.split(b"\r\n", 1)[0].decode("ascii", "replace")
        method, path, _ = (line.split(" ") + ["", "", ""])[:3]
        state = self.server.state
        if method == "POST" and path == "/api/auth":
            with state.lock:
                state.auth += 1
                sid = "SID-%d" % state.auth
            body = json.dumps({"session": {"sid": sid, "csrf": "CSRF"}}).encode()
            self.request.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
            )
            return
        if method == "DELETE" and path == "/api/auth":
            with state.lock:
                state.deletes += 1
            self.request.sendall(b"HTTP/1.1 204 No Content\r\n\r\n")
            return
        if method == "GET" and path == "/slow":
            try:
                for byte in (
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: 11\r\n\r\n"
                ):
                    self.request.sendall(bytes([byte]))
                    time.sleep(0.02)
                self.request.sendall(b'{"ok":true}')
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            return
        self.request.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


state = State()
server = Server(("127.0.0.1", 0), Handler)
server.state = state
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()
base = "http://127.0.0.1:%d" % server.server_address[1]
sentinel = Path(sys.argv[1])
sentinel.write_text("keep", encoding="utf-8")
registry = harness.SecretRegistry(["fixture-password"])

with harness._lifecycle_interrupts():
    v6 = harness._V6Readiness(base, "fixture-password", registry=registry)
    v6.session(timeout=2, deadline=time.monotonic() + 2)
    v6.invalidate()
    v6.session(timeout=2, deadline=time.monotonic() + 2)
    timer = threading.Timer(0.2, lambda: os.kill(os.getpid(), signal.SIGTERM))
    timer.start()
    started = time.monotonic()
    try:
        harness._http_json(
            "GET",
            base + "/slow",
            registry=registry,
            timeout=5,
            deadline=time.monotonic() + 5,
        )
        print("unexpected_success")
        sys.exit(3)
    except harness._Interrupted as error:
        primary = error
    elapsed = time.monotonic() - started
    try:
        harness._finish_preparation(v6=v6, primary=primary)
        print("unexpected_prepare_success")
        sys.exit(4)
    except harness.HarnessError as error:
        print("status=%d" % error.exit_code)
    print("deletes=%d" % state.deletes)
    print("elapsed=%.3f" % elapsed)
    print("sentinel=%d" % (1 if sentinel.exists() else 0))

server.shutdown()
server.server_close()
server_thread.join(2)
'''
        script_path.write_text(
            script.replace("__DIR__", repr(str(INTEGRATION_DIR))),
            encoding="utf-8",
        )
        result = subprocess.run(
            [sys.executable, str(script_path), str(sentinel)],
            capture_output=True,
            text=True,
            timeout=15,
        )
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("status=143", result.stdout)
        self.assertIn("deletes=2", result.stdout)
        self.assertIn("sentinel=1", result.stdout)
        match = re.search(r"elapsed=([0-9.]+)", result.stdout)
        self.assertIsNotNone(match)
        self.assertLess(float(match.group(1)), 1.0)
        self.assertNotIn("SID-", combined)
        self.assertNotIn("fixture-password", combined)

    def _blocking_stderr(self):
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b"x" * 65536)
        except BlockingIOError:
            pass
        os.set_blocking(write_fd, True)
        stream = os.fdopen(write_fd, "w", encoding="utf-8", buffering=1)
        self.addCleanup(self._close_quietly, stream)
        self.addCleanup(self._close_fd_quietly, read_fd)
        return read_fd, stream

    def _run_up_in_thread(self, arguments, *, timeout=8.0):
        result = {}
        started = time.monotonic()

        def run():
            try:
                result["status"] = harness.main(arguments)
            except BaseException as error:  # noqa: BLE001
                result["error"] = error
            finally:
                result["elapsed"] = time.monotonic() - started

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        thread.join(timeout)
        return thread, result

    def _late_up_scenario(
        self,
        project,
        *,
        stdout,
        stderr,
        prepare=None,
        startup=None,
        log=None,
    ):
        self.write_scenario(endpoint="unix:///var/run/docker.sock")
        ports = harness.find_free_loopback_ports(2)
        arguments = [
            "up",
            "--project",
            project,
            "--v5-port",
            str(ports[0]),
            "--v6-port",
            str(ports[1]),
        ]
        patches = [
            mock.patch.dict(
                os.environ,
                {"DOCKER_HOST": "unix:///var/run/docker.sock"},
                clear=False,
            ),
            mock.patch.object(harness, "repo_root", return_value=self.worktree),
            mock.patch.object(harness, "_ensure_images", return_value={}),
            mock.patch("sys.stdout", stdout),
            mock.patch("sys.stderr", stderr),
        ]
        teardown_mock = mock.MagicMock(wraps=harness.teardown_project)
        patches.insert(3, mock.patch.object(harness, "teardown_project", teardown_mock))
        if prepare is not None:
            patches.append(mock.patch.object(harness, "_prepare_allocation", side_effect=prepare))
        if startup is not None:
            patches.append(mock.patch.object(harness, "_compose_up", side_effect=startup))
        else:
            patches.append(mock.patch.object(harness, "_compose_up"))
        if log is not None:
            original_phase_log = harness._PhaseLog
            calls = {"count": 0}

            def factory(*args, **kwargs):
                calls["count"] += 1
                if calls["count"] == 1:
                    return log
                return original_phase_log(*args, **kwargs)

            patches.append(mock.patch.object(harness, "_PhaseLog", side_effect=factory))
        return arguments, patches, teardown_mock

    def test_late_output_failure_does_not_retry_blocked_stderr(self):
        def prepared(**_kwargs):
            return harness.Prepared(
                fixtures_path=self.tmp / "fixtures.json",
                fixtures={"schema_version": 1, "lanes": {"v5": {}, "v6": {}}},
                durations={},
            )

        read_fd, blocked_stderr = self._blocking_stderr()
        stdout = io.StringIO()
        log = harness._PhaseLog(stdout, blocked_stderr)
        self.assertTrue(log._stderr.write("pre-failed stderr\n"))
        time.sleep(0.05)
        arguments, patches, teardown_mock = self._late_up_scenario(
            "holeberry-late-sink-manual",
            stdout=stdout,
            stderr=blocked_stderr,
            prepare=prepared,
            log=log,
        )
        with contextlib.ExitStack() as stack:
            for patch in patches:
                stack.enter_context(patch)
            thread, result = self._run_up_in_thread(arguments)
            if thread.is_alive():
                os.close(read_fd)
                thread.join(2.0)
        self.assertFalse(thread.is_alive())
        self.assertLess(result.get("elapsed", 99.0), 5.0)
        self.assertEqual(result.get("status"), 1)
        self.assertTrue(teardown_mock.called)
        self.assertFalse(
            (self.worktree / ".integration" / "manual" / "holeberry-late-sink-manual").exists()
        )
        self.assertIn("phase=output status=failed", stdout.getvalue())
        self.assertIn("exit=1", stdout.getvalue())
        failures = list((self.worktree / ".integration" / "failures").iterdir())
        self.assertTrue(failures)
        final_status = [
            path for path in failures[-1].iterdir() if path.name == "final-status.txt"
        ]
        self.assertEqual(len(final_status), 1)
        final_text = final_status[0].read_text(encoding="utf-8")
        self.assertIn("exit=1", final_text)

        read_fd2, blocked_stderr2 = self._blocking_stderr()
        failed_stdout = LateFailureSink("manual-startup")
        log2 = harness._PhaseLog(failed_stdout, blocked_stderr2)
        self.assertTrue(log2._stderr.write("pre-failed stderr\n"))
        time.sleep(0.05)
        arguments2, patches2, teardown_mock2 = self._late_up_scenario(
            "holeberry-late-both-manual",
            stdout=failed_stdout,
            stderr=blocked_stderr2,
            prepare=prepared,
            log=log2,
        )
        with contextlib.ExitStack() as stack:
            for patch in patches2:
                stack.enter_context(patch)
            thread2, result2 = self._run_up_in_thread(arguments2)
            if thread2.is_alive():
                os.close(read_fd2)
                thread2.join(2.0)
        self.assertFalse(thread2.is_alive())
        self.assertLess(result2.get("elapsed", 99.0), 5.0)
        self.assertEqual(result2.get("status"), 1)
        self.assertTrue(teardown_mock2.called)
        self.assertNotIn("phase=output status=failed", "".join(failed_stdout.text))
        failures2 = list((self.worktree / ".integration" / "failures").iterdir())
        self.assertTrue(failures2)
        self.assertTrue(
            any((path / "final-status.txt").is_file() for path in failures2)
        )

        read_fd3, blocked_stderr3 = self._blocking_stderr()
        stdout3 = io.StringIO()
        log3 = harness._PhaseLog(stdout3, blocked_stderr3)
        self.assertTrue(log3._stderr.write("pre-failed stderr\n"))
        time.sleep(0.05)
        arguments3, patches3, teardown_mock3 = self._late_up_scenario(
            "holeberry-late-primary-manual",
            stdout=stdout3,
            stderr=blocked_stderr3,
            prepare=None,
            startup=harness.HarnessError(
                "startup failed", phase="startup", exit_code=7
            ),
            log=log3,
        )
        with contextlib.ExitStack() as stack:
            for patch in patches3:
                stack.enter_context(patch)
            thread3, result3 = self._run_up_in_thread(arguments3)
            if thread3.is_alive():
                os.close(read_fd3)
                thread3.join(2.0)
        self.assertFalse(thread3.is_alive())
        self.assertLess(result3.get("elapsed", 99.0), 5.0)
        self.assertEqual(result3.get("status"), 7)
        self.assertTrue(teardown_mock3.called)
        self.assertIn("exit=7", stdout3.getvalue())
        failures3 = [
            path
            for path in (self.worktree / ".integration" / "failures").iterdir()
            if path.is_dir()
        ]
        final_texts = [
            (path / "final-status.txt").read_text(encoding="utf-8")
            for path in failures3
            if (path / "final-status.txt").is_file()
        ]
        self.assertTrue(any("exit=7" in text for text in final_texts))

    def test_cleanup_signal_precedes_first_logout_error_and_timeout(self):
        with self.fixture_api() as (api, base_url):
            api.rotate_sids = True
            registry = harness.SecretRegistry([api.v6_password])

            def make_v6():
                v6 = harness._V6Readiness(
                    base_url, api.v6_password, registry=registry
                )
                v6.session(timeout=2, deadline=time.monotonic() + 2)
                v6.invalidate()
                v6.session(timeout=2, deadline=time.monotonic() + 2)
                return v6

            api.delete_count = 0
            api.logout_failures = {0}
            api.delete_hook = (
                lambda index: harness._request_active_interrupt(15)
                if index == 0
                else None
            )
            v6 = make_v6()
            with harness._lifecycle_interrupts():
                with self.assertRaises(harness.HarnessError) as context:
                    harness._finish_preparation(v6=v6, primary=None)
            self.assertEqual(context.exception.exit_code, 143)
            self.assertEqual(api.delete_count, 2)
            self.assertIn("secondary", str(context.exception))
            self.assertNotIn("SID-", str(context.exception))

            api.delete_count = 0
            api.logout_failures = set()
            api.logout_delays = {0: 1.0}
            v6 = make_v6()
            started = time.monotonic()
            with harness._lifecycle_interrupts():
                with self.assertRaises(harness.HarnessError) as context:
                    harness._finish_preparation(v6=v6, primary=None, timeout=0.2)
            self.assertEqual(context.exception.exit_code, 143)
            self.assertEqual(api.delete_count, 2)
            self.assertIn("secondary", str(context.exception))
            self.assertLess(time.monotonic() - started, 3.0)

            api.delete_count = 0
            api.logout_delays = {}
            api.logout_failures = {0}
            api.delete_hook = (
                lambda index: harness._request_active_interrupt(15)
                if index == 1
                else None
            )
            v6 = make_v6()
            with harness._lifecycle_interrupts():
                with self.assertRaises(harness.HarnessError) as context:
                    harness._finish_preparation(v6=v6, primary=None)
            self.assertEqual(context.exception.exit_code, 1)
            self.assertEqual(api.delete_count, 2)
            api.delete_hook = None
            api.logout_failures = set()

    # -------------------------------------------------------------- cleanup utilities

    @staticmethod
    def _stop_process(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    @staticmethod
    def _close_quietly(stream):
        try:
            stream.close()
        except Exception:
            pass

    @staticmethod
    def _close_fd_quietly(fd):
        try:
            os.close(fd)
        except OSError:
            pass

    @staticmethod
    def _kill_if_alive(pids):
        for pid in pids:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass

    @staticmethod
    def _wait_until_gone(pid, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.05)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        return False


REPORT_RUNNER_MODULE = "HoleberryCoreIntegrationTests"
REPORT_SUITE_TYPE = "PiholeIntegrationTests"
REPORT_METHODS = {
    "v5": (
        "detectionV5",
        "domainsV5",
        "blockingV5",
        "managedUnblockV5",
        "queryAndGravityV5",
    ),
    "v6": (
        "detectionV6",
        "domainsV6",
        "blockingV6",
        "managedUnblockV6",
        "queryAndGravityV6",
    ),
}


class ReportValidationTests(unittest.TestCase):
    """Focused RED/GREEN tests for the structured integration report contract.

    The XML fixtures below are explicit parser-test data. None of them represents
    an actual integration pass.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="holeberry report test "))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    # ---------------------------------------------------------------- helpers

    def case_xml(
        self,
        version,
        method,
        *,
        suite=None,
        outcome="passed",
        message=None,
        text=None,
        name=None,
    ):
        classname = suite or f"{REPORT_RUNNER_MODULE}.{REPORT_SUITE_TYPE}"
        attributes = (
            f'classname="{html.escape(classname, quote=True)}" '
            f'name="{html.escape(name or method + "()", quote=True)}" time="0.001"'
        )
        if outcome == "skipped":
            return f"<testcase {attributes}><skipped/></testcase>"
        if outcome == "failure":
            detail = html.escape(text or "", quote=True)
            failure_message = html.escape(message or "", quote=True)
            return (
                f'<testcase {attributes}><failure message="{failure_message}">'
                f"{detail}</failure></testcase>"
            )
        if outcome == "error":
            return f'<testcase {attributes}><error message="boom"/></testcase>'
        return f"<testcase {attributes} />"

    def report_xml(self, cases, *, errors=0, tests=None, extra_suites="", truncated=False):
        body = "".join(cases)
        declared = len(cases) if tests is None else tests
        xml = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<testsuites>\n"
            f'  <testsuite name="TestResults" errors="{errors}" tests="{declared}" '
            'failures="0" skipped="0" time="0.01">\n'
            f"    {body}\n"
            "  </testsuite>\n"
            f"{extra_suites}"
            "</testsuites>\n"
        )
        if truncated:
            xml = xml[: len(xml) // 2]
        return xml

    def all_cases(self):
        return [
            self.case_xml(version, method)
            for version in ("v5", "v6")
            for method in REPORT_METHODS[version]
        ]

    def write(self, text, name="report.xml"):
        path = self.tmp / name
        path.write_text(text, encoding="utf-8")
        return path

    def assert_report_error(self, path, *fragments, registry=None):
        with self.assertRaises(harness.ReportError) as context:
            harness.validate_report(path, registry=registry)
        message = str(context.exception)
        for fragment in fragments:
            self.assertIn(fragment, message)
        return message

    # ------------------------------------------------------------ RED/GREEN

    def test_empty_missing_skipped_and_partial_reports_fail(self):
        self.assert_report_error(self.tmp / "absent.xml", "missing")
        self.assert_report_error(self.write(""), "malformed")
        self.assert_report_error(self.write("<testsuites><testsuite>"), "malformed")
        self.assert_report_error(self.write(self.report_xml([])), "no executed")

        skipped = self.all_cases()
        skipped[3] = self.case_xml("v5", "managedUnblockV5", outcome="skipped")
        self.assert_report_error(self.write(self.report_xml(skipped)), "skipped")

        partial = self.all_cases()[:-1]
        self.assert_report_error(self.write(self.report_xml(partial)), "missing")

        duplicate = self.all_cases() + [self.case_xml("v5", "detectionV5")]
        self.assert_report_error(self.write(self.report_xml(duplicate)), "duplicate")

        unknown = self.all_cases() + [self.case_xml("v5", "helperScenario")]
        self.assert_report_error(self.write(self.report_xml(unknown)), "unknown")

        self.assert_report_error(
            self.write(self.report_xml(self.all_cases(), errors=1)), "error"
        )

        unit_only = [
            self.case_xml(
                version,
                method,
                suite=f"HoleberryCoreTests.{REPORT_SUITE_TYPE}",
            )
            for version in ("v5", "v6")
            for method in REPORT_METHODS[version]
        ]
        self.assert_report_error(self.write(self.report_xml(unit_only)), "missing")

        self.assert_report_error(
            self.write(self.report_xml(self.all_cases(), truncated=True)), "malformed"
        )

    def test_failed_case_fails_report(self):
        secret = 'v5&token<value>"quoted"'
        encoded = quote(secret, safe="")
        registry = harness.SecretRegistry({"v5_password": secret})
        cases = self.all_cases()
        cases[0] = self.case_xml(
            "v5",
            "detectionV5",
            outcome="failure",
            message=f"login failed: token={secret}",
            text=f"percent={encoded}",
        )
        path = self.write(self.report_xml(cases))

        message = self.assert_report_error(path, "failed", "[REDACTED]", registry=registry)
        self.assertNotIn(secret, message)
        self.assertNotIn(encoded, message)
        self.assertNotIn(html.escape(secret, quote=True), message)

        # A sanitized failure message is still a failed case.
        with self.assertRaises(harness.ReportError) as context:
            harness.validate_report(path, registry=harness.SecretRegistry())
        self.assertIn("failed", str(context.exception))

        secrets_path = self.write(
            json.dumps({"v5_password": secret}), name="secrets.json"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            status = harness.main(
                [
                    "validate-report",
                    "--xml",
                    str(path),
                    "--secrets",
                    str(secrets_path),
                ]
            )
        self.assertEqual(status, 1)
        output = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn(secret, output)
        self.assertNotIn(encoded, output)
        self.assertIn("phase=report", output)
        self.assertIn("status=failed", output)

    def test_both_versions_required(self):
        v5_only = [self.case_xml("v5", method) for method in REPORT_METHODS["v5"]]
        self.assert_report_error(self.write(self.report_xml(v5_only)), "v6")

        v6_only = [self.case_xml("v6", method) for method in REPORT_METHODS["v6"]]
        self.assert_report_error(self.write(self.report_xml(v6_only)), "v5")

    def test_valid_ten_case_report_passes(self):
        unit_suite = (
            '<testsuite name="Unit" errors="0" tests="1" failures="0" skipped="0">'
            '<testcase classname="HoleberryCoreTests.WordLabelTests" '
            'name="generateDefaultStyle()" />'
            "</testsuite>"
        )
        path = self.write(self.report_xml(self.all_cases(), extra_suites=unit_suite))

        result = harness.validate_report(path)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["tests"], 10)
        self.assertEqual(result["lanes"], {"v5": 5, "v6": 5})

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            status = harness.main(["validate-report", "--xml", str(path)])
        self.assertEqual(status, 0)
        output = stdout.getvalue() + stderr.getvalue()
        self.assertIn("phase=report", output)
        self.assertIn("status=ok", output)
        self.assertIn("tests=10", output)


if __name__ == "__main__":
    unittest.main()
