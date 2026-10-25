"""Lifecycle owner for Holeberry's local Pi-hole integration harness.

The shell entry points only forward to this module. Task 1 provides working
state allocation, ownership validation, Docker preflight/teardown and bounded
supervision; manual startup and automatic scenario orchestration are refused
explicitly until the later tasks supply them.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import html
import ipaddress
import json
import math
import os
import re
import secrets as secrets_module
import shlex
import shutil
import signal
import socket
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Callable, Iterator, Mapping, Sequence, TypeVar
from urllib.parse import urlencode, urlparse

from supervisor import (
    MAX_CAPTURE_BYTES,
    MAX_RECORD_BYTES,
    OMITTED_MARKER,
    READ_CHUNK_BYTES,
    REDACTED,
    SINK_FLUSH_TIMEOUT,
    CapturedResult,
    OutputSink,
    SecretRegistry,
    format_phase,
    run_captured,
    run_supervised,
    sanitize_text,
)

SCHEMA_VERSION = 1
LABEL_PREFIX = "com.holeberry.integration"
LABEL_PROJECT = f"{LABEL_PREFIX}.project"
LABEL_RUN_ID = f"{LABEL_PREFIX}.run-id"
LABEL_WORKTREE = f"{LABEL_PREFIX}.worktree"
LABEL_OWNER = f"{LABEL_PREFIX}.owner"
COMPOSE_PROJECT_LABEL = "com.docker.compose.project"

RUNTIME_DIRNAME = ".integration"
MANUAL_DIRNAME = "manual"
RUNS_DIRNAME = "runs"
FAILURES_DIRNAME = "failures"
DEFAULT_MANUAL_PORTS = {"v5": 18085, "v6": 18086}
DOCKER_OPERATION_TIMEOUT = 10.0
DOCKER_TERMINATION_GRACE = 1.0
SERVICE_READINESS_TIMEOUT = 120.0
FIXTURE_SETUP_TIMEOUT = 120.0
QUERY_VISIBILITY_TIMEOUT = 15.0
IMAGE_PULL_TIMEOUT = 600.0
READINESS_POLL_INTERVAL = 1.0
QUERY_POLL_INTERVAL = 0.5
MAX_HTTP_BODY_BYTES = 256 * 1024
MAX_EVIDENCE_BYTES = 64 * 1024
FIXTURE_URL = "http://fixture:8080/hosts"
FIXTURE_ALLOW_DOMAINS = ("allowed.holeberry.test", "xn--bcher-kva.holeberry.test")
FIXTURE_DENY_DOMAINS = ("denied.holeberry.test",)
FIXTURE_REGEX_DENY_DOMAINS = (r"(^|\.)regex\.holeberry\.test$",)
GRAVITY_QUERY_DOMAIN = "gravity.holeberry.test"
QUERY_INTERVAL_PADDING_SECONDS = 2
V5_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9$./+=_-]{8,512}$")
LANE_SERVICES = {"v5": "pihole-v5", "v6": "pihole-v6"}
LANE_SEED_SCRIPTS = {"v5": "seed-v5.sh", "v6": "seed-v6.sh"}
PROJECT_PATTERN = re.compile(r"^holeberry-[a-z0-9][a-z0-9_-]{0,52}$")
RUN_ID_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
TOKEN_PATTERN = re.compile(r"^[0-9a-f]{32}$")
RESOURCE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


class HarnessError(RuntimeError):
    """A failure with a named harness phase and a process exit status."""

    def __init__(self, message: str, *, phase: str = "harness", exit_code: int = 1):
        super().__init__(message)
        self.phase = phase
        self.exit_code = exit_code


class StateError(HarnessError):
    def __init__(self, message: str):
        super().__init__(message, phase="state")


class PreflightError(HarnessError):
    def __init__(self, message: str):
        super().__init__(message, phase="preflight")


class OwnershipError(HarnessError):
    def __init__(self, message: str):
        super().__init__(message, phase="ownership")


class ReportError(HarnessError):
    """A structured integration report that does not satisfy the contract."""

    def __init__(self, message: str):
        super().__init__(message, phase="report")


@dataclass(frozen=True)
class Allocation:
    state: dict
    runtime_dir: Path
    state_path: Path
    secrets_path: Path
    artifact_directory: Path
    secrets: dict[str, str]


# --------------------------------------------------------------------- paths


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def canonical_worktree(path: str | Path | None = None) -> Path:
    candidate = Path(path) if path is not None else repo_root()
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise StateError(f"invalid worktree path {candidate}: {error}") from error
    if not resolved.is_dir():
        raise StateError(f"worktree path is not a directory: {resolved}")
    return resolved


def runtime_root(worktree: str | Path | None = None) -> Path:
    return canonical_worktree(worktree) / RUNTIME_DIRNAME


def default_manual_project(worktree: str | Path | None = None) -> str:
    canonical = canonical_worktree(worktree)
    digest = hashlib.sha256(str(canonical).encode("utf-8")).hexdigest()[:8]
    return f"holeberry-{digest}-manual"


def validate_project_name(project: str) -> str:
    if not isinstance(project, str) or not PROJECT_PATTERN.fullmatch(project):
        raise StateError(
            f"invalid project name {project!r}; expected holeberry-<lowercase letters, digits, '_' or '-'>"
        )
    return project


def validate_port(port: int, name: str) -> int:
    if isinstance(port, bool) or not isinstance(port, int) or not (1 <= port <= 65535):
        raise HarnessError(f"invalid {name} {port!r}; expected 1-65535", phase="options")
    return port


def _ensure_private_dir(path: Path) -> None:
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise StateError(f"cannot create harness directory {path}: {error}") from error
    if path.is_symlink() or not path.is_dir():
        raise StateError(f"harness path is not a private directory: {path}")
    os.chmod(path, 0o700)


def _ensure_runtime_dirs(worktree: Path) -> Path:
    root = worktree / RUNTIME_DIRNAME
    _ensure_private_dir(root)
    _ensure_private_dir(root / MANUAL_DIRNAME)
    _ensure_private_dir(root / RUNS_DIRNAME)
    return root


def _write_private_json(path: Path, payload: object) -> None:
    data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def _read_json(path: Path) -> object:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _new_run_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{secrets_module.token_hex(4)}"


def _prepare_secrets(secrets: Mapping[str, str] | None) -> dict[str, str]:
    prepared = {str(key): str(value) for key, value in (secrets or {}).items()}
    prepared.setdefault("v5_password", secrets_module.token_urlsafe(24))
    prepared.setdefault("v6_password", secrets_module.token_urlsafe(24))
    return prepared


def _validate_ports(ports: Mapping[str, int] | None) -> dict[str, int]:
    selected = dict(ports or DEFAULT_MANUAL_PORTS)
    if set(selected) != {"v5", "v6"}:
        raise HarnessError("ports must define exactly v5 and v6", phase="options")
    v5 = validate_port(selected["v5"], "v5 port")
    v6 = validate_port(selected["v6"], "v6 port")
    if v5 == v6:
        raise HarnessError("v5 and v6 ports must differ", phase="options")
    return {"v5": v5, "v6": v6}


def find_free_loopback_ports(count: int) -> list[int]:
    for _attempt in range(10):
        sockets: list[socket.socket] = []
        ports: list[int] = []
        try:
            for _ in range(count):
                bound = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sockets.append(bound)
                bound.bind(("127.0.0.1", 0))
                ports.append(bound.getsockname()[1])
        finally:
            for bound in sockets:
                bound.close()
        if len(set(ports)) == count:
            return ports
    raise StateError("could not allocate distinct loopback ports")


def _build_state(
    *,
    mode: str,
    worktree: Path,
    project: str,
    run_id: str,
    ownership_token: str,
    artifact_directory: Path,
    ports: Mapping[str, int],
) -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "mode": mode,
        "run_id": run_id,
        "worktree": str(worktree),
        "project": project,
        "ownership_token": ownership_token,
        "artifact_directory": str(artifact_directory),
        "ports": {"v5": ports["v5"], "v6": ports["v6"]},
        "urls": {
            "v5": f"http://127.0.0.1:{ports['v5']}",
            "v6": f"http://127.0.0.1:{ports['v6']}",
            "fixture": "http://fixture:8080",
        },
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


# --------------------------------------------------------------- allocation


def allocate_manual(
    *,
    worktree: str | Path | None = None,
    project: str | None = None,
    ports: Mapping[str, int] | None = None,
    secrets: Mapping[str, str] | None = None,
) -> Allocation:
    """Create the one-and-only recorded manual project for this worktree."""
    worktree_path = canonical_worktree(worktree)
    chosen_project = validate_project_name(project or default_manual_project(worktree_path))
    selected_ports = _validate_ports(ports)
    root = _ensure_runtime_dirs(worktree_path)

    runtime_dir = root / MANUAL_DIRNAME / chosen_project
    try:
        os.mkdir(runtime_dir, 0o700)
    except FileExistsError as error:
        raise StateError(
            f"manual project {chosen_project} is already recorded; run down before allocating again"
        ) from error
    except OSError as error:
        raise StateError(f"cannot allocate manual project {chosen_project}: {error}") from error

    try:
        os.chmod(runtime_dir, 0o700)
        artifact_directory = runtime_dir / "artifacts"
        os.mkdir(artifact_directory, 0o700)
        os.chmod(artifact_directory, 0o700)
        prepared_secrets = _prepare_secrets(secrets)
        secrets_path = runtime_dir / "secrets.json"
        _write_private_json(secrets_path, prepared_secrets)
        state = _build_state(
            mode="manual",
            worktree=worktree_path,
            project=chosen_project,
            run_id=_new_run_id(),
            ownership_token=secrets_module.token_hex(16),
            artifact_directory=artifact_directory,
            ports=selected_ports,
        )
        state_path = runtime_dir / "state.json"
        _write_private_json(state_path, state)
    except BaseException:
        shutil.rmtree(runtime_dir, ignore_errors=True)
        raise

    return Allocation(
        state=state,
        runtime_dir=runtime_dir,
        state_path=state_path,
        secrets_path=secrets_path,
        artifact_directory=artifact_directory,
        secrets=prepared_secrets,
    )


def _create_custom_artifacts(path: str | Path) -> Path:
    artifact_path = Path(path).expanduser()
    if not artifact_path.is_absolute():
        raise StateError("artifact directory must be an absolute path")
    if artifact_path.exists() or artifact_path.is_symlink():
        raise StateError(f"artifact directory must not already exist: {artifact_path}")
    parent = artifact_path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise StateError(f"artifact parent must be an existing directory: {parent}")
    try:
        os.mkdir(artifact_path, 0o700)
    except OSError as error:
        raise StateError(f"cannot create artifact directory {artifact_path}: {error}") from error
    os.chmod(artifact_path, 0o700)
    return artifact_path.resolve()


def allocate_run(
    *,
    worktree: str | Path | None = None,
    artifacts: str | Path | None = None,
    ports: Mapping[str, int] | None = None,
    secrets: Mapping[str, str] | None = None,
) -> Allocation:
    """Create a private run directory and an exclusively new artifact directory."""
    worktree_path = canonical_worktree(worktree)
    selected_ports = _validate_ports(ports) if ports is not None else None
    root = _ensure_runtime_dirs(worktree_path)

    custom_artifact: Path | None = None
    if artifacts is not None:
        custom_artifact = _create_custom_artifacts(artifacts)

    runtime_dir: Path | None = None
    try:
        for _attempt in range(10):
            run_id = _new_run_id()
            candidate = root / RUNS_DIRNAME / run_id
            try:
                os.mkdir(candidate, 0o700)
            except FileExistsError:
                continue
            runtime_dir = candidate
            break
        if runtime_dir is None:
            raise StateError("could not allocate a unique run directory")

        os.chmod(runtime_dir, 0o700)
        artifact_directory = custom_artifact or (runtime_dir / "artifacts")
        if custom_artifact is None:
            os.mkdir(artifact_directory, 0o700)
            os.chmod(artifact_directory, 0o700)

        selected_ports = (
            selected_ports
            if selected_ports is not None
            else dict(zip(("v5", "v6"), find_free_loopback_ports(2)))
        )
        prepared_secrets = _prepare_secrets(secrets)
        secrets_path = runtime_dir / "secrets.json"
        _write_private_json(secrets_path, prepared_secrets)
        state = _build_state(
            mode="automatic",
            worktree=worktree_path,
            project=f"holeberry-run-{run_id[-8:]}",
            run_id=run_id,
            ownership_token=secrets_module.token_hex(16),
            artifact_directory=artifact_directory,
            ports=selected_ports,
        )
        state_path = runtime_dir / "state.json"
        _write_private_json(state_path, state)
    except BaseException:
        if runtime_dir is not None:
            shutil.rmtree(runtime_dir, ignore_errors=True)
        if custom_artifact is not None:
            try:
                os.rmdir(custom_artifact)
            except OSError:
                pass
        raise

    return Allocation(
        state=state,
        runtime_dir=runtime_dir,
        state_path=state_path,
        secrets_path=secrets_path,
        artifact_directory=artifact_directory,
        secrets=prepared_secrets,
    )


# ------------------------------------------------------------------- state


def _assert_runtime_path_trusted(worktree: Path) -> Path:
    root = worktree / RUNTIME_DIRNAME
    for candidate in (root, root / MANUAL_DIRNAME, root / RUNS_DIRNAME):
        if candidate.is_symlink():
            raise StateError(f"harness runtime path must not be a symlink: {candidate}")
    return root


def load_state_record(
    state_path: str | Path,
    *,
    worktree: str | Path | None = None,
    expected_project: str | None = None,
) -> dict:
    """Load one trusted state file and reject tampering or misplaced files."""
    worktree_path = canonical_worktree(worktree)
    path = Path(state_path)
    _assert_runtime_path_trusted(worktree_path)
    if path.is_symlink():
        raise StateError(f"state file must not be a symlink: {path}")
    if path.parent.is_symlink():
        raise StateError(f"state directory must not be a symlink: {path.parent}")
    if not path.is_file():
        raise StateError(f"state file is missing or not a regular file: {path}")
    try:
        state = _read_json(path)
    except (OSError, json.JSONDecodeError) as error:
        raise StateError(f"cannot read state file {path}: {error}") from error
    if not isinstance(state, dict):
        raise StateError(f"state file does not contain a JSON object: {path}")

    if state.get("schema_version") != SCHEMA_VERSION:
        raise StateError(
            f"unsupported state schema_version {state.get('schema_version')!r}; expected {SCHEMA_VERSION}"
        )
    for key in (
        "run_id",
        "worktree",
        "project",
        "ownership_token",
        "artifact_directory",
    ):
        if not isinstance(state.get(key), str) or not state[key]:
            raise StateError(f"state field {key} is missing or invalid")
    if not isinstance(state.get("urls"), dict):
        raise StateError("state field urls is missing or invalid")
    if not isinstance(state.get("ports"), dict):
        raise StateError("state field ports is missing or invalid")

    try:
        project = validate_project_name(state["project"])
    except StateError as error:
        raise StateError(f"state project is invalid: {error}") from error
    if expected_project is not None and project != expected_project:
        raise StateError(
            f"state project {project!r} does not match selected project {expected_project!r}"
        )
    if state["worktree"] != str(worktree_path):
        raise StateError(
            f"state worktree {state['worktree']!r} does not match the canonical worktree "
            f"{str(worktree_path)!r}"
        )
    if not RUN_ID_PATTERN.fullmatch(state["run_id"]):
        raise StateError(f"state run_id is invalid: {state['run_id']!r}")
    if not TOKEN_PATTERN.fullmatch(state["ownership_token"]):
        raise StateError("state ownership_token is invalid")
    artifact_directory = Path(state["artifact_directory"])
    if not artifact_directory.is_absolute():
        raise StateError("state artifact_directory must be absolute")

    manual_state = worktree_path / RUNTIME_DIRNAME / MANUAL_DIRNAME / project / "state.json"
    run_state = worktree_path / RUNTIME_DIRNAME / RUNS_DIRNAME / state["run_id"] / "state.json"
    if path == manual_state:
        expected_mode = "manual"
    elif path == run_state:
        expected_mode = "automatic"
    else:
        raise StateError(f"state path is outside its recorded project or run directory: {path}")
    if state.get("mode") != expected_mode:
        raise StateError(
            f"state mode {state.get('mode')!r} does not match its runtime location ({expected_mode})"
        )
    if expected_mode == "automatic":
        derived_project = f"holeberry-run-{state['run_id'][-8:]}"
        if project != derived_project:
            raise StateError(
                f"automatic state project {project!r} does not match its run_id "
                f"{state['run_id']!r} (expected {derived_project!r})"
            )
    return state


def _state_candidate(
    worktree: Path,
    project: str,
) -> Path | None:
    root = _assert_runtime_path_trusted(worktree)
    manual_directory = root / MANUAL_DIRNAME / project
    candidates: list[Path] = []
    errors: list[str] = []

    if manual_directory.is_symlink():
        raise StateError(f"manual project directory must not be a symlink: {manual_directory}")
    if manual_directory.exists():
        if not manual_directory.is_dir():
            raise StateError(f"manual project path is not a directory: {manual_directory}")
        manual_state = manual_directory / "state.json"
        if not manual_state.exists() and not manual_state.is_symlink():
            raise StateError(f"recorded manual project has no state.json: {manual_directory}")
        candidates.append(manual_state)

    runs_directory = root / RUNS_DIRNAME
    if runs_directory.is_symlink():
        raise StateError(f"runs directory must not be a symlink: {runs_directory}")
    if runs_directory.is_dir():
        try:
            entries = sorted(runs_directory.iterdir())
        except OSError as error:
            raise StateError(f"cannot read runs directory {runs_directory}: {error}") from error
        for entry in entries:
            if entry.is_symlink():
                raise StateError(f"run directory must not be a symlink: {entry}")
            if not entry.is_dir():
                continue
            state_path = entry / "state.json"
            if state_path.is_symlink():
                raise StateError(f"run state file must not be a symlink: {state_path}")
            if not state_path.is_file():
                continue
            try:
                state = _read_json(state_path)
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"cannot read run state {state_path}: {error}")
                continue
            if not isinstance(state, dict):
                errors.append(f"run state {state_path} does not contain a JSON object")
                continue
            run_id = state.get("run_id")
            project_value = state.get("project")
            if not isinstance(run_id, str) or not RUN_ID_PATTERN.fullmatch(run_id):
                errors.append(f"run state {state_path} has an invalid run_id")
                continue
            if entry.name != run_id:
                errors.append(
                    f"run state directory {entry.name!r} does not match run_id {run_id!r}"
                )
                continue
            derived_project = f"holeberry-run-{run_id[-8:]}"
            if project_value != derived_project:
                errors.append(
                    f"run state {state_path} project {project_value!r} does not match its run_id"
                )
                continue
            if project_value == project:
                candidates.append(state_path)

    if len(candidates) > 1:
        raise StateError(
            f"multiple recorded states match project {project}: "
            + ", ".join(str(candidate) for candidate in candidates)
        )
    if not candidates and errors:
        raise StateError(errors[0])
    return candidates[0] if candidates else None


def _state_runtime_directory(state: dict, *, worktree: Path) -> Path:
    runtime = _assert_runtime_path_trusted(worktree)
    if state.get("mode") == "manual":
        directory = runtime / MANUAL_DIRNAME / state["project"]
    elif state.get("mode") == "automatic":
        directory = runtime / RUNS_DIRNAME / state["run_id"]
    else:
        raise StateError("state mode is invalid for runtime lookup")
    if directory.is_symlink() or not directory.is_dir():
        raise StateError(f"recorded runtime directory is missing or unsafe: {directory}")
    return directory


def _secrets_path_for_state(state: dict, *, worktree: Path) -> Path:
    runtime = _assert_runtime_path_trusted(worktree)
    if state.get("mode") == "manual":
        secrets_path = runtime / MANUAL_DIRNAME / state["project"] / "secrets.json"
    elif state.get("mode") == "automatic":
        secrets_path = runtime / RUNS_DIRNAME / state["run_id"] / "secrets.json"
    else:
        raise StateError("state mode is invalid for secret lookup")
    if secrets_path.is_symlink():
        raise StateError(f"secrets file must not be a symlink: {secrets_path}")
    if secrets_path.parent.is_symlink():
        raise StateError(f"secrets directory must not be a symlink: {secrets_path.parent}")
    if not secrets_path.is_file():
        raise StateError(f"recorded project has no secrets file: {secrets_path}")
    return secrets_path


def _read_credentials(secrets_path: Path) -> dict[str, str]:
    try:
        secrets = _read_json(secrets_path)
    except (OSError, json.JSONDecodeError) as error:
        raise StateError(f"cannot read secrets file {secrets_path}: {error}") from error
    if not isinstance(secrets, dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in secrets.items()
    ):
        raise StateError(f"secrets file has invalid contents: {secrets_path}")
    return secrets


def _load_state_secrets(state: dict, *, worktree: Path) -> SecretRegistry:
    """Register the selected project's credentials before any Docker diagnostic runs."""
    return SecretRegistry(_read_credentials(_secrets_path_for_state(state, worktree=worktree)))


def _load_state_credentials(
    state: dict, *, worktree: Path
) -> tuple[Path, dict[str, str]]:
    """Return the validated secrets path and values for preparation."""
    secrets_path = _secrets_path_for_state(state, worktree=worktree)
    return secrets_path, _read_credentials(secrets_path)


def _store_v5_token(state: dict, *, worktree: Path, token: str) -> None:
    secrets_path, credentials = _load_state_credentials(state, worktree=worktree)
    credentials["v5_token"] = token
    _write_private_json(secrets_path, credentials)


# ------------------------------------------------------------------ docker


def _docker_environment(env: Mapping[str, str] | None) -> dict[str, str]:
    if env is None:
        return dict(os.environ)
    merged = dict(os.environ)
    # An explicit environment is authoritative: never inherit an ambient remote
    # DOCKER_HOST that the endpoint validator did not see.
    merged.pop("DOCKER_HOST", None)
    merged.update({str(key): str(value) for key, value in env.items()})
    return merged


def _endpoint_environment(env: Mapping[str, str] | None) -> dict[str, str]:
    if env is None:
        return dict(os.environ)
    return {str(key): str(value) for key, value in env.items()}


def _complete_capture_record(text: str, truncated: bool) -> str:
    """Drop an incomplete final record when private capture was truncated."""
    if not truncated or text.endswith("\n"):
        return text
    newline = text.rfind("\n")
    return text[: newline + 1] if newline >= 0 else ""


def _safe_docker_detail(result: CapturedResult, registry: SecretRegistry) -> str:
    if result.stderr:
        text = result.stderr
        truncated = result.stderr_truncated
    else:
        text = result.stdout
        truncated = result.stdout_truncated
    text = _complete_capture_record(text, truncated)
    first_line = text.splitlines()[0] if text else ""
    sanitized = sanitize_text(first_line, registry)
    detail = sanitized[:300]
    if truncated:
        detail = (detail + " [capture truncated]").strip()
    return detail


def _deadline_error(result: CapturedResult, *, phase: str, action: str) -> HarnessError | None:
    if result.timed_out:
        return HarnessError(
            f"{action} exceeded {DOCKER_OPERATION_TIMEOUT:.1f}s",
            phase=phase,
            exit_code=124,
        )
    if result.interrupted_signal is not None:
        signum = result.interrupted_signal
        return HarnessError(
            f"{action} interrupted by signal {signum}",
            phase=phase,
            exit_code=128 + signum,
        )
    return None


def _run_docker(
    arguments: Sequence[str],
    *,
    env: Mapping[str, str] | None,
    phase: str,
    timeout: float | None = None,
    termination_grace: float | None = None,
) -> CapturedResult:
    selected_timeout = DOCKER_OPERATION_TIMEOUT if timeout is None else timeout
    selected_grace = DOCKER_TERMINATION_GRACE if termination_grace is None else termination_grace
    try:
        return run_captured(
            ["docker", *arguments],
            selected_timeout,
            termination_grace=selected_grace,
            env=_docker_environment(env),
        )
    except FileNotFoundError as error:
        raise PreflightError("docker CLI not found; install Docker or Colima and retry") from error
    except OSError as error:
        raise HarnessError(f"cannot run docker {arguments[0]}: {error}", phase=phase) from error


def _validate_local_endpoint(endpoint: str) -> str:
    if not endpoint:
        raise PreflightError("could not resolve the Docker endpoint")
    parsed = urlparse(endpoint)
    scheme = parsed.scheme.lower()
    if scheme == "unix":
        if not parsed.path:
            raise PreflightError("Docker Unix endpoint has no socket path")
        return endpoint
    if scheme == "" and endpoint.startswith("/"):
        return endpoint
    raise PreflightError(
        f"Docker endpoint {scheme or endpoint!r} is not a local Unix socket; "
        "TCP, SSH and npipe endpoints are not allowed"
    )


def resolve_docker_endpoint(
    env: Mapping[str, str] | None = None,
    *,
    registry: SecretRegistry | None = None,
) -> str:
    """Resolve the effective endpoint and require a local Unix socket."""
    selected_registry = registry if registry is not None else SecretRegistry()
    source = _endpoint_environment(env)
    docker_host = source.get("DOCKER_HOST", "").strip()
    if docker_host:
        return _validate_local_endpoint(docker_host)
    result = _run_docker(
        ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
        env=env,
        phase="preflight",
    )
    deadline = _deadline_error(result, phase="preflight", action="docker context inspect")
    if deadline is not None:
        raise deadline
    if result.stdout_truncated:
        raise PreflightError("docker context endpoint output exceeded the capture bound")
    if result.returncode != 0:
        detail = _safe_docker_detail(result, selected_registry)
        raise PreflightError(
            f"cannot resolve the Docker endpoint (status {result.returncode})"
            + (f": {detail}" if detail else "")
        )
    return _validate_local_endpoint(result.stdout.strip())


def preflight_docker(
    env: Mapping[str, str] | None = None,
    *,
    registry: SecretRegistry | None = None,
) -> str:
    """Resolve a local Unix endpoint and prove the daemon answers before any mutation."""
    selected_registry = registry if registry is not None else SecretRegistry()
    endpoint = resolve_docker_endpoint(env, registry=selected_registry)
    result = _run_docker(
        ["info", "--format", "{{.ServerVersion}}"],
        env=env,
        phase="preflight",
    )
    deadline = _deadline_error(result, phase="preflight", action="docker info")
    if deadline is not None:
        raise deadline
    if result.returncode != 0:
        detail = _safe_docker_detail(result, selected_registry)
        raise PreflightError(
            f"Docker daemon is unavailable at {endpoint} (status {result.returncode})"
            + (f": {detail}" if detail else "")
            + "; start Docker or Colima and retry"
        )
    return endpoint


def _parse_resource_ids(
    output: str,
    kind: str,
    registry: SecretRegistry | None = None,
) -> list[str]:
    identifiers: list[str] = []
    for line in output.splitlines():
        candidate = line.strip()
        if not candidate or candidate in identifiers:
            continue
        if len(candidate) > 256 or not RESOURCE_ID_PATTERN.fullmatch(candidate):
            display = registry.sanitize(candidate) if registry is not None else candidate
            display = display[:80]
            raise HarnessError(
                f"unexpected {kind} identifier from Docker: {display!r}",
                phase="lookup",
            )
        identifiers.append(candidate)
    return identifiers


def _docker_lookup(
    arguments: Sequence[str],
    *,
    kind: str,
    env: Mapping[str, str] | None,
    registry: SecretRegistry,
) -> list[str]:
    result = _run_docker(arguments, env=env, phase="lookup")
    deadline = _deadline_error(result, phase="lookup", action=f"docker {kind} lookup")
    if deadline is not None:
        raise deadline
    if result.stdout_truncated:
        raise HarnessError(
            f"docker {kind} lookup output exceeded {MAX_CAPTURE_BYTES} bytes",
            phase="lookup",
        )
    if result.returncode != 0:
        detail = _safe_docker_detail(result, registry)
        raise HarnessError(
            f"docker {kind} lookup failed with status {result.returncode}"
            + (f": {detail}" if detail else ""),
            phase="lookup",
        )
    return _parse_resource_ids(result.stdout, kind, registry)


def discover_project_resources(
    project: str,
    *,
    env: Mapping[str, str] | None = None,
    registry: SecretRegistry | None = None,
) -> dict[str, list[str]]:
    """Find the union of Compose-project and harness-project members."""
    selected_registry = registry if registry is not None else SecretRegistry()
    harness_filter = f"label={LABEL_PROJECT}={project}"
    compose_filter = f"label={COMPOSE_PROJECT_LABEL}={project}"

    def union(prefix: list[str], kind: str) -> list[str]:
        identifiers: list[str] = []
        for filter_value in (harness_filter, compose_filter):
            for resource_id in _docker_lookup(
                [*prefix, "--filter", filter_value],
                kind=kind,
                env=env,
                registry=selected_registry,
            ):
                if resource_id not in identifiers:
                    identifiers.append(resource_id)
        return identifiers

    return {
        "containers": union(["ps", "-aq"], "container"),
        "networks": union(["network", "ls", "-q"], "network"),
        "volumes": union(["volume", "ls", "-q"], "volume"),
    }


def _inspect_labels(
    kind: str,
    resource_id: str,
    *,
    env: Mapping[str, str] | None,
    registry: SecretRegistry,
) -> dict[str, str]:
    if kind == "containers":
        arguments = [
            "inspect",
            "--type",
            "container",
            "--format",
            "{{json .Config.Labels}}",
            resource_id,
        ]
        singular = "container"
    elif kind == "networks":
        arguments = ["network", "inspect", "--format", "{{json .Labels}}", resource_id]
        singular = "network"
    elif kind == "volumes":
        arguments = ["volume", "inspect", "--format", "{{json .Labels}}", resource_id]
        singular = "volume"
    else:  # pragma: no cover - guarded by the fixed resource kinds
        raise HarnessError(f"unsupported resource kind {kind}", phase="ownership")

    result = _run_docker(arguments, env=env, phase="ownership")
    deadline = _deadline_error(result, phase="ownership", action=f"docker {singular} inspect")
    if deadline is not None:
        raise deadline
    if result.stdout_truncated:
        raise OwnershipError(
            f"{singular} {resource_id} label output exceeded {MAX_CAPTURE_BYTES} bytes"
        )
    if result.returncode != 0:
        detail = _safe_docker_detail(result, registry)
        raise OwnershipError(
            f"cannot inspect {singular} {resource_id} (status {result.returncode})"
            + (f": {detail}" if detail else "")
        )
    try:
        labels = json.loads(result.stdout) if result.stdout.strip() else {}
    except json.JSONDecodeError as error:
        raise OwnershipError(f"{singular} {resource_id} returned invalid label JSON") from error
    if labels is None:
        return {}
    if not isinstance(labels, dict) or any(
        not isinstance(key, str) or not isinstance(value, str) for key, value in labels.items()
    ):
        raise OwnershipError(f"{singular} {resource_id} returned unexpected label data")
    return labels


def _validate_ownership(
    state: dict,
    resources: Mapping[str, list[str]],
    *,
    env: Mapping[str, str] | None,
    registry: SecretRegistry,
) -> None:
    expected = {
        LABEL_PROJECT: state["project"],
        LABEL_RUN_ID: state["run_id"],
        LABEL_WORKTREE: state["worktree"],
        LABEL_OWNER: state["ownership_token"],
    }
    inspected: dict[tuple[str, str], dict[str, str]] = {}
    for kind in ("containers", "networks", "volumes"):
        for resource_id in resources[kind]:
            inspected[(kind, resource_id)] = _inspect_labels(
                kind, resource_id, env=env, registry=registry
            )

    problems: list[str] = []
    for (kind, resource_id), labels in inspected.items():
        singular = {"containers": "container", "networks": "network", "volumes": "volume"}[kind]
        for label, value in expected.items():
            if labels.get(label) == value:
                continue
            if label == LABEL_OWNER:
                problem = f"{singular} {resource_id} has a mismatched harness ownership label"
            else:
                observed = registry.sanitize(str(labels.get(label)))[:120]
                problem = (
                    f"{singular} {resource_id} label {label}={observed!r} "
                    "does not match state"
                )
            problems.append(registry.sanitize(problem))
    if problems:
        raise OwnershipError(
            "refusing teardown before deleting anything; resource ownership mismatch: "
            + "; ".join(problems[:10])
        )


def _remove_runtime_directory(runtime_dir: Path) -> None:
    try:
        shutil.rmtree(runtime_dir)
    except OSError as error:
        raise HarnessError(
            f"could not remove runtime state directory {runtime_dir}: {error}",
            phase="teardown",
        ) from error


# ---------------------------------------------------------- fixture readiness


class _NotReady(Exception):
    """A bounded readiness observation did not satisfy the current phase."""


class _SessionExpired(Exception):
    """A tracked v6 readiness session is no longer accepted by the server."""


class _Interrupted(Exception):
    """A lifecycle SIGINT/SIGTERM arrived outside a supervised child."""

    def __init__(self, signum: int):
        super().__init__(f"interrupted by signal {signum}")
        self.signum = signum


class _LifecycleInterrupt:
    """Cooperative signal state for one lifecycle invocation."""

    def __init__(self):
        self.signum: int | None = None
        self._event = threading.Event()
        self._suspended = False

    def trigger(self, signum: int) -> None:
        if self.signum is None:
            self.signum = signum
        self._event.set()

    def check(self) -> None:
        if self.signum is not None and not self._suspended:
            raise _Interrupted(self.signum)

    def wait(self, timeout: float) -> None:
        self._event.wait(max(0.0, timeout))
        self.check()

    def suspend(self) -> None:
        """Stop raising after a failure so diagnostics and teardown can finish."""
        self._suspended = True

    def begin_cleanup(self) -> bool:
        previous = self._suspended
        self._suspended = True
        return previous

    def end_cleanup(self, previous: bool) -> None:
        self._suspended = previous


_ACTIVE_INTERRUPT: _LifecycleInterrupt | None = None


@contextlib.contextmanager
def _lifecycle_interrupts() -> Iterator[_LifecycleInterrupt]:
    """Route lifecycle SIGINT/SIGTERM into cooperative checks and cleanup.

    The process supervisor temporarily replaces these handlers while a child
    runs and restores them afterwards, so child status handling stays owned by
    the existing supervisor.
    """
    global _ACTIVE_INTERRUPT
    previous_guard = _ACTIVE_INTERRUPT
    guard = _LifecycleInterrupt()
    previous_handlers: dict[int, object] = {}

    def handle_signal(signum: int, _frame: object) -> None:
        guard.trigger(signum)

    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGINT, signal.SIGTERM):
            try:
                previous_handlers[signum] = signal.signal(signum, handle_signal)
            except (ValueError, OSError):
                pass
    _ACTIVE_INTERRUPT = guard
    try:
        yield guard
    finally:
        _ACTIVE_INTERRUPT = previous_guard
        for signum, handler in previous_handlers.items():
            try:
                signal.signal(signum, handler)  # type: ignore[arg-type]
            except (ValueError, OSError):
                pass


def _request_active_interrupt(signum: int) -> bool:
    """Test hook: trigger the active lifecycle guard without a real signal."""
    guard = _ACTIVE_INTERRUPT
    if guard is None:
        return False
    guard.trigger(signum)
    return True


def _check_interrupted() -> None:
    guard = _ACTIVE_INTERRUPT
    if guard is not None:
        guard.check()


def _interruptible_sleep(seconds: float) -> None:
    guard = _ACTIVE_INTERRUPT
    if guard is not None:
        guard.wait(seconds)
    else:
        time.sleep(max(0.0, seconds))
    _check_interrupted()


@dataclass(frozen=True)
class Prepared:
    fixtures_path: Path
    fixtures: dict
    durations: dict[str, float]


def _remaining(deadline: float) -> float:
    return max(0.0, deadline - time.monotonic())


def _bounded_timeout(deadline: float, *, maximum: float = DOCKER_OPERATION_TIMEOUT) -> float:
    return max(0.05, min(maximum, _remaining(deadline)))


def _set_stream_timeout(stream: object, seconds: float) -> None:
    """Best-effort per-read socket timeout so a slow body cannot outlive a phase."""
    try:
        stream.fp.raw._sock.settimeout(max(0.01, seconds))  # type: ignore[attr-defined]
    except (AttributeError, OSError, ValueError):
        pass


def _read_http_body(
    stream: object, deadline: float, registry: SecretRegistry
) -> bytes:
    buffer = bytearray()
    while True:
        _check_interrupted()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise _NotReady("HTTP response body exceeded the phase deadline")
        _set_stream_timeout(stream, remaining)
        limit = MAX_HTTP_BODY_BYTES + 1 - len(buffer)
        if limit <= 0:
            raise _NotReady("HTTP response exceeded the bounded body limit")
        reader = getattr(stream, "read1", None)
        try:
            if reader is not None:
                chunk = reader(min(READ_CHUNK_BYTES, limit))
            else:
                chunk = stream.read(min(READ_CHUNK_BYTES, limit))  # type: ignore[attr-defined]
        except (TimeoutError, OSError) as error:
            detail = registry.sanitize(str(error))[:200]
            raise _NotReady(f"HTTP response body read failed: {detail}") from None
        if not chunk:
            break
        buffer.extend(chunk)
        if len(buffer) > MAX_HTTP_BODY_BYTES:
            raise _NotReady("HTTP response exceeded the bounded body limit")
    return bytes(buffer)


class _HttpDeadline(_NotReady):
    """An absolute HTTP budget expired, raised from the alarm handler."""


_HTTP_ALARM_TICK = 0.05


@contextlib.contextmanager
def _elapsed_http_alarm(deadline: float) -> Iterator[None]:
    """Interrupt the whole synchronous urllib operation at its absolute deadline.

    The one-shot ITIMER_REAL keeps re-arming in short ticks only while this
    operation owns the timer. The raising handler interrupts blocking status,
    header and body reads even when bytes arrive more often than the socket
    inactivity timeout.
    """
    if not math.isfinite(deadline):
        raise HarnessError("HTTP deadline must be finite", phase="http")
    if time.monotonic() >= deadline:
        raise _NotReady("HTTP phase deadline already expired")
    if threading.current_thread() is not threading.main_thread():
        raise HarnessError(
            "HTTP deadline alarm requires the main thread", phase="http"
        )
    setitimer = getattr(signal, "setitimer", None)
    getitimer = getattr(signal, "getitimer", None)
    sigalrm = getattr(signal, "SIGALRM", None)
    if setitimer is None or getitimer is None or sigalrm is None:
        raise HarnessError(
            "HTTP deadline alarm is unavailable on this platform", phase="http"
        )
    previous_timer = getitimer(signal.ITIMER_REAL)
    if previous_timer != (0.0, 0.0):
        raise HarnessError(
            "an unrelated real-time timer is already armed", phase="http"
        )
    previous_handler = signal.getsignal(sigalrm)

    def handle_alarm(_signum: int, _frame: object) -> None:
        guard = _ACTIVE_INTERRUPT
        if guard is not None:
            guard.check()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise _HttpDeadline("HTTP operation exceeded its elapsed deadline")
        signal.setitimer(
            signal.ITIMER_REAL, max(0.001, min(remaining, _HTTP_ALARM_TICK))
        )

    try:
        signal.signal(sigalrm, handle_alarm)
        signal.setitimer(
            signal.ITIMER_REAL,
            max(0.001, min(deadline - time.monotonic(), _HTTP_ALARM_TICK)),
        )
        yield
    finally:
        try:
            signal.setitimer(signal.ITIMER_REAL, 0.0)
        finally:
            signal.signal(sigalrm, previous_handler)


def _http_json(
    method: str,
    url: str,
    *,
    registry: SecretRegistry,
    timeout: float,
    headers: Mapping[str, str] | None = None,
    body: object | None = None,
    deadline: float | None = None,
) -> tuple[int, object]:
    """Call one bounded local HTTP endpoint without exposing URLs or bodies on errors."""
    operation_deadline = (
        deadline if deadline is not None else time.monotonic() + timeout
    )
    if time.monotonic() >= operation_deadline:
        raise _NotReady("HTTP phase deadline already expired")
    data = None
    request_headers = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    socket_timeout = max(
        0.01, min(timeout, operation_deadline - time.monotonic())
    )
    with _elapsed_http_alarm(operation_deadline):
        _check_interrupted()
        try:
            with opener.open(request, timeout=socket_timeout) as response:
                status = int(response.status)
                raw = _read_http_body(response, operation_deadline, registry)
        except urllib.error.HTTPError as error:
            try:
                status = int(error.code)
                raw = _read_http_body(error, operation_deadline, registry)
            finally:
                error.close()
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            reason = getattr(error, "reason", error)
            detail = registry.sanitize(str(reason))[:200]
            raise _NotReady(f"HTTP request failed: {detail}") from None
        _check_interrupted()
        if time.monotonic() >= operation_deadline:
            raise _NotReady("HTTP response arrived after the phase deadline")
        if len(raw) > MAX_HTTP_BODY_BYTES:
            raise _NotReady("HTTP response exceeded the bounded body limit")
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise _NotReady("HTTP response was not valid JSON") from None
        return status, payload


def _v5_list_url(base_url: str, token: str, list_name: str) -> str:
    return f"{base_url}/admin/api.php?{urlencode({'auth': token, 'list': list_name})}"


def _v5_status_url(base_url: str, token: str) -> str:
    return f"{base_url}/admin/api.php?{urlencode({'auth': token})}&status"


def _v5_domain_candidates(value: str) -> set[str]:
    """Expand v5's IDN display form into exact ASCII candidates.

    v5's list API renders an internationalized domain as
    ``bücher.example (xn--bcher-kva.example)`` and HTML-escapes it. Verification
    still requires the exact punycode fixture, so both forms are accepted.
    """
    candidates = {value}
    decoded = html.unescape(value)
    candidates.add(decoded)
    match = re.fullmatch(r"(.+) \(([^()]+)\)", decoded)
    if match:
        candidates.add(match.group(1))
        candidates.add(match.group(2))
    for candidate in tuple(candidates):
        try:
            ascii_form = candidate.encode("idna").decode("ascii")
        except UnicodeError:
            continue
        candidates.add(ascii_form)
    return candidates


def _v5_domains(payload: object, *, list_name: str) -> tuple[str, ...]:
    if not isinstance(payload, dict):
        raise _NotReady("v5 list response is not a JSON object")
    rows = payload.get("data")
    if not isinstance(rows, list):
        raise _NotReady("v5 list response has no data array")
    domains: list[str] = []
    for row in rows:
        if not isinstance(row, dict):
            raise _NotReady("v5 list row is not a JSON object")
        domain = row.get("domain")
        if not isinstance(domain, str) or not domain:
            raise _NotReady("v5 list row has no domain")
        domains.extend(sorted(_v5_domain_candidates(domain)))
    return tuple(domains)


def _v6_domains(payload: object) -> tuple[str, ...]:
    if not isinstance(payload, dict):
        raise _NotReady("v6 domain response is not a JSON object")
    rows = payload.get("domains")
    if not isinstance(rows, list):
        raise _NotReady("v6 domain response has no domains array")
    domains: list[str] = []
    for row in rows:
        if not isinstance(row, dict):
            raise _NotReady("v6 domain row is not a JSON object")
        domain = row.get("domain")
        if not isinstance(domain, str) or not domain:
            raise _NotReady("v6 domain row has no domain")
        domains.append(domain)
    return tuple(domains)


def _verify_fixture_entries(lane: str, data: Mapping[str, Sequence[str]]) -> None:
    required = {
        "allow": set(FIXTURE_ALLOW_DOMAINS),
        "deny": set(FIXTURE_DENY_DOMAINS),
        "regex_deny": set(FIXTURE_REGEX_DENY_DOMAINS),
    }
    missing: list[str] = []
    for kind, expected in required.items():
        observed = set(data.get(kind, ()))
        for domain in sorted(expected - observed):
            missing.append(f"{kind}:{domain}")
    if missing:
        raise _NotReady(f"{lane} fixture entries are missing: " + ", ".join(missing))


def _gravity_source_sql() -> str:
    return (
        "SELECT 'source', address FROM adlist WHERE enabled = 1 "
        "UNION ALL "
        "SELECT 'gravity', g.domain || '|' || a.address "
        "FROM gravity g JOIN adlist a ON g.adlist_id = a.id "
        f"WHERE g.domain = '{GRAVITY_QUERY_DOMAIN}';"
    )


def _gravity_source_command(
    lane: str, compose_env: Mapping[str, str]
) -> list[str]:
    service = LANE_SERVICES[lane]
    binary = ["sqlite3"] if lane == "v5" else ["pihole-FTL", "sqlite3"]
    return [
        *_compose_arguments(
            compose_env["HARNESS_PROJECT"], "exec", "-T", service
        ),
        *binary,
        "-readonly",
        "-batch",
        "-noheader",
        "-separator",
        "|",
        "/etc/pihole/gravity.db",
        _gravity_source_sql(),
    ]


def _parse_gravity_source_rows(
    output: str,
) -> tuple[list[str], list[tuple[str, str]]]:
    sources: list[str] = []
    gravity_rows: list[tuple[str, str]] = []
    for line in output.splitlines():
        parts = line.split("|")
        if not parts:
            continue
        if parts[0] == "source" and len(parts) == 2:
            sources.append(parts[1])
        elif parts[0] == "gravity" and len(parts) == 3:
            gravity_rows.append((parts[1], parts[2]))
    return sources, gravity_rows


def _validate_gravity_source_rows(lane: str, output: str) -> None:
    sources, gravity_rows = _parse_gravity_source_rows(output)
    if sorted(sources) != [FIXTURE_URL]:
        raise HarnessError(
            f"{lane} enabled adlist sources are not exactly the local fixture source",
            phase=f"gravity-{lane}",
        )
    if (GRAVITY_QUERY_DOMAIN, FIXTURE_URL) not in gravity_rows:
        raise HarnessError(
            f"{lane} stored gravity row does not reference the fixture source",
            phase=f"gravity-{lane}",
        )


def _verify_gravity_sources(
    lane: str,
    *,
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    deadline: float,
) -> None:
    """Independently read the enabled source set and fixture gravity row."""
    result = _run_docker(
        _gravity_source_command(lane, compose_env),
        env=compose_env,
        phase=f"gravity-{lane}",
        timeout=_bounded_timeout(deadline),
    )
    if result.timed_out:
        raise HarnessError(
            f"{lane} gravity source verification exceeded its deadline",
            phase=f"gravity-{lane}",
            exit_code=124,
        )
    if result.interrupted_signal is not None:
        raise HarnessError(
            f"{lane} gravity source verification interrupted by signal "
            f"{result.interrupted_signal}",
            phase=f"gravity-{lane}",
            exit_code=128 + result.interrupted_signal,
        )
    if result.stdout_truncated or result.stderr_truncated:
        raise HarnessError(
            f"{lane} gravity source verification output was truncated",
            phase=f"gravity-{lane}",
        )
    if result.returncode != 0:
        detail = _safe_docker_detail(result, registry)
        raise HarnessError(
            f"{lane} read-only gravity source verification failed with status "
            f"{result.returncode}" + (f": {detail}" if detail else ""),
            phase=f"gravity-{lane}",
            exit_code=result.returncode,
        )
    _validate_gravity_source_rows(lane, result.stdout)


def _v5_authenticated_status(
    base_url: str,
    token: str,
    *,
    registry: SecretRegistry,
    timeout: float,
    deadline: float | None = None,
) -> None:
    status, payload = _http_json(
        "GET",
        _v5_status_url(base_url, token),
        registry=registry,
        timeout=timeout,
        deadline=deadline,
    )
    if status != 200 or not isinstance(payload, dict) or "status" not in payload:
        raise _NotReady("v5 authenticated status is not available")
    if payload.get("status") != "enabled":
        raise HarnessError("v5 blocking is not enabled", phase="readiness")


def _v5_fixture_data(
    base_url: str,
    token: str,
    *,
    registry: SecretRegistry,
    timeout: float,
    deadline: float | None = None,
) -> dict[str, tuple[str, ...]]:
    operation_deadline = (
        deadline if deadline is not None else time.monotonic() + timeout
    )
    data: dict[str, tuple[str, ...]] = {}
    for list_name, key in (
        ("white", "allow"),
        ("black", "deny"),
        ("regex_black", "regex_deny"),
    ):
        status, payload = _http_json(
            "GET",
            _v5_list_url(base_url, token, list_name),
            registry=registry,
            timeout=timeout,
            deadline=operation_deadline,
        )
        if status != 200:
            raise _NotReady(f"v5 {key} list returned status {status}")
        data[key] = _v5_domains(payload, list_name=list_name)
    _verify_fixture_entries("v5", data)
    return data


def _v6_authenticated_status(
    base_url: str,
    sid: str,
    *,
    registry: SecretRegistry,
    timeout: float,
    deadline: float | None = None,
) -> None:
    status, payload = _http_json(
        "GET",
        f"{base_url}/api/dns/blocking",
        headers={"X-FTL-SID": sid},
        registry=registry,
        timeout=timeout,
        deadline=deadline,
    )
    if status == 401:
        raise _SessionExpired()
    if status != 200 or not isinstance(payload, dict) or "blocking" not in payload:
        raise _NotReady("v6 authenticated status is not available")
    if payload.get("blocking") != "enabled":
        raise HarnessError("v6 blocking is not enabled", phase="readiness")


def _v6_fixture_data(
    base_url: str,
    sid: str,
    *,
    registry: SecretRegistry,
    timeout: float,
    deadline: float | None = None,
) -> dict[str, tuple[str, ...]]:
    operation_deadline = (
        deadline if deadline is not None else time.monotonic() + timeout
    )
    data: dict[str, tuple[str, ...]] = {}
    for list_name, filter_name, key in (
        ("allow", "exact", "allow"),
        ("deny", "exact", "deny"),
        ("deny", "regex", "regex_deny"),
    ):
        status, payload = _http_json(
            "GET",
            f"{base_url}/api/domains/{list_name}/{filter_name}",
            headers={"X-FTL-SID": sid},
            registry=registry,
            timeout=timeout,
            deadline=operation_deadline,
        )
        if status == 401:
            raise _SessionExpired()
        if status != 200:
            raise _NotReady(f"v6 {key} list returned status {status}")
        data[key] = _v6_domains(payload)
    _verify_fixture_entries("v6", data)
    return data


class _V6Readiness:
    """Tracks every readiness-created v6 session so each one is logged out."""

    def __init__(
        self, base_url: str, password: str, *, registry: SecretRegistry
    ):
        self._base_url = base_url.rstrip("/")
        self._password = password
        self._registry = registry
        self._sid: str | None = None
        self._acquired: list[str] = []

    def session(self, *, timeout: float, deadline: float | None = None) -> str:
        if self._sid is not None:
            return self._sid
        status, payload = _http_json(
            "POST",
            f"{self._base_url}/api/auth",
            body={"password": self._password},
            registry=self._registry,
            timeout=timeout,
            deadline=deadline,
        )
        if status in (401, 403):
            raise HarnessError(
                "v6 fixture password was rejected during readiness", phase="readiness"
            )
        if status == 429:
            raise _NotReady("v6 authentication is rate limited")
        if status != 200 or not isinstance(payload, dict):
            raise _NotReady(f"v6 authentication returned status {status}")
        session = payload.get("session")
        sid = session.get("sid") if isinstance(session, dict) else None
        if not isinstance(sid, str) or not sid:
            raise HarnessError(
                "v6 authentication did not return a session identifier",
                phase="readiness",
            )
        self._registry.register(sid)
        self._sid = sid
        self._acquired.append(sid)
        return sid

    def invalidate(self) -> None:
        self._sid = None

    def close(self, *, timeout: float = DOCKER_OPERATION_TIMEOUT) -> HarnessError | None:
        self._sid = None
        first: HarnessError | None = None
        secondary: list[HarnessError] = []
        guard = _ACTIVE_INTERRUPT
        for sid in reversed(self._acquired):
            attempt_error: HarnessError | None = None
            attempt_deadline = time.monotonic() + timeout
            try:
                _v6_logout(
                    self._base_url,
                    sid,
                    registry=self._registry,
                    timeout=timeout,
                    deadline=attempt_deadline,
                )
            except _Interrupted as error:
                attempt_error = HarnessError(
                    "v6 readiness session logout interrupted by signal "
                    f"{error.signum}",
                    phase="readiness",
                    exit_code=128 + error.signum,
                )
            except HarnessError as error:
                attempt_error = error
            except BaseException as error:  # noqa: BLE001 - continue all sessions
                attempt_error = _as_harness_error(error, phase="readiness")
            # A signal observed here arrived before this attempt's error/timeout
            # was recorded, so it wins the first-candidate slot if still open.
            if first is None and guard is not None and guard.signum is not None:
                first = _as_harness_error(
                    _Interrupted(guard.signum), phase="readiness"
                )
            if attempt_error is not None:
                if first is None:
                    first = attempt_error
                else:
                    secondary.append(attempt_error)
        self._acquired.clear()
        if first is None and guard is not None and guard.signum is not None:
            first = _as_harness_error(
                _Interrupted(guard.signum), phase="readiness"
            )
        if first is None:
            return None
        message = str(first)
        if secondary:
            message += "; secondary: " + "; ".join(
                str(error) for error in secondary
            )
        return HarnessError(
            message, phase=first.phase, exit_code=first.exit_code
        )


def _v6_logout(
    base_url: str,
    sid: str,
    *,
    registry: SecretRegistry,
    timeout: float,
    deadline: float | None = None,
) -> None:
    try:
        status, _payload = _http_json(
            "DELETE",
            f"{base_url}/api/auth",
            headers={"X-FTL-SID": sid},
            registry=registry,
            timeout=timeout,
            deadline=deadline,
        )
    except _HttpDeadline:
        raise HarnessError(
            "v6 readiness session logout exceeded its deadline",
            phase="readiness",
            exit_code=124,
        ) from None
    except _NotReady as error:
        raise HarnessError(
            f"v6 readiness session logout failed: {error}", phase="readiness"
        ) from None
    if status not in (200, 204, 401):
        raise HarnessError(
            f"v6 readiness session logout failed with status {status}",
            phase="readiness",
        )


_PollResult = TypeVar("_PollResult")


def _poll_until(
    attempt: Callable[[], _PollResult],
    *,
    deadline: float,
    interval: float,
    phase: str,
    action: str,
    registry: SecretRegistry,
) -> _PollResult:
    """Retry one bounded observation without ever extending the phase deadline."""
    last_detail = ""
    while True:
        _check_interrupted()
        remaining = _remaining(deadline)
        if remaining <= 0:
            suffix = f": {registry.sanitize(last_detail)[:200]}" if last_detail else ""
            raise HarnessError(
                f"{action} did not complete before its deadline{suffix}",
                phase=phase,
                exit_code=124,
            )
        try:
            result = attempt()
            if time.monotonic() >= deadline:
                raise _NotReady("observation completed after its phase deadline")
            return result
        except _NotReady as error:
            last_detail = str(error)
        _interruptible_sleep(min(interval, _remaining(deadline)))


def _check_dns(
    lane: str,
    *,
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    timeout: float,
) -> None:
    service = LANE_SERVICES[lane]
    result = _run_docker(
        [
            *_compose_arguments(compose_env["HARNESS_PROJECT"], "exec", "-T", service),
            "dig",
            "@127.0.0.1",
            GRAVITY_QUERY_DOMAIN,
            "A",
            "+time=1",
            "+tries=1",
        ],
        env=compose_env,
        phase=f"readiness-{lane}",
        timeout=timeout,
    )
    if result.timed_out:
        raise _NotReady("DNS readiness probe exceeded its bounded operation deadline")
    if result.interrupted_signal is not None:
        raise HarnessError(
            f"DNS readiness probe interrupted by signal {result.interrupted_signal}",
            phase=f"readiness-{lane}",
            exit_code=128 + result.interrupted_signal,
        )
    if result.returncode != 0 or result.stdout_truncated or result.stderr_truncated:
        raise _NotReady("DNS readiness probe did not get a response from FTL")
    if "status:" not in result.stdout:
        raise _NotReady("DNS readiness probe returned no DNS status")


def _extract_v5_token(
    *,
    project: str,
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    timeout: float,
) -> str:
    """Read the initialized WEBPASSWORD token without ever logging capture contents."""
    result = _run_docker(
        [
            *_compose_arguments(
                project, "exec", "-T", "pihole-v5"
            ),
            "sh",
            "-c",
            "grep -m1 '^WEBPASSWORD=' /etc/pihole/setupVars.conf",
        ],
        env=compose_env,
        phase="credentials",
        timeout=timeout,
    )
    if result.timed_out:
        raise HarnessError(
            "v5 token extraction exceeded its deadline",
            phase="credentials",
            exit_code=124,
        )
    if result.interrupted_signal is not None:
        raise HarnessError(
            f"v5 token extraction interrupted by signal {result.interrupted_signal}",
            phase="credentials",
            exit_code=128 + result.interrupted_signal,
        )
    if result.stdout_truncated or result.stderr_truncated:
        raise HarnessError(
            "v5 token extraction output was truncated", phase="credentials"
        )
    if result.returncode != 0:
        raise HarnessError(
            f"v5 token extraction failed with status {result.returncode}",
            phase="credentials",
        )
    token: str | None = None
    for line in result.stdout.splitlines():
        if line.startswith("WEBPASSWORD="):
            candidate = line[len("WEBPASSWORD=") :].strip()
            if candidate:
                token = candidate
                break
    if token is None or not V5_TOKEN_PATTERN.fullmatch(token):
        raise HarnessError(
            "initialized v5 API token was not found or has an invalid form",
            phase="credentials",
        )
    registry.register(token)
    return token


def _seed_and_verify(
    lane: str,
    *,
    run_seed: Callable[[], int],
    read_fixtures: Callable[[], dict[str, tuple[str, ...]]],
    deadline: float,
    registry: SecretRegistry,
    log: "_PhaseLog",
    interval: float = READINESS_POLL_INTERVAL,
) -> dict[str, tuple[str, ...]]:
    log.emit(f"seed-{lane}", "running")
    status = run_seed()
    if status != 0:
        code = status if status > 0 else 1
        raise HarnessError(
            f"{lane} fixture seed failed with status {status}",
            phase=f"fixtures-{lane}",
            exit_code=code,
        )
    def verified_read() -> dict[str, tuple[str, ...]]:
        data = read_fixtures()
        _verify_fixture_entries(lane, data)
        return data

    data = _poll_until(
        verified_read,
        deadline=deadline,
        interval=interval,
        phase=f"fixtures-{lane}",
        action=f"{lane} fixture verification",
        registry=registry,
    )
    log.emit(
        f"fixtures-{lane}",
        "ok",
        allow=len(data["allow"]),
        deny=len(data["deny"]),
        regex=len(data["regex_deny"]),
    )
    return data


def _parse_v5_timestamp(value: object) -> float:
    if isinstance(value, bool):
        raise _NotReady("v5 query timestamp is not numeric")
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        try:
            return float(text)
        except ValueError:
            pass
        for pattern in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
            try:
                return datetime.strptime(text, pattern).replace(
                    tzinfo=timezone.utc
                ).timestamp()
            except ValueError:
                continue
    raise _NotReady("v5 query timestamp is not in a recognized format")


def _v5_query_entry(
    base_url: str,
    token: str,
    *,
    start: int,
    until: int,
    registry: SecretRegistry,
    timeout: float,
    deadline: float | None = None,
) -> tuple[str, float]:
    query = urlencode(
        {
            "auth": token,
            "getAllQueries": "100",
            "from": str(start),
            "until": str(until),
        }
    )
    status, payload = _http_json(
        "GET",
        f"{base_url}/admin/api.php?{query}",
        registry=registry,
        timeout=timeout,
        deadline=deadline,
    )
    if status != 200 or not isinstance(payload, dict):
        raise _NotReady("v5 query history is not available")
    rows = payload.get("data")
    if not isinstance(rows, list):
        raise _NotReady("v5 query history has no data array")
    for row in rows:
        if not isinstance(row, list) or len(row) < 5:
            continue
        if str(row[2]) != GRAVITY_QUERY_DOMAIN:
            continue
        if str(row[4]) != "1":
            continue
        return str(row[3]), _parse_v5_timestamp(row[0])
    raise _NotReady("gravity query is not visible in v5 query history yet")


def _v6_query_entry(
    base_url: str,
    sid: str,
    *,
    start: int,
    until: int,
    registry: SecretRegistry,
    timeout: float,
    deadline: float | None = None,
) -> tuple[str, float]:
    query = urlencode(
        {
            "status": "GRAVITY",
            "length": "100",
            "from": str(start),
            "until": str(until),
        }
    )
    status, payload = _http_json(
        "GET",
        f"{base_url}/api/queries?{query}",
        headers={"X-FTL-SID": sid},
        registry=registry,
        timeout=timeout,
        deadline=deadline,
    )
    if status == 401:
        raise _SessionExpired()
    if status != 200 or not isinstance(payload, dict):
        raise _NotReady("v6 query history is not available")
    rows = payload.get("queries")
    if not isinstance(rows, list):
        raise _NotReady("v6 query history has no queries array")
    for row in rows:
        if not isinstance(row, dict) or row.get("domain") != GRAVITY_QUERY_DOMAIN:
            continue
        client = row.get("client")
        timestamp = row.get("time")
        if not isinstance(client, dict):
            continue
        address = client.get("ip")
        if isinstance(address, str) and isinstance(timestamp, (int, float)):
            return address, float(timestamp)
    raise _NotReady("gravity query is not visible in v6 query history yet")


def _numeric_client_ip(lane: str, value: str) -> str:
    try:
        return str(ipaddress.ip_address(value.strip().strip("[]")))
    except ValueError:
        raise HarnessError(
            f"{lane} gravity query client is not a numeric address",
            phase=f"query-{lane}",
        ) from None


def _observe_gravity_query(
    lane: str,
    *,
    state: dict,
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    token: str | None,
    session: _V6Readiness | None,
) -> dict[str, object]:
    service = LANE_SERVICES[lane]
    deadline = time.monotonic() + QUERY_VISIBILITY_TIMEOUT

    def dig_attempt() -> float:
        started = time.time()
        result = _run_docker(
            [
                *_compose_arguments(
                    compose_env["HARNESS_PROJECT"], "exec", "-T", service
                ),
                "dig",
                "@127.0.0.1",
                GRAVITY_QUERY_DOMAIN,
                "A",
                "+time=2",
                "+tries=1",
            ],
            env=compose_env,
            phase=f"query-{lane}",
            timeout=_bounded_timeout(deadline),
        )
        if result.timed_out:
            raise HarnessError(
                f"{lane} gravity query exceeded its deadline",
                phase=f"query-{lane}",
                exit_code=124,
            )
        if result.interrupted_signal is not None:
            raise HarnessError(
                f"{lane} gravity query interrupted by signal "
                f"{result.interrupted_signal}",
                phase=f"query-{lane}",
                exit_code=128 + result.interrupted_signal,
            )
        if result.returncode != 0:
            raise _NotReady("DNS server did not answer the gravity query yet")
        if result.stdout_truncated or result.stderr_truncated:
            raise _NotReady("gravity query output was truncated")
        if "0.0.0.0" not in result.stdout:
            raise _NotReady("gravity query was not blocked yet")
        return started

    started = _poll_until(
        dig_attempt,
        deadline=deadline,
        interval=QUERY_POLL_INTERVAL,
        phase=f"query-{lane}",
        action=f"{lane} gravity query",
        registry=registry,
    )
    base_url = state["urls"][lane]

    def observe() -> tuple[str, float]:
        search_from = int(math.floor(started)) - QUERY_INTERVAL_PADDING_SECONDS
        search_until = int(math.ceil(time.time())) + QUERY_INTERVAL_PADDING_SECONDS
        timeout = _bounded_timeout(deadline)
        if lane == "v5":
            assert token is not None
            return _v5_query_entry(
                base_url,
                token,
                start=search_from,
                until=search_until,
                registry=registry,
                timeout=timeout,
                deadline=deadline,
            )
        assert session is not None
        try:
            sid = session.session(timeout=timeout, deadline=deadline)
            return _v6_query_entry(
                base_url,
                sid,
                start=search_from,
                until=search_until,
                registry=registry,
                timeout=timeout,
                deadline=deadline,
            )
        except _SessionExpired:
            session.invalidate()
            raise _NotReady("v6 session expired; re-authenticating") from None

    client_text, observed_at = _poll_until(
        observe,
        deadline=deadline,
        interval=QUERY_POLL_INTERVAL,
        phase=f"query-{lane}",
        action=f"{lane} gravity query visibility",
        registry=registry,
    )
    query_start = int(math.floor(started)) - QUERY_INTERVAL_PADDING_SECONDS
    query_end = (
        int(math.ceil(max(observed_at, time.time()))) + QUERY_INTERVAL_PADDING_SECONDS
    )
    if query_end <= query_start:
        query_end = query_start + 1
    if not query_start <= observed_at <= query_end:
        raise HarnessError(
            f"{lane} gravity query timestamp is outside the recorded interval",
            phase=f"query-{lane}",
        )
    return {
        "url": base_url,
        "query_start": query_start,
        "query_end": query_end,
        "client_ip": _numeric_client_ip(lane, client_text),
    }


# ------------------------------------------------------- compose preparation


def compose_path() -> Path:
    return Path(__file__).resolve().parent / "compose.yml"


def down_path() -> Path:
    return Path(__file__).resolve().parent / "down"


def _compose_arguments(project: str, *arguments: str) -> list[str]:
    return [
        "compose",
        "--file",
        str(compose_path()),
        "--project-name",
        project,
        *arguments,
    ]


def _compose_command(project: str, *arguments: str) -> list[str]:
    return ["docker", *_compose_arguments(project, *arguments)]


def _compose_environment(
    state: dict,
    credentials: Mapping[str, str],
    endpoint: str,
    base_env: Mapping[str, str],
) -> dict[str, str]:
    env = {str(key): str(value) for key, value in base_env.items()}
    env.pop("DOCKER_HOST", None)
    env["DOCKER_HOST"] = endpoint
    env.update(
        {
            "HARNESS_PROJECT": state["project"],
            "HARNESS_RUN_ID": state["run_id"],
            "HARNESS_WORKTREE": state["worktree"],
            "HARNESS_OWNER": state["ownership_token"],
            "HARNESS_V5_PASSWORD": credentials["v5_password"],
            "HARNESS_V6_PASSWORD": credentials["v6_password"],
            "HARNESS_V5_PORT": str(state["ports"]["v5"]),
            "HARNESS_V6_PORT": str(state["ports"]["v6"]),
        }
    )
    return env


class _PhaseLogs:
    """Unique per-invocation log directories so repeated runs cannot erase evidence."""

    def __init__(self, directory: Path):
        self._base = directory
        self.directory = self._allocate_invocation(directory)
        self._counter = 0
        self.paths: list[Path] = []

    @staticmethod
    def _allocate_invocation(directory: Path) -> Path:
        for _attempt in range(10):
            name = (
                f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-"
                f"{secrets_module.token_hex(4)}"
            )
            candidate = directory / name
            try:
                os.mkdir(candidate, 0o700)
            except FileExistsError:
                continue
            except OSError as error:
                raise HarnessError(
                    f"cannot create invocation log directory {candidate}: {error}",
                    phase="output",
                ) from error
            os.chmod(candidate, 0o700)
            return candidate
        raise HarnessError(
            "could not allocate a unique invocation log directory",
            phase="output",
        )

    def next_path(self, label: str) -> Path:
        self._counter += 1
        safe = re.sub(r"[^a-z0-9-]+", "-", label.lower()).strip("-") or "phase"
        path = self.directory / f"{self._counter:02d}-{safe}.log"
        self.paths.append(path)
        return path


def _run_streamed(
    command: Sequence[str],
    *,
    env: Mapping[str, str],
    timeout: float,
    log_path: Path,
    registry: SecretRegistry,
    stdout: IO[str],
    stderr: IO[str],
) -> int:
    try:
        return run_supervised(
            list(command),
            timeout=timeout,
            log_path=log_path,
            secrets=registry,
            stdout=stdout,
            stderr=stderr,
            env=env,
        )
    except ValueError as error:
        raise HarnessError(str(error), phase="command") from error


def _compose_images(
    *, compose_env: Mapping[str, str], registry: SecretRegistry, log: "_PhaseLog"
) -> list[str]:
    project = compose_env["HARNESS_PROJECT"]
    result = _run_docker(
        _compose_arguments(project, "config", "--images"),
        env=compose_env,
        phase="images",
    )
    if result.timed_out:
        raise HarnessError(
            "Compose image lookup exceeded its deadline", phase="images", exit_code=124
        )
    if result.interrupted_signal is not None:
        raise HarnessError(
            f"Compose image lookup interrupted by signal {result.interrupted_signal}",
            phase="images",
            exit_code=128 + result.interrupted_signal,
        )
    if result.stdout_truncated or result.stderr_truncated:
        raise HarnessError(
            "Compose image list exceeded the capture bound", phase="images"
        )
    if result.returncode != 0:
        detail = _safe_docker_detail(result, registry)
        raise HarnessError(
            f"Compose image lookup failed with status {result.returncode}"
            + (f": {detail}" if detail else ""),
            phase="images",
        )
    images: list[str] = []
    for line in result.stdout.splitlines():
        candidate = line.strip()
        if not candidate or candidate in images:
            continue
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9./:_@-]{0,255}", candidate):
            raise HarnessError("Compose returned an invalid image reference", phase="images")
        images.append(candidate)
    if not images:
        raise HarnessError("Compose returned no images to verify", phase="images")
    return images


def _inspect_image(
    image: str, *, env: Mapping[str, str], phase: str
) -> str | None:
    result = _run_docker(
        ["image", "inspect", "--format", "{{.Id}}", image], env=env, phase=phase
    )
    if result.timed_out:
        raise HarnessError(
            f"image inspection for {image} exceeded its deadline",
            phase=phase,
            exit_code=124,
        )
    if result.interrupted_signal is not None:
        raise HarnessError(
            f"image inspection for {image} interrupted by signal "
            f"{result.interrupted_signal}",
            phase=phase,
            exit_code=128 + result.interrupted_signal,
        )
    if result.stdout_truncated:
        raise HarnessError(f"image inspection for {image} exceeded the capture bound", phase=phase)
    if result.returncode != 0:
        return None
    identifier = result.stdout.strip()
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", identifier):
        raise HarnessError(
            f"image {image} returned an unexpected identifier", phase=phase
        )
    return identifier


def _ensure_images(
    *,
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    log: "_PhaseLog",
    stdout: IO[str],
    stderr: IO[str],
    logs: _PhaseLogs,
) -> dict[str, str]:
    images = _compose_images(compose_env=compose_env, registry=registry, log=log)
    identifiers: dict[str, str] = {}
    missing: list[str] = []
    for image in images:
        identifier = _inspect_image(image, env=compose_env, phase="images")
        if identifier is None:
            missing.append(image)
        else:
            identifiers[image] = identifier
    if missing:
        log.emit("images", "pulling", count=len(missing))
        status = _run_streamed(
            _compose_command(compose_env["HARNESS_PROJECT"], "pull", "--quiet"),
            env=compose_env,
            timeout=IMAGE_PULL_TIMEOUT,
            log_path=logs.next_path("image-pull"),
            registry=registry,
            stdout=stdout,
            stderr=stderr,
        )
        if status == 124:
            raise HarnessError(
                "image pull exceeded its deadline", phase="images", exit_code=124
            )
        if status != 0:
            raise HarnessError(
                f"image pull failed with status {status}",
                phase="images",
                exit_code=status,
            )
        for image in missing:
            identifier = _inspect_image(image, env=compose_env, phase="images")
            if identifier is None:
                raise HarnessError(
                    f"required image is unavailable after pull: {image}",
                    phase="images",
                )
            identifiers[image] = identifier
    log.emit("images", "ok", images=len(images))
    return identifiers


def _compose_up(
    *,
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    log: "_PhaseLog",
    stdout: IO[str],
    stderr: IO[str],
    logs: _PhaseLogs,
) -> None:
    status = _run_streamed(
        _compose_command(compose_env["HARNESS_PROJECT"], "up", "-d"),
        env=compose_env,
        timeout=SERVICE_READINESS_TIMEOUT,
        log_path=logs.next_path("compose-up"),
        registry=registry,
        stdout=stdout,
        stderr=stderr,
    )
    if status == 124:
        raise HarnessError(
            "container startup exceeded its deadline", phase="startup", exit_code=124
        )
    if status != 0:
        raise HarnessError(
            f"container startup failed with status {status}",
            phase="startup",
            exit_code=status,
        )
    log.emit("startup", "ok")


def _validated_urls(state: dict) -> dict[str, str]:
    ports = state.get("ports")
    urls = state.get("urls")
    if not isinstance(ports, dict) or not isinstance(urls, dict):
        raise StateError("state ports or urls are missing")
    validated: dict[str, str] = {}
    for lane in ("v5", "v6"):
        port = validate_port(ports.get(lane), f"{lane} port")
        expected = f"http://127.0.0.1:{port}"
        if urls.get(lane) != expected:
            raise StateError(
                f"state {lane} URL does not match its recorded loopback port"
            )
        validated[lane] = expected
    return validated


def _validate_publications(
    state: dict,
    *,
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    log: "_PhaseLog",
) -> None:
    urls = _validated_urls(state)
    for lane in ("v5", "v6"):
        port = state["ports"][lane]
        expected = f"127.0.0.1:{port}"
        result = _run_docker(
            _compose_arguments(
                state["project"], "port", LANE_SERVICES[lane], "80"
            ),
            env=compose_env,
            phase=f"publication-{lane}",
        )
        if result.timed_out:
            raise HarnessError(
                f"{lane} port publication lookup exceeded its deadline",
                phase=f"publication-{lane}",
                exit_code=124,
            )
        if result.interrupted_signal is not None:
            raise HarnessError(
                f"{lane} port publication lookup interrupted by signal "
                f"{result.interrupted_signal}",
                phase=f"publication-{lane}",
                exit_code=128 + result.interrupted_signal,
            )
        if result.stdout_truncated or result.stderr_truncated:
            raise HarnessError(
                f"{lane} port publication output exceeded the capture bound",
                phase=f"publication-{lane}",
            )
        if result.returncode != 0:
            detail = _safe_docker_detail(result, registry)
            raise HarnessError(
                f"{lane} port publication lookup failed with status "
                f"{result.returncode}" + (f": {detail}" if detail else ""),
                phase=f"publication-{lane}",
            )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if expected not in lines:
            raise HarnessError(
                f"{lane} HTTP port is not published on the recorded loopback address",
                phase=f"publication-{lane}",
            )
        for line in lines:
            if not line.startswith("127.0.0.1:"):
                raise HarnessError(
                    f"{lane} HTTP port has a non-loopback publication",
                    phase=f"publication-{lane}",
                )
        log.emit(f"publication-{lane}", "ok", url=urls[lane])


def _assert_name_absent(
    kind: str,
    name: str,
    *,
    env: Mapping[str, str],
    registry: SecretRegistry,
) -> None:
    result = _run_docker(
        [kind, "inspect", "--format", "{{.Name}}", name],
        env=env,
        phase="lookup",
    )
    if result.timed_out:
        raise HarnessError(
            f"{kind} name lookup exceeded its deadline", phase="lookup", exit_code=124
        )
    if result.interrupted_signal is not None:
        raise HarnessError(
            f"{kind} name lookup interrupted by signal {result.interrupted_signal}",
            phase="lookup",
            exit_code=128 + result.interrupted_signal,
        )
    if result.stdout_truncated or result.stderr_truncated:
        raise HarnessError(
            f"{kind} name lookup output exceeded the capture bound", phase="lookup"
        )
    if result.returncode == 0:
        raise StateError(
            f"{kind} {name} exists without harness ownership; refusing to reuse it"
        )
    detail = result.stderr.lower()
    if "no such" not in detail and "not found" not in detail:
        safe_detail = registry.sanitize(result.stderr.splitlines()[0] if result.stderr else "")[:200]
        raise HarnessError(
            f"cannot check {kind} name {name} (status {result.returncode})"
            + (f": {safe_detail}" if safe_detail else ""),
            phase="lookup",
        )


def _assert_no_existing_project(
    project: str,
    *,
    env: Mapping[str, str],
    registry: SecretRegistry,
) -> None:
    resources = discover_project_resources(project, env=env, registry=registry)
    if any(resources.values()):
        raise StateError(
            f"project {project} already has resources; run down --project {project} first"
        )
    _assert_name_absent("network", f"{project}_network", env=env, registry=registry)
    _assert_name_absent(
        "volume", f"{project}_pihole-v5-data", env=env, registry=registry
    )
    _assert_name_absent(
        "volume", f"{project}_pihole-v6-data", env=env, registry=registry
    )



# ------------------------------------------------------- prepare orchestration


def _write_private_text(path: Path, text: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise


def _as_harness_error(error: BaseException, *, phase: str = "harness") -> HarnessError:
    if isinstance(error, HarnessError):
        return error
    if isinstance(error, _Interrupted):
        return HarnessError(
            f"interrupted by signal {error.signum}",
            phase="interrupt",
            exit_code=128 + error.signum,
        )
    if isinstance(error, KeyboardInterrupt):
        return HarnessError("interrupted by user", phase=phase, exit_code=130)
    if isinstance(error, SystemExit):
        code = error.code if isinstance(error.code, int) else 1
        return HarnessError(f"exit status {code}", phase=phase, exit_code=code)
    return HarnessError(f"{type(error).__name__}: {error}", phase=phase)


def _down_command(project: str, endpoint: str) -> str:
    return (
        f"DOCKER_HOST={shlex.quote(endpoint)} "
        f"{shlex.quote(str(down_path()))} --project {shlex.quote(project)}"
    )


def _finish_preparation(
    *,
    v6: "_V6Readiness",
    primary: BaseException | None,
    timeout: float = DOCKER_OPERATION_TIMEOUT,
) -> None:
    """Suspend cooperative interruption, attempt all logouts, preserve first error."""
    guard = _ACTIVE_INTERRUPT
    if primary is None and guard is not None and guard.signum is not None:
        primary = _Interrupted(guard.signum)
    previous_suspended = guard.begin_cleanup() if guard is not None else None
    try:
        try:
            logout_error = v6.close(timeout=timeout)
        except HarnessError as error:
            logout_error = error
        except BaseException as error:  # noqa: BLE001 - cleanup must continue
            logout_error = _as_harness_error(error, phase="prepare")
    finally:
        if guard is not None:
            guard.end_cleanup(previous_suspended)
    if primary is not None:
        primary_error = _as_harness_error(primary, phase="prepare")
        if logout_error is not None:
            raise HarnessError(
                f"{primary_error} (secondary v6 logout failure: {logout_error})",
                phase=primary_error.phase,
                exit_code=primary_error.exit_code,
            ) from primary
        raise primary_error
    if logout_error is not None:
        raise logout_error
    if guard is not None and guard.signum is not None:
        raise _as_harness_error(_Interrupted(guard.signum), phase="prepare")


def _prepare_allocation(
    *,
    state: dict,
    worktree: Path,
    credentials: Mapping[str, str],
    compose_env: Mapping[str, str],
    registry: SecretRegistry,
    log: "_PhaseLog",
    stdout: IO[str],
    stderr: IO[str],
    logs: _PhaseLogs,
    phase: str = "prepare",
) -> Prepared:
    runtime_dir = _state_runtime_directory(state, worktree=worktree)
    _validate_publications(state, compose_env=compose_env, registry=registry, log=log)
    urls = _validated_urls(state)
    durations: dict[str, float] = {}
    token_holder: dict[str, str] = {}
    v6 = _V6Readiness(urls["v6"], credentials["v6_password"], registry=registry)
    primary: BaseException | None = None
    prepared: Prepared | None = None
    overall_started = time.monotonic()

    try:
        started = time.monotonic()
        deadline = started + SERVICE_READINESS_TIMEOUT

        def v5_attempt() -> None:
            _check_dns(
                "v5",
                compose_env=compose_env,
                registry=registry,
                timeout=_bounded_timeout(deadline),
            )
            if "token" not in token_holder:
                try:
                    token = _extract_v5_token(
                        project=state["project"],
                        compose_env=compose_env,
                        registry=registry,
                        timeout=_bounded_timeout(deadline),
                    )
                except HarnessError as error:
                    if error.exit_code in (124, 130, 143):
                        raise
                    raise _NotReady(str(error)) from None
                _store_v5_token(state, worktree=worktree, token=token)
                token_holder["token"] = token
            _v5_authenticated_status(
                urls["v5"],
                token_holder["token"],
                registry=registry,
                timeout=_bounded_timeout(deadline),
                deadline=deadline,
            )

        _poll_until(
            v5_attempt,
            deadline=deadline,
            interval=READINESS_POLL_INTERVAL,
            phase="readiness-v5",
            action="v5 service readiness",
            registry=registry,
        )
        durations["readiness_v5"] = time.monotonic() - started
        log.emit("readiness-v5", "ok", url=urls["v5"])

        started = time.monotonic()
        deadline = started + SERVICE_READINESS_TIMEOUT

        def v6_attempt() -> None:
            _check_dns(
                "v6",
                compose_env=compose_env,
                registry=registry,
                timeout=_bounded_timeout(deadline),
            )
            try:
                sid = v6.session(
                    timeout=_bounded_timeout(deadline), deadline=deadline
                )
                _v6_authenticated_status(
                    urls["v6"],
                    sid,
                    registry=registry,
                    timeout=_bounded_timeout(deadline),
                    deadline=deadline,
                )
            except _SessionExpired:
                v6.invalidate()
                raise _NotReady("v6 session expired; re-authenticating") from None

        _poll_until(
            v6_attempt,
            deadline=deadline,
            interval=READINESS_POLL_INTERVAL,
            phase="readiness-v6",
            action="v6 service readiness",
            registry=registry,
        )
        durations["readiness_v6"] = time.monotonic() - started
        log.emit("readiness-v6", "ok", url=urls["v6"])

        lane_metadata: dict[str, dict[str, object]] = {}
        for lane in ("v5", "v6"):
            started = time.monotonic()
            deadline = started + FIXTURE_SETUP_TIMEOUT
            seed_command = [
                str(Path(__file__).resolve().parent / LANE_SEED_SCRIPTS[lane]),
                state["project"],
            ]

            def run_seed(
                command: Sequence[str] = seed_command,
                seed_deadline: float = deadline,
                seed_lane: str = lane,
            ) -> int:
                return _run_streamed(
                    command,
                    env=compose_env,
                    timeout=_bounded_timeout(
                        seed_deadline, maximum=FIXTURE_SETUP_TIMEOUT
                    ),
                    log_path=logs.next_path(f"seed-{seed_lane}"),
                    registry=registry,
                    stdout=stdout,
                    stderr=stderr,
                )

            if lane == "v5":

                def read_v5(
                    fixture_deadline: float = deadline,
                ) -> dict[str, tuple[str, ...]]:
                    return _v5_fixture_data(
                        urls["v5"],
                        token_holder["token"],
                        registry=registry,
                        timeout=_bounded_timeout(fixture_deadline),
                        deadline=fixture_deadline,
                    )

                read_fixtures: Callable[[], dict[str, tuple[str, ...]]] = read_v5
            else:

                def read_v6(
                    fixture_deadline: float = deadline,
                ) -> dict[str, tuple[str, ...]]:
                    try:
                        sid = v6.session(
                            timeout=_bounded_timeout(fixture_deadline),
                            deadline=fixture_deadline,
                        )
                        return _v6_fixture_data(
                            urls["v6"],
                            sid,
                            registry=registry,
                            timeout=_bounded_timeout(fixture_deadline),
                            deadline=fixture_deadline,
                        )
                    except _SessionExpired:
                        v6.invalidate()
                        raise _NotReady(
                            "v6 session expired; re-authenticating"
                        ) from None

                read_fixtures = read_v6

            _seed_and_verify(
                lane,
                run_seed=run_seed,
                read_fixtures=read_fixtures,
                deadline=deadline,
                registry=registry,
                log=log,
            )
            _verify_gravity_sources(
                lane,
                compose_env=compose_env,
                registry=registry,
                deadline=deadline,
            )
            durations[f"fixtures_{lane}"] = time.monotonic() - started

            started = time.monotonic()
            lane_metadata[lane] = _observe_gravity_query(
                lane,
                state=state,
                compose_env=compose_env,
                registry=registry,
                token=token_holder.get("token"),
                session=v6 if lane == "v6" else None,
            )
            durations[f"query_{lane}"] = time.monotonic() - started
            log.emit(
                f"query-{lane}",
                "ok",
                client_ip=lane_metadata[lane]["client_ip"],
                window=(
                    f"{lane_metadata[lane]['query_start']}-"
                    f"{lane_metadata[lane]['query_end']}"
                ),
            )

        fixtures = {
            "schema_version": 1,
            "lanes": {
                "v5": lane_metadata["v5"],
                "v6": lane_metadata["v6"],
            },
        }
        fixtures_path = runtime_dir / "fixtures.json"
        _write_private_json(fixtures_path, fixtures)
        durations["total"] = time.monotonic() - overall_started
        prepared = Prepared(
            fixtures_path=fixtures_path,
            fixtures=fixtures,
            durations=durations,
        )
    except BaseException as error:
        primary = error

    _finish_preparation(v6=v6, primary=primary)
    assert prepared is not None
    return prepared


def prepare_state(
    state_path: str | Path,
    *,
    worktree: str | Path | None = None,
    env: Mapping[str, str] | None = None,
    stdout: IO[str] | None = None,
    stderr: IO[str] | None = None,
    phase: str = "prepare",
    log: "_PhaseLog" | None = None,
    logs: _PhaseLogs | None = None,
) -> dict[str, object]:
    """Verify an already-started owned project and write non-secret fixture metadata."""
    worktree_path = canonical_worktree(worktree)
    owns_log = log is None
    output_stream = stdout if stdout is not None else sys.stdout
    error_stream = stderr if stderr is not None else sys.stderr
    phase_log = log if log is not None else _PhaseLog(output_stream, error_stream)
    primary: BaseException | None = None
    result: dict[str, object] | None = None
    with _lifecycle_interrupts() as guard:
        try:
            state_candidate = Path(state_path)
            if not state_candidate.is_absolute():
                state_candidate = Path.cwd() / state_candidate
            state = load_state_record(state_candidate, worktree=worktree_path)
            runtime_dir = _state_runtime_directory(state, worktree=worktree_path)
            secrets_path, credentials = _load_state_credentials(
                state, worktree=worktree_path
            )
            registry = SecretRegistry(credentials)
            phase_log.set_registry(registry)

            endpoint = preflight_docker(env, registry=registry)
            phase_log.emit("preflight", "ok", endpoint=endpoint)

            resources = discover_project_resources(
                state["project"], env=env, registry=registry
            )
            if not any(resources.values()):
                raise OwnershipError(
                    "recorded project has no running resources; start it with up first"
                )
            _validate_ownership(state, resources, env=env, registry=registry)
            phase_log.emit(
                "ownership",
                "ok",
                containers=len(resources["containers"]),
                networks=len(resources["networks"]),
                volumes=len(resources["volumes"]),
            )

            compose_env = _compose_environment(
                state, credentials, endpoint, _endpoint_environment(env)
            )
            logs_dir = runtime_dir / "logs"
            _ensure_private_dir(logs_dir)
            selected_logs = logs if logs is not None else _PhaseLogs(logs_dir)

            prepared = _prepare_allocation(
                state=state,
                worktree=worktree_path,
                credentials=credentials,
                compose_env=compose_env,
                registry=registry,
                log=phase_log,
                stdout=output_stream,
                stderr=error_stream,
                logs=selected_logs,
                phase=phase,
            )
            result = {
                "project": state["project"],
                "mode": state.get("mode"),
                "urls": _validated_urls(state),
                "endpoint": endpoint,
                "runtime_dir": runtime_dir,
                "secrets_path": secrets_path,
                "artifact_directory": state["artifact_directory"],
                "fixtures_path": prepared.fixtures_path,
                "fixtures": prepared.fixtures,
                "durations": prepared.durations,
            }
            phase_log.emit(
                phase,
                "ok",
                project=result["project"],
                v5_url=result["urls"]["v5"],
                v6_url=result["urls"]["v6"],
                secrets=str(secrets_path),
                secret_fields="v5_token,v6_password",
                fixtures=str(prepared.fixtures_path),
                artifacts=state["artifact_directory"],
                down=_down_command(state["project"], endpoint),
                swift_scenarios="not_run",
                **{
                    f"duration_{key}": round(value, 3)
                    for key, value in prepared.durations.items()
                },
            )
        except BaseException as error:
            primary = _as_harness_error(error)
            phase_log.emit(primary.phase, "failed", detail=str(primary))

        if primary is None and guard.signum is not None:
            primary = _as_harness_error(_Interrupted(guard.signum))
            phase_log.emit(primary.phase, "failed", detail=str(primary))

    output_failure = phase_log.finish() if owns_log else None
    if primary is not None:
        if output_failure:
            raise HarnessError(
                f"{primary} (secondary output failure: {output_failure})",
                phase=primary.phase,
                exit_code=primary.exit_code,
            ) from primary
        raise primary
    if output_failure:
        raise HarnessError(
            f"lifecycle output failed: {output_failure}", phase="output", exit_code=1
        )
    assert result is not None
    return result


def _read_bounded_log(
    path: Path, limit: int = MAX_EVIDENCE_BYTES
) -> tuple[str, bool]:
    """Read streamed evidence by complete records without loading the whole file."""
    chunks: list[str] = []
    total = 0
    truncated = False
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        while True:
            remaining = limit - total
            if remaining <= 0:
                truncated = True
                break
            line = handle.readline(min(remaining + 1, MAX_RECORD_BYTES + 1))
            if not line:
                break
            encoded = line.encode("utf-8", errors="replace")
            if len(encoded) > remaining or (
                not line.endswith("\n") and len(line) > MAX_RECORD_BYTES
            ):
                truncated = True
                break
            chunks.append(line)
            total += len(encoded)
            if not line.endswith("\n"):
                break
    return "".join(chunks), truncated


def _bounded_evidence_text(text: str, *, truncated: bool = False) -> str:
    """Keep complete records inside the evidence budget and mark any omission."""
    encoded = text.encode("utf-8", errors="replace")
    if len(encoded) <= MAX_EVIDENCE_BYTES:
        return text + ("\n[truncated for evidence]\n" if truncated else "")
    kept: list[str] = []
    total = 0
    for line in text.splitlines(keepends=True):
        size = len(line.encode("utf-8", errors="replace"))
        if total + size > MAX_EVIDENCE_BYTES:
            break
        kept.append(line)
        total += size
    return "".join(kept).rstrip("\n") + "\n[truncated for evidence]\n"


def _collect_failure_evidence(
    *,
    state: dict,
    primary: BaseException,
    compose_env: Mapping[str, str] | None,
    registry: SecretRegistry,
    logs: _PhaseLogs | None,
    worktree: Path,
) -> Path:
    root = worktree / RUNTIME_DIRNAME / FAILURES_DIRNAME
    _ensure_private_dir(root)
    evidence = Path(tempfile.mkdtemp(prefix=f"{state['run_id']}-", dir=root))
    os.chmod(evidence, 0o700)
    failure_text = _bounded_evidence_text(registry.sanitize(str(primary)))
    _write_private_text(
        evidence / "failure.txt", failure_text.rstrip() + "\n"
    )
    for path in (logs.paths if logs is not None else []):
        if not path.is_file():
            continue
        try:
            text, truncated = _read_bounded_log(path)
        except OSError as error:
            text = f"unavailable: {type(error).__name__}\n"
            truncated = False
        safe = _bounded_evidence_text(
            registry.sanitize(text), truncated=truncated
        )
        _write_private_text(evidence / f"phase-{path.name}", safe)
    for name, arguments in (
        ("compose-ps", _compose_arguments(state["project"], "ps")),
        (
            "container-logs",
            _compose_arguments(
                state["project"], "logs", "--no-color", "--tail", "200"
            ),
        ),
    ):
        if compose_env is None:
            continue
        try:
            result = _run_docker(arguments, env=compose_env, phase="diagnostics")
        except HarnessError as error:
            safe_error = _bounded_evidence_text(
                registry.sanitize(str(error))
            )
            _write_private_text(
                evidence / f"{name}.txt", f"unavailable: {safe_error}\n"
            )
            continue
        prefix = ""
        if result.timed_out:
            prefix = "diagnostic timed out; incomplete final record omitted\n"
        elif result.interrupted_signal is not None:
            prefix = (
                "diagnostic interrupted by signal "
                f"{result.interrupted_signal}; incomplete final record omitted\n"
            )
        elif result.stdout_truncated or result.stderr_truncated:
            prefix = "diagnostic capture truncated; incomplete final record omitted\n"
        if result.stdout:
            text = result.stdout
            truncated = result.stdout_truncated
        else:
            text = result.stderr
            truncated = result.stderr_truncated
        truncated = bool(
            truncated
            or result.timed_out
            or result.interrupted_signal is not None
        )
        text = _complete_capture_record(text, truncated)
        safe = _bounded_evidence_text(
            registry.sanitize(text), truncated=truncated
        )
        _write_private_text(evidence / f"{name}.txt", prefix + safe)
    return evidence





class _PhaseLog:
    def __init__(self, stdout: IO[str], stderr: IO[str]):
        self._registry = SecretRegistry()
        self._stdout_stream = stdout
        self._stderr_stream = stderr
        self._stdout = OutputSink("stdout", stdout)
        self._stderr = OutputSink("stderr", stderr)
        self._sinks = (self._stdout, self._stderr)
        self._reported: set[str] = set()
        self._phase_started = time.monotonic()

    def set_registry(self, registry: SecretRegistry) -> None:
        self._registry = registry

    def emit(self, phase: str, status: str, **fields: object) -> None:
        now = time.monotonic()
        line = format_phase(
            phase,
            status,
            elapsed=now - self._phase_started,
            **fields,
        ) + "\n"
        self._phase_started = now
        line = self._registry.sanitize(line)
        if not self._stdout.write(line):
            self._stderr.write(line)

    def finish(self, timeout: float = SINK_FLUSH_TIMEOUT) -> str | None:
        failures: list[str] = []
        deadline = time.monotonic() + max(0.0, timeout)
        for sink in self._sinks:
            sink.drain(max(0.0, deadline - time.monotonic()))
        self._collect(failures)
        if failures:
            deadline = time.monotonic() + max(0.0, timeout)
            for sink in self._sinks:
                sink.drain(max(0.0, deadline - time.monotonic()))
            self._collect(failures)
        for sink in self._sinks:
            sink.close(timeout)
        self._collect(failures)
        return "; ".join(failures) if failures else None

    def deliver_late(self, text: str) -> str | None:
        """Deliver one final sanitized line through a healthy, bounded sink."""
        if self._stdout.error is None and self._stdout_stream is not None:
            name, stream = "stdout", self._stdout_stream
        elif self._stderr.error is None and self._stderr_stream is not None:
            name, stream = "stderr", self._stderr_stream
        else:
            return "no healthy console stream"
        sink = OutputSink(f"late-{name}", stream)
        try:
            if not sink.write(self._registry.sanitize(text)):
                return f"{name}: {sink.error or 'write rejected'}"
            sink.drain(SINK_FLUSH_TIMEOUT)
            sink.close(SINK_FLUSH_TIMEOUT)
            if sink.error is not None:
                return f"{name}: {sink.error}"
            return None
        except BaseException as error:  # noqa: BLE001 - bounded diagnostic fallback
            try:
                sink.close(SINK_FLUSH_TIMEOUT)
            except Exception:
                pass
            return f"{name}: {type(error).__name__}"

    def _collect(self, failures: list[str]) -> None:
        for sink in self._sinks:
            detail = sink.error
            if detail is None or sink.name in self._reported:
                continue
            self._reported.add(sink.name)
            safe_detail = self._registry.sanitize(detail)
            failures.append(f"{sink.name}: {safe_detail}")
            line = format_phase(
                "output", "failed", sink=sink.name, detail=safe_detail
            ) + "\n"
            for target in self._sinks:
                if target.name != sink.name:
                    target.write(line)


def teardown_project(
    project: str | None = None,
    *,
    worktree: str | Path | None = None,
    env: Mapping[str, str] | None = None,
    stdout: IO[str] | None = None,
    stderr: IO[str] | None = None,
) -> dict[str, object]:
    """Validate ownership, then remove only this project's owned resources."""
    log = _PhaseLog(
        stdout if stdout is not None else sys.stdout,
        stderr if stderr is not None else sys.stderr,
    )
    error: HarnessError | None = None
    summary: dict[str, object] | None = None
    try:
        summary = _teardown_project(
            project=project,
            worktree=worktree,
            env=env,
            log=log,
        )
    except HarnessError as caught:
        error = caught
        log.emit(caught.phase, "failed", detail=str(caught))
    except BaseException:
        log.finish()
        raise
    output_failure = log.finish()
    if error is not None:
        if output_failure:
            raise HarnessError(
                f"{error} (secondary output failure: {output_failure})",
                phase=error.phase,
                exit_code=error.exit_code,
            ) from error
        raise error
    if output_failure:
        raise HarnessError(
            f"lifecycle output failed: {output_failure}",
            phase="output",
            exit_code=1,
        )
    assert summary is not None
    return summary


def _teardown_project(
    *,
    project: str | None,
    worktree: str | Path | None,
    env: Mapping[str, str] | None,
    log: _PhaseLog,
) -> dict[str, object]:
    worktree_path = canonical_worktree(worktree)
    chosen_project = validate_project_name(project or default_manual_project(worktree_path))

    state_path = _state_candidate(worktree_path, chosen_project)
    state = (
        load_state_record(state_path, worktree=worktree_path, expected_project=chosen_project)
        if state_path is not None
        else None
    )
    if state is not None:
        registry = _load_state_secrets(state, worktree=worktree_path)
    else:
        registry = SecretRegistry()
    log.set_registry(registry)
    log.emit("state", "ok" if state is not None else "absent", project=chosen_project)

    endpoint = preflight_docker(env, registry=registry)
    log.emit("preflight", "ok", endpoint=endpoint)

    resources = discover_project_resources(chosen_project, env=env, registry=registry)
    log.emit(
        "lookup",
        "ok",
        containers=len(resources["containers"]),
        networks=len(resources["networks"]),
        volumes=len(resources["volumes"]),
    )
    found_any = any(resources.values())

    if state is None:
        if found_any:
            raise OwnershipError(
                f"project {chosen_project} has resources but no recorded harness state; "
                "refusing unverified teardown"
            )
        log.emit("teardown", "noop", project=chosen_project)
        return {
            "project": chosen_project,
            "state": None,
            "containers": [],
            "networks": [],
            "volumes": [],
        }

    _validate_ownership(state, resources, env=env, registry=registry)
    log.emit(
        "ownership",
        "ok",
        containers=len(resources["containers"]),
        networks=len(resources["networks"]),
        volumes=len(resources["volumes"]),
    )

    failures: list[tuple[str, int]] = []
    commands = {
        "containers": ["rm", "--force"],
        "networks": ["network", "rm"],
        "volumes": ["volume", "rm"],
    }
    for kind in ("containers", "networks", "volumes"):
        for resource_id in resources[kind]:
            try:
                result = _run_docker(
                    [*commands[kind], resource_id],
                    env=env,
                    phase="teardown",
                )
            except HarnessError as error:
                failures.append(
                    (registry.sanitize(f"{kind[:-1]} {resource_id}: {error}"), error.exit_code)
                )
                continue
            if (
                result.returncode == 0
                and not result.timed_out
                and result.interrupted_signal is None
            ):
                continue
            detail = _safe_docker_detail(result, registry)
            if result.timed_out:
                exit_code = 124
                reason = "timed out"
            elif result.interrupted_signal is not None:
                exit_code = 128 + result.interrupted_signal
                reason = f"interrupted by signal {result.interrupted_signal}"
            else:
                exit_code = 1
                reason = f"status {result.returncode}"
            message = f"{kind[:-1]} {resource_id} {reason}"
            if detail:
                message += f": {detail}"
            failures.append((registry.sanitize(message), exit_code))

    if failures:
        first_detail, first_code = failures[0]
        message = "teardown failed; state retained for retry: " + first_detail
        if len(failures) > 1:
            message += "; secondary: " + "; ".join(
                detail for detail, _code in failures[1:][:9]
            )
        raise HarnessError(message, phase="teardown", exit_code=first_code)

    if state_path is not None:
        _remove_runtime_directory(state_path.parent)
    log.emit(
        "teardown",
        "ok",
        containers=len(resources["containers"]),
        networks=len(resources["networks"]),
        volumes=len(resources["volumes"]),
    )
    return {
        "project": chosen_project,
        "state": state.get("mode"),
        "containers": resources["containers"],
        "networks": resources["networks"],
        "volumes": resources["volumes"],
    }


# --------------------------------------------------------------------- CLI


def _record_final_status(
    evidence: Path | None,
    primary: HarnessError,
    *,
    output_failure: str | None,
    evidence_failure: HarnessError | None,
    cleanup_failure: HarnessError | None,
    delivery_failure: str | None,
    registry: SecretRegistry,
) -> HarnessError | None:
    """Write a small bounded sanitized final status into surviving evidence."""
    if evidence is None:
        return HarnessError(
            "final status evidence destination is unavailable", phase="output"
        )
    lines = [
        f"phase={primary.phase} status=failed exit={primary.exit_code}",
        f"detail={registry.sanitize(str(primary))}",
    ]
    for label, value in (
        ("output", output_failure),
        ("evidence", evidence_failure),
        ("cleanup", cleanup_failure),
        ("delivery", delivery_failure),
    ):
        if value is not None:
            lines.append(f"{label}={registry.sanitize(str(value))}")
    text = _bounded_evidence_text("\n".join(lines) + "\n")
    try:
        _write_private_text(evidence / "final-status.txt", text)
    except OSError as error:
        return HarnessError(
            f"cannot write final status evidence: {error}", phase="output"
        )
    return None


def _cleanup_failed_up(
    *,
    allocation: Allocation | None,
    project: str,
    worktree: Path,
    env: Mapping[str, str],
    compose_env: Mapping[str, str] | None,
    registry: SecretRegistry,
    logs: _PhaseLogs | None,
    primary_error: HarnessError,
) -> tuple[Path | None, HarnessError | None, HarnessError | None]:
    """Collect best-effort evidence, then run the scoped teardown owner."""
    evidence: Path | None = None
    evidence_failure: HarnessError | None = None
    cleanup_failure: HarnessError | None = None
    if allocation is None:
        return evidence, evidence_failure, cleanup_failure
    try:
        evidence = _collect_failure_evidence(
            state=allocation.state,
            primary=primary_error,
            compose_env=compose_env,
            registry=registry,
            logs=logs,
            worktree=worktree,
        )
    except BaseException as error:
        evidence_failure = _as_harness_error(error)
    try:
        teardown_project(project, worktree=worktree, env=env)
    except HarnessError as error:
        cleanup_failure = error
    return evidence, evidence_failure, cleanup_failure


def _cli_up(arguments: argparse.Namespace) -> int:
    worktree_path = canonical_worktree()
    project = validate_project_name(
        arguments.project or default_manual_project(worktree_path)
    )
    ports = _validate_ports({"v5": arguments.v5_port, "v6": arguments.v6_port})
    env = _endpoint_environment(None)
    log = _PhaseLog(sys.stdout, sys.stderr)
    registry = SecretRegistry()
    allocation: Allocation | None = None
    compose_env: dict[str, str] | None = None
    logs: _PhaseLogs | None = None
    primary_error: HarnessError | None = None
    evidence: Path | None = None
    evidence_failure: HarnessError | None = None
    cleanup_failure: HarnessError | None = None

    with _lifecycle_interrupts() as guard:
        try:
            endpoint = preflight_docker(env, registry=registry)
            log.emit("preflight", "ok", endpoint=endpoint)
            _assert_no_existing_project(project, env=env, registry=registry)
            allocation = allocate_manual(
                worktree=worktree_path, project=project, ports=ports
            )
            registry = SecretRegistry(allocation.secrets)
            log.set_registry(registry)
            log.emit(
                "allocate",
                "ok",
                project=project,
                state=str(allocation.state_path),
                secrets=str(allocation.secrets_path),
                artifacts=str(allocation.artifact_directory),
            )
            compose_env = _compose_environment(
                allocation.state, allocation.secrets, endpoint, env
            )
            logs_dir = allocation.runtime_dir / "logs"
            _ensure_private_dir(logs_dir)
            logs = _PhaseLogs(logs_dir)
            _ensure_images(
                compose_env=compose_env,
                registry=registry,
                log=log,
                stdout=sys.stdout,
                stderr=sys.stderr,
                logs=logs,
            )
            _compose_up(
                compose_env=compose_env,
                registry=registry,
                log=log,
                stdout=sys.stdout,
                stderr=sys.stderr,
                logs=logs,
            )
            prepared = _prepare_allocation(
                state=allocation.state,
                worktree=worktree_path,
                credentials=allocation.secrets,
                compose_env=compose_env,
                registry=registry,
                log=log,
                stdout=sys.stdout,
                stderr=sys.stderr,
                logs=logs,
            )
            urls = _validated_urls(allocation.state)
            log.emit(
                "manual-startup",
                "ready",
                project=project,
                v5_url=urls["v5"],
                v6_url=urls["v6"],
                secrets=str(allocation.secrets_path),
                secret_fields="v5_token,v6_password",
                fixtures=str(prepared.fixtures_path),
                artifacts=str(allocation.artifact_directory),
                down=_down_command(project, endpoint),
                swift_scenarios="not_run",
                **{
                    f"duration_{key}": round(value, 3)
                    for key, value in prepared.durations.items()
                },
            )
        except BaseException as error:
            primary_error = _as_harness_error(error)

        if primary_error is None and guard.signum is not None:
            primary_error = _as_harness_error(_Interrupted(guard.signum))

        if primary_error is not None:
            guard.suspend()
            evidence, evidence_failure, cleanup_failure = _cleanup_failed_up(
                allocation=allocation,
                project=project,
                worktree=worktree_path,
                env=env,
                compose_env=compose_env,
                registry=registry,
                logs=logs,
                primary_error=primary_error,
            )
            log.emit(
                primary_error.phase,
                "failed",
                detail=str(primary_error),
                evidence=str(evidence) if evidence is not None else None,
                cleanup=str(cleanup_failure) if cleanup_failure is not None else None,
            )
            if evidence_failure is not None:
                log.emit(
                    evidence_failure.phase,
                    "failed",
                    stage="evidence",
                    detail=str(evidence_failure),
                )

        output_failure = log.finish()
        if output_failure and primary_error is None:
            # A late phase-output failure is still a failed allocated up.
            guard.suspend()
            late_error = HarnessError(
                f"lifecycle output failed: {output_failure}",
                phase="output",
                exit_code=1,
            )
            (
                late_evidence,
                late_evidence_failure,
                late_cleanup_failure,
            ) = _cleanup_failed_up(
                allocation=allocation,
                project=project,
                worktree=worktree_path,
                env=env,
                compose_env=compose_env,
                registry=registry,
                logs=logs,
                primary_error=late_error,
            )
            line = format_phase(
                "output",
                "failed",
                detail=f"lifecycle output failed: {output_failure}",
                exit=1,
                evidence=str(late_evidence) if late_evidence is not None else None,
            ) + "\n"
            delivery_failure = log.deliver_late(line)
            _record_final_status(
                late_evidence,
                late_error,
                output_failure=output_failure,
                evidence_failure=late_evidence_failure,
                cleanup_failure=late_cleanup_failure,
                delivery_failure=delivery_failure,
                registry=registry,
            )
            primary_error = late_error
        elif output_failure and primary_error is not None:
            line = format_phase(
                "output",
                "failed",
                stage="secondary",
                detail=output_failure,
                exit=primary_error.exit_code,
            ) + "\n"
            delivery_failure = log.deliver_late(line)
            _record_final_status(
                evidence,
                primary_error,
                output_failure=output_failure,
                evidence_failure=evidence_failure,
                cleanup_failure=cleanup_failure,
                delivery_failure=delivery_failure,
                registry=registry,
            )

    if primary_error is not None:
        return primary_error.exit_code
    return 0


# ------------------------------------------------------------------- reports

INTEGRATION_REPORT_MODULE = "HoleberryCoreIntegrationTests"
INTEGRATION_REPORT_SUITE = "PiholeIntegrationTests"
INTEGRATION_REPORT_METHODS = {
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
INTEGRATION_REPORT_MAX_BYTES = 8 * 1024 * 1024
INTEGRATION_REPORT_MAX_CASES = 10_000
INTEGRATION_REPORT_EXCERPT_LIMIT = 400
INTEGRATION_REPORT_MAX_EXCERPTS = 5
REPORT_CASE_NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
REPORT_CLASSNAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")


def _report_local_name(tag: object) -> str:
    if not isinstance(tag, str):
        return ""
    return tag.rsplit("}", 1)[-1]


def _report_case_name(name: str) -> str:
    return name[:-2] if name.endswith("()") else name


def _report_safe_label(classname: str, name: str) -> str:
    class_label = (
        classname
        if REPORT_CLASSNAME_PATTERN.fullmatch(classname)
        else "<unrecognized class>"
    )
    case_name = _report_case_name(name)
    case_label = (
        case_name
        if REPORT_CASE_NAME_PATTERN.fullmatch(case_name)
        else "<unrecognized case>"
    )
    return f"{class_label}.{case_label}"


def _report_count(suite: object, attribute: str) -> int:
    value = suite.get(attribute)
    if value is None:
        return 0
    try:
        count = int(value)
    except (TypeError, ValueError):
        raise ReportError("report XML is malformed") from None
    if count < 0:
        raise ReportError("report XML is malformed")
    return count


def _report_failure_excerpt(case: object, registry: SecretRegistry) -> str:
    parts: list[str] = []
    for child in case:
        if _report_local_name(child.tag) not in {"failure", "error"}:
            continue
        message = child.get("message") or ""
        text = child.text or ""
        combined = " ".join(part.strip() for part in (message, text) if part.strip())
        if not combined:
            continue
        sanitized = registry.sanitize(combined)
        sanitized = "".join(
            character if character.isprintable() else " " for character in sanitized
        )
        sanitized = " ".join(sanitized.split())
        if len(sanitized) > INTEGRATION_REPORT_EXCERPT_LIMIT:
            sanitized = sanitized[:INTEGRATION_REPORT_EXCERPT_LIMIT] + "..."
        parts.append(sanitized)
    return " | ".join(parts)


def _report_contains_secret(text: str, registry: SecretRegistry) -> bool:
    return any(value in text for value in registry.values_longest_first())


def _report_join(labels: list[str]) -> str:
    shown = labels[:INTEGRATION_REPORT_MAX_EXCERPTS]
    text = "; ".join(shown)
    if len(labels) > len(shown):
        text += f"; ... {len(labels) - len(shown)} more"
    return text


def _load_report_registry(secrets_path: str | None) -> SecretRegistry:
    if secrets_path is None:
        return SecretRegistry()
    path = Path(secrets_path)
    try:
        payload = _read_json(path)
    except (HarnessError, OSError, ValueError):
        raise ReportError(f"secret file is unreadable: {path}") from None
    if not isinstance(payload, dict):
        raise ReportError("secret file is malformed")
    values = {
        str(key): value
        for key, value in payload.items()
        if isinstance(value, str) and value
    }
    return SecretRegistry(values)


def validate_report(
    xml_path: str | Path, *, registry: SecretRegistry | None = None
) -> dict[str, object]:
    """Validate one real xUnit report from the integration runner.

    Requires exactly one executed passing case for each stable method in the
    integration suite. Unrelated unit cases are ignored for coverage but any
    failed, errored or skipped case fails the report. Failure text is sanitized
    and bounded before it appears in an error.
    """
    active_registry = registry if registry is not None else SecretRegistry()
    path = Path(xml_path)
    try:
        if not path.is_file():
            raise ReportError(f"report file is missing: {path}")
        size = path.stat().st_size
    except OSError:
        raise ReportError(f"report file is missing: {path}") from None
    if size > INTEGRATION_REPORT_MAX_BYTES:
        raise ReportError(
            f"report file exceeds the {INTEGRATION_REPORT_MAX_BYTES}-byte limit"
        )
    try:
        data = path.read_bytes()
    except OSError:
        raise ReportError(f"report file is unreadable: {path}") from None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise ReportError("report XML is malformed") from None
    lowered = text.lower()
    if "<!doctype" in lowered or "<!entity" in lowered:
        raise ReportError("report XML is malformed")
    try:
        root = ElementTree.fromstring(text)
    except ElementTree.ParseError:
        raise ReportError("report XML is malformed") from None

    root_name = _report_local_name(root.tag)
    if root_name not in {"testsuites", "testsuite"}:
        raise ReportError("report XML is malformed")

    if root_name == "testsuite":
        suites = [root]
    else:
        suites = [
            element
            for element in root.iter()
            if _report_local_name(element.tag) == "testsuite"
        ]
    if not suites:
        raise ReportError("report XML is malformed")

    for suite in suites:
        if _report_count(suite, "errors"):
            raise ReportError("report records suite errors")

    suite_failures = sum(_report_count(suite, "failures") for suite in suites)
    suite_skips = sum(_report_count(suite, "skipped") for suite in suites)

    cases = [
        element
        for element in root.iter()
        if _report_local_name(element.tag) == "testcase"
    ]
    if not cases:
        raise ReportError("report contains no executed test cases")
    if len(cases) > INTEGRATION_REPORT_MAX_CASES:
        raise ReportError("report contains too many test cases")

    expected = {
        method: lane
        for lane, methods in INTEGRATION_REPORT_METHODS.items()
        for method in methods
    }
    integration_classname = f"{INTEGRATION_REPORT_MODULE}.{INTEGRATION_REPORT_SUITE}"
    integration_prefix = f"{INTEGRATION_REPORT_MODULE}."
    seen: dict[str, int] = {}
    failed_labels: list[str] = []
    skipped_labels: list[str] = []
    unknown_labels: list[str] = []

    for case in cases:
        classname = case.get("classname")
        name = case.get("name")
        if not classname or not name:
            raise ReportError("report XML is malformed")
        label = _report_safe_label(classname, name)

        skipped = any(
            _report_local_name(child.tag) == "skipped" for child in case
        )
        failed = any(
            _report_local_name(child.tag) in {"failure", "error"} for child in case
        )

        if skipped:
            skipped_labels.append(label)
        if failed:
            excerpt = _report_failure_excerpt(case, active_registry)
            if excerpt and _report_contains_secret(excerpt, active_registry):
                raise ReportError("report contains unredacted secret material")
            failed_labels.append(f"{label}: {excerpt}" if excerpt else label)

        if classname == integration_classname:
            normalized = _report_case_name(name)
            if normalized not in expected:
                unknown_labels.append(label)
                continue
            seen[normalized] = seen.get(normalized, 0) + 1
        elif classname.startswith(integration_prefix):
            unknown_labels.append(label)

    if failed_labels:
        raise ReportError("report contains failed cases: " + _report_join(failed_labels))
    if suite_failures:
        raise ReportError("report contains failed cases")
    if skipped_labels:
        raise ReportError(
            "report contains skipped cases: " + _report_join(skipped_labels)
        )
    if suite_skips:
        raise ReportError("report contains skipped cases")
    if unknown_labels:
        raise ReportError(
            "integration report has unknown cases: " + _report_join(unknown_labels)
        )

    duplicates = sorted(name for name, count in seen.items() if count > 1)
    if duplicates:
        raise ReportError(
            "integration report has duplicate cases: " + ", ".join(duplicates)
        )

    missing: list[str] = []
    for lane, methods in INTEGRATION_REPORT_METHODS.items():
        missing_methods = [method for method in methods if seen.get(method, 0) == 0]
        if missing_methods:
            missing.append(f"missing {lane} cases: {', '.join(missing_methods)}")
    if missing:
        raise ReportError("integration report is incomplete: " + "; ".join(missing))

    return {
        "status": "passed",
        "tests": sum(len(methods) for methods in INTEGRATION_REPORT_METHODS.values()),
        "lanes": {
            lane: len(methods) for lane, methods in INTEGRATION_REPORT_METHODS.items()
        },
        "methods": {
            lane: list(methods) for lane, methods in INTEGRATION_REPORT_METHODS.items()
        },
    }


def _cli_validate_report(arguments: argparse.Namespace) -> int:
    registry = _load_report_registry(arguments.secrets)
    result = validate_report(arguments.xml, registry=registry)
    print(
        format_phase(
            "report",
            "ok",
            tests=result["tests"],
            v5=result["lanes"]["v5"],
            v6=result["lanes"]["v6"],
            path=arguments.xml,
        )
    )
    return 0


def _cli_prepare(arguments: argparse.Namespace) -> int:
    try:
        prepare_state(arguments.state, worktree=repo_root(), phase="prepare")
    except HarnessError as error:
        # prepare_state already emitted the failing phase line and closed its sinks.
        return error.exit_code
    return 0


def _cli_test(arguments: argparse.Namespace) -> int:
    started = time.monotonic()
    print(
        format_phase(
            "scenario-execution",
            "unavailable",
            elapsed=time.monotonic() - started,
            artifacts=arguments.artifacts,
            detail=(
                "Task 1 provides the safety foundation only; Task 4 fills the opted-in "
                "scenario wrappers and Task 5 adds automatic run orchestration. "
                "No run was allocated."
            ),
        )
    )
    return 1


def _cli_down(arguments: argparse.Namespace) -> int:
    try:
        teardown_project(arguments.project, worktree=repo_root())
    except HarnessError as error:
        # teardown_project already emitted the failing phase line.
        return error.exit_code
    return 0


def _cli_run(arguments: argparse.Namespace) -> int:
    command = list(arguments.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print(
            format_phase("command", "failed", detail="no command was supplied after --"),
            file=sys.stderr,
        )
        return 1
    try:
        return run_supervised(
            command,
            timeout=arguments.timeout,
            log_path=arguments.log,
        )
    except ValueError as error:
        print(format_phase("command", "failed", detail=str(error)), file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="harness.py",
        description="Lifecycle and supervision owner for Holeberry integration tests.",
    )
    subcommands = parser.add_subparsers(dest="subcommand", required=True)

    up_parser = subcommands.add_parser("up", help="start the manual integration environment")
    up_parser.add_argument("--project", help="recorded manual project name")
    up_parser.add_argument("--v5-port", type=int, default=DEFAULT_MANUAL_PORTS["v5"])
    up_parser.add_argument("--v6-port", type=int, default=DEFAULT_MANUAL_PORTS["v6"])
    up_parser.set_defaults(handler=_cli_up)

    prepare_parser = subcommands.add_parser(
        "prepare", help="verify an owned project and write fixture metadata"
    )
    prepare_parser.add_argument("--state", required=True, help="recorded state.json path")
    prepare_parser.set_defaults(handler=_cli_prepare)

    test_parser = subcommands.add_parser("test", help="run the automatic integration suite")
    test_parser.add_argument("--artifacts", help="new directory for run artifacts")
    test_parser.set_defaults(handler=_cli_test)

    report_parser = subcommands.add_parser(
        "validate-report", help="validate one structured integration report"
    )
    report_parser.add_argument("--xml", required=True, help="xUnit report path")
    report_parser.add_argument(
        "--secrets", help="private JSON secret mapping used for report redaction"
    )
    report_parser.set_defaults(handler=_cli_validate_report)

    down_parser = subcommands.add_parser("down", help="remove one owned integration project")
    down_parser.add_argument("--project", help="recorded project name")
    down_parser.set_defaults(handler=_cli_down)

    run_parser = subcommands.add_parser("run", help="supervise one command with sanitized output")
    run_parser.add_argument("--timeout", type=float, required=True)
    run_parser.add_argument("--log", required=True)
    run_parser.add_argument("command", nargs=argparse.REMAINDER)
    run_parser.set_defaults(handler=_cli_run)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        return int(arguments.handler(arguments))
    except HarnessError as error:
        print(
            format_phase(error.phase, "failed", detail=str(error)),
            file=sys.stderr,
        )
        return error.exit_code
    except ValueError as error:
        print(format_phase("options", "failed", detail=str(error)), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
