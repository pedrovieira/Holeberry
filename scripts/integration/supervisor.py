"""Redaction and bounded subprocess supervision for the integration harness.

One process supervisor owns every child: streaming commands and private Docker
capture both use the same process-group engine. Output sinks deliver through
bounded queues so a blocked console or log can never stop deadline handling or
child cleanup.
"""

from __future__ import annotations

import html
import json
import math
import os
import re
import selectors
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Callable, Iterable, Mapping
from urllib.parse import quote, quote_plus
from xml.sax.saxutils import escape as xml_escape

MAX_RECORD_BYTES = 64 * 1024
REDACTED = "[REDACTED]"
OMITTED_MARKER = f"[omitted: record exceeded {MAX_RECORD_BYTES} bytes]"
READ_CHUNK_BYTES = 64 * 1024
DRAIN_GRACE_SECONDS = 1.0
POLL_SECONDS = 0.05
SINK_MAX_PENDING_BYTES = 1024 * 1024
SINK_COALESCE_RECORDS = 256
SINK_FLUSH_TIMEOUT = 1.0
MAX_CAPTURE_BYTES = 256 * 1024
CAPTURE_TRUNCATED_MARKER = f"[truncated: capture exceeded {MAX_CAPTURE_BYTES} bytes]"


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _format_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if text and all(character not in text for character in ' \t\r\n"='):
        return text
    return json.dumps(text)


def format_phase(
    phase: str,
    status: str,
    *,
    elapsed: float | None = None,
    lane: str | None = None,
    **fields: object,
) -> str:
    """Build the harness phase line: UTC timestamp, phase, status, fields, elapsed."""
    parts = [utc_timestamp(), f"phase={phase}", f"status={status}"]
    if lane is not None:
        parts.append(f"lane={lane}")
    for key, value in fields.items():
        if value is None:
            continue
        parts.append(f"{key}={_format_value(value)}")
    if elapsed is not None:
        parts.append(f"elapsed={elapsed:.3f}s")
    return " ".join(parts)


def _quote_variants(value: str) -> Iterable[str]:
    yield quote(value, safe="")
    yield quote(value, safe="/")
    yield quote_plus(value)


def _json_variants(value: str) -> Iterable[str]:
    yield json.dumps(value, ensure_ascii=True)[1:-1]
    yield json.dumps(value, ensure_ascii=False)[1:-1]


def _lowercase_percent_escapes(value: str) -> str:
    return re.sub(
        r"%[0-9A-Fa-f]{2}",
        lambda match: match.group(0).lower(),
        value,
    )


def _xml_variants(value: str) -> Iterable[str]:
    yield xml_escape(value)
    yield html.escape(value, quote=True)


class SecretRegistry:
    """Holds fixture secrets privately and runs the standard encodings through redaction."""

    def __init__(self, secrets: Iterable[str] | Mapping[str, str] | None = None):
        self._values: set[str] = set()
        if isinstance(secrets, Mapping):
            for value in secrets.values():
                self.register(str(value))
        elif secrets is not None:
            for value in secrets:
                self.register(str(value))

    def register(self, value: str) -> None:
        if not value:
            return
        variants = {value}
        quoted = tuple(_quote_variants(value))
        variants.update(quoted)
        variants.update(_lowercase_percent_escapes(variant) for variant in quoted)
        variants.update(_json_variants(value))
        variants.update(_xml_variants(value))
        self._values.update(variant for variant in variants if variant)

    def values_longest_first(self) -> tuple[str, ...]:
        return tuple(sorted(self._values, key=len, reverse=True))

    def sanitize(self, text: str) -> str:
        return sanitize_text(text, self)


_AUTH_HEADER_RE = re.compile(
    r"(?im)(\b(?:proxy-)?authorization\s*:\s*)[^\r\n]+",
)
_COOKIE_HEADER_RE = re.compile(
    r"(?im)(\b(?:set-)?cookie\s*:\s*)[^\r\n]+",
)
_AUTH_FIELD_RE = re.compile(
    r"(?i)(\b(?:password|passwd|pwd|webpassword|token|api[_-]?token|api[_-]?key|apikey|"
    r"secret|sid|session(?:id)?|auth|authorization|access[_-]?token|refresh[_-]?token|"
    r"client[_-]?secret)\b[\"']?)(\s*(?:=|:|%3D)\s*)"
    r"(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|(?!\[REDACTED\])[^\s&;,\"'}\]]+)",
)


def _mask_auth_field(match: re.Match[str]) -> str:
    key, separator, value = match.groups()
    if value.startswith('"') and value.endswith('"'):
        return f'{key}{separator}"{REDACTED}"'
    if value.startswith("'") and value.endswith("'"):
        return f"{key}{separator}'{REDACTED}'"
    return f"{key}{separator}{REDACTED}"


def sanitize_text(text: str, registry: SecretRegistry) -> str:
    """Redact registered secrets and common auth material from one logical record."""
    if not text:
        return text
    for value in registry.values_longest_first():
        if value in text:
            text = text.replace(value, REDACTED)
    text = _AUTH_HEADER_RE.sub(lambda match: match.group(1) + REDACTED, text)
    text = _COOKIE_HEADER_RE.sub(lambda match: match.group(1) + REDACTED, text)
    return _AUTH_FIELD_RE.sub(_mask_auth_field, text)


class _RecordSplitter:
    """Bounds every pending logical record and never emits an unsanitized fragment."""

    def __init__(self, limit: int = MAX_RECORD_BYTES):
        self._limit = limit
        self._buffer = bytearray()
        self._discarding = False

    def feed(self, data: bytes) -> list[str]:
        results: list[str] = []
        start = 0
        while start < len(data):
            if self._discarding:
                newline = data.find(b"\n", start)
                if newline < 0:
                    return results
                self._discarding = False
                start = newline + 1
                continue

            newline = data.find(b"\n", start)
            end = len(data) if newline < 0 else newline + 1
            self._buffer.extend(data[start:end])
            start = end

            if newline >= 0:
                line = bytes(self._buffer)
                self._buffer.clear()
                results.append(self._decode(line))
            elif len(self._buffer) > self._limit:
                self._buffer.clear()
                self._discarding = True
                results.append(OMITTED_MARKER + "\n")
        return results

    def finish(self) -> list[str]:
        if self._discarding:
            self._discarding = False
            self._buffer.clear()
            return []
        if not self._buffer:
            return []
        line = bytes(self._buffer)
        self._buffer.clear()
        return [self._decode(line)]

    def _decode(self, line: bytes) -> str:
        if len(line) > self._limit:
            return OMITTED_MARKER + "\n"
        return line.decode("utf-8", errors="replace")


class OutputSink:
    """Delivers sanitized records through a bounded buffer and a writer thread.

    Writes never block the deadline loop. Bursts are coalesced into ordered
    chunks, so healthy writers are not mistaken for stalled ones. A sink that
    exceeds the pending-byte bound, fails, or stalls past a drain deadline is
    marked failed and stops accepting records. Closeable streams are closed by
    their writer thread, never synchronously from the supervising thread.
    """

    def __init__(
        self,
        name: str,
        stream: IO[str] | None = None,
        error: str | None = None,
        *,
        closeable: bool = False,
    ):
        self.name = name
        self._stream = stream
        self._closeable = closeable
        self._error = error
        self._condition = threading.Condition()
        self._pending: list[str] = []
        self._pending_bytes = 0
        self._active = False
        self._stopped = False
        self._closed = False
        self._thread: threading.Thread | None = None
        if stream is not None and error is None:
            self._thread = threading.Thread(
                target=self._write_loop,
                name=f"harness-{name}-sink",
                daemon=True,
            )
            self._thread.start()

    @classmethod
    def open_log(cls, path: Path) -> "OutputSink":
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NONBLOCK
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = -1
        try:
            descriptor = os.open(path, flags, 0o600)
            os.fchmod(descriptor, 0o600)
            stream = os.fdopen(descriptor, "w", encoding="utf-8")
        except (OSError, ValueError) as error:
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            return cls("log", error=f"{type(error).__name__}: {error}")
        return cls("log", stream=stream, closeable=True)

    @property
    def error(self) -> str | None:
        with self._condition:
            return self._error

    def write(self, text: str) -> bool:
        with self._condition:
            if self._error is not None or self._closed:
                return False
            size = len(text.encode("utf-8", errors="replace"))
            if self._pending_bytes + size > SINK_MAX_PENDING_BYTES:
                self._error = (
                    f"output sink pending buffer exceeded {SINK_MAX_PENDING_BYTES} bytes; "
                    "sink stalled"
                )
                self._pending.clear()
                self._pending_bytes = 0
                self._condition.notify_all()
                return False
            self._pending.append(text)
            self._pending_bytes += size
            if len(self._pending) >= SINK_COALESCE_RECORDS:
                self._pending = ["".join(self._pending)]
            self._condition.notify()
            return True

    def drain(self, timeout: float) -> bool:
        """Wait at most ``timeout`` for pending output to reach the stream."""
        deadline = time.monotonic() + max(0.0, timeout)
        with self._condition:
            while True:
                if self._error is not None:
                    return False
                if not self._pending and not self._active:
                    return True
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._error = f"output sink stalled beyond {timeout:.3f}s"
                    self._pending.clear()
                    self._pending_bytes = 0
                    self._condition.notify_all()
                    return False
                self._condition.wait(remaining)

    def close(self, timeout: float = SINK_FLUSH_TIMEOUT) -> None:
        deadline = time.monotonic() + max(0.0, timeout)
        self.drain(max(0.0, deadline - time.monotonic()))
        with self._condition:
            self._stopped = True
            self._closed = True
            self._condition.notify_all()
        thread = self._thread
        if thread is not None:
            thread.join(max(0.0, deadline - time.monotonic()))
            if thread.is_alive():
                with self._condition:
                    if self._error is None:
                        self._error = "output sink writer did not stop"
        # A closeable stream is owned and closed by its writer thread. Closing a
        # stalled buffered stream here could block on the writer's lock.

    def _write_loop(self) -> None:
        try:
            while True:
                with self._condition:
                    while not self._pending and not self._stopped and self._error is None:
                        self._condition.wait()
                    if self._error is not None:
                        return
                    if not self._pending:
                        if self._stopped:
                            return
                        continue
                    text = "".join(self._pending)
                    self._pending.clear()
                    self._pending_bytes = 0
                    self._active = True
                try:
                    assert self._stream is not None
                    self._stream.write(text)
                    self._stream.flush()
                except BaseException as error:
                    with self._condition:
                        self._error = f"{type(error).__name__}: {error}"
                        self._active = False
                        self._pending.clear()
                        self._pending_bytes = 0
                        self._condition.notify_all()
                    return
                with self._condition:
                    self._active = False
                    self._condition.notify_all()
        finally:
            if self._closeable and self._stream is not None:
                try:
                    self._stream.close()
                except Exception:
                    pass
                self._stream = None


def _send_group_signal(process_group: int, signum: int) -> None:
    try:
        os.killpg(process_group, signum)
    except (ProcessLookupError, PermissionError):
        pass


def _validate_deadline(timeout: float, termination_grace: float) -> None:
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout must be a finite positive number")
    if not math.isfinite(termination_grace) or termination_grace < 0:
        raise ValueError("termination_grace must be a finite non-negative number")


@dataclass(frozen=True)
class ProcessOutcome:
    returncode: int
    child_status: int | None
    timed_out: bool
    interrupted_signal: int | None
    elapsed: float


@dataclass(frozen=True)
class CapturedResult:
    returncode: int
    stdout: str
    stderr: str
    stdout_truncated: bool
    stderr_truncated: bool
    timed_out: bool
    interrupted_signal: int | None
    elapsed: float


def _supervise_process(
    command: list[str],
    timeout: float,
    termination_grace: float,
    *,
    on_stdout: Callable[[bytes], None],
    on_stderr: Callable[[bytes], None],
    progress: Callable[[float, int], None] | None = None,
    progress_interval: float | None = None,
    env: Mapping[str, str] | None = None,
) -> ProcessOutcome:
    """Run one child process group and stream bounded reads to callbacks."""
    if not command:
        raise ValueError("command must not be empty")
    _validate_deadline(timeout, termination_grace)

    started = time.monotonic()
    deadline = started + timeout
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        close_fds=True,
        env=dict(env) if env is not None else None,
    )
    assert process.stdout is not None
    assert process.stderr is not None
    for stream in (process.stdout, process.stderr):
        os.set_blocking(stream.fileno(), False)

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")

    interrupted: int | None = None
    previous_handlers: dict[int, object] = {}

    def handle_signal(signum: int, _frame: object) -> None:
        nonlocal interrupted
        if interrupted is None:
            interrupted = signum

    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGINT, signal.SIGTERM):
            try:
                previous_handlers[signum] = signal.signal(signum, handle_signal)
            except (ValueError, OSError):
                pass

    timed_out = False
    term_sent_at: float | None = None
    interrupted_running = False
    kill_sent = False
    child_exited_at: float | None = None
    open_streams = 2
    last_progress = started

    try:
        try:
            while True:
                now = time.monotonic()

                if (
                    interrupted is None
                    and not timed_out
                    and term_sent_at is None
                    and now >= deadline
                    and process.poll() is None
                ):
                    timed_out = True
                    term_sent_at = now
                    _send_group_signal(process.pid, signal.SIGTERM)

                if interrupted is not None and term_sent_at is None and process.poll() is None:
                    term_sent_at = now
                    interrupted_running = True
                    _send_group_signal(process.pid, signal.SIGTERM)

                if (
                    term_sent_at is not None
                    and not kill_sent
                    and now >= term_sent_at + termination_grace
                ):
                    _send_group_signal(process.pid, signal.SIGKILL)
                    kill_sent = True

                if process.poll() is not None:
                    if child_exited_at is None:
                        child_exited_at = now
                        if not kill_sent:
                            # Stop descendants that would otherwise keep pipe write ends open.
                            _send_group_signal(process.pid, signal.SIGKILL)
                            kill_sent = True
                    elif now - child_exited_at > DRAIN_GRACE_SECONDS:
                        break

                if (
                    progress is not None
                    and progress_interval is not None
                    and progress_interval > 0
                    and process.poll() is None
                    and now - last_progress >= progress_interval
                ):
                    last_progress = now
                    progress(now - started, process.pid)

                if open_streams == 0:
                    if process.poll() is not None:
                        break
                    time.sleep(POLL_SECONDS)
                    continue

                for key, _mask in selector.select(timeout=POLL_SECONDS):
                    try:
                        data = os.read(key.fd, READ_CHUNK_BYTES)
                    except BlockingIOError:
                        continue
                    except OSError:
                        data = b""
                    if not data:
                        try:
                            selector.unregister(key.fileobj)
                        except KeyError:
                            pass
                        open_streams -= 1
                        continue
                    if key.data == "stdout":
                        on_stdout(data)
                    else:
                        on_stderr(data)
        except BaseException:
            _send_group_signal(process.pid, signal.SIGKILL)
            try:
                process.wait(timeout=5)
            except Exception:
                pass
            raise
        finally:
            for signum, handler in previous_handlers.items():
                try:
                    signal.signal(signum, handler)  # type: ignore[arg-type]
                except (ValueError, OSError):
                    pass
            selector.close()

        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _send_group_signal(process.pid, signal.SIGKILL)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
    finally:
        process.stdout.close()
        process.stderr.close()

    child_status = process.returncode
    if timed_out:
        returncode = 124
    elif interrupted_running and interrupted is not None:
        returncode = 128 + interrupted
    elif child_status is not None and child_status < 0:
        returncode = 128 + (-child_status)
    elif child_status is not None:
        returncode = child_status
    else:
        returncode = 1
    return ProcessOutcome(
        returncode=returncode,
        child_status=child_status,
        timed_out=timed_out,
        interrupted_signal=interrupted if interrupted_running else None,
        elapsed=time.monotonic() - started,
    )


def run_captured(
    command: list[str],
    timeout: float,
    *,
    termination_grace: float = 1.0,
    stdout_limit: int = MAX_CAPTURE_BYTES,
    stderr_limit: int = MAX_CAPTURE_BYTES,
    env: Mapping[str, str] | None = None,
) -> CapturedResult:
    """Run a command with bounded private capture, owned-group termination and interruption."""
    stdout_buffer = bytearray()
    stderr_buffer = bytearray()
    stdout_truncated = False
    stderr_truncated = False

    def capture(buffer: bytearray, data: bytes, limit: int) -> bool:
        remaining = max(0, limit - len(buffer))
        if remaining:
            buffer.extend(data[:remaining])
        return len(data) > remaining

    def on_stdout(data: bytes) -> None:
        nonlocal stdout_truncated
        if capture(stdout_buffer, data, stdout_limit):
            stdout_truncated = True

    def on_stderr(data: bytes) -> None:
        nonlocal stderr_truncated
        if capture(stderr_buffer, data, stderr_limit):
            stderr_truncated = True

    outcome = _supervise_process(
        command,
        timeout,
        termination_grace,
        on_stdout=on_stdout,
        on_stderr=on_stderr,
        env=env,
    )
    return CapturedResult(
        returncode=outcome.returncode,
        stdout=stdout_buffer.decode("utf-8", errors="replace"),
        stderr=stderr_buffer.decode("utf-8", errors="replace"),
        stdout_truncated=stdout_truncated,
        stderr_truncated=stderr_truncated,
        timed_out=outcome.timed_out,
        interrupted_signal=outcome.interrupted_signal,
        elapsed=outcome.elapsed,
    )


def _drain_sinks(sinks: tuple[OutputSink, ...], timeout: float) -> None:
    deadline = time.monotonic() + max(0.0, timeout)
    for sink in sinks:
        sink.drain(max(0.0, deadline - time.monotonic()))


def run_supervised(
    command: list[str],
    timeout: float,
    log_path: str | Path,
    *,
    secrets: SecretRegistry | Iterable[str] | Mapping[str, str] | None = None,
    stdout: IO[str] | None = None,
    stderr: IO[str] | None = None,
    progress_interval: float | None = 30.0,
    termination_grace: float = 1.0,
    sink_flush_timeout: float = SINK_FLUSH_TIMEOUT,
    env: Mapping[str, str] | None = None,
) -> int:
    """Run one command in its own process group and return its exit status.

    Child status wins over sink errors. A deadline returns 124 and an
    interruption returns the conventional 128+signal status when no earlier
    child failure exists. Sink failures alone return 1, and the final phase line
    reflects the eventual return status.
    """
    _validate_deadline(timeout, termination_grace)
    if sink_flush_timeout < 0 or not math.isfinite(sink_flush_timeout):
        raise ValueError("sink_flush_timeout must be finite and non-negative")

    registry = secrets if isinstance(secrets, SecretRegistry) else SecretRegistry(secrets)
    stdout_sink = OutputSink("stdout", stdout if stdout is not None else sys.stdout)
    stderr_sink = OutputSink("stderr", stderr if stderr is not None else sys.stderr)
    log_sink = OutputSink.open_log(Path(log_path))
    sinks = (stdout_sink, stderr_sink, log_sink)
    sink_errors: list[tuple[str, str]] = []
    reported_sinks: set[str] = set()

    def report_failures() -> None:
        for sink in sinks:
            detail = sink.error
            if detail is None or sink.name in reported_sinks:
                continue
            reported_sinks.add(sink.name)
            safe_detail = registry.sanitize(detail)
            sink_errors.append((sink.name, safe_detail))
            line = format_phase(
                "output", "failed", sink=sink.name, detail=safe_detail
            ) + "\n"
            for target in sinks:
                if target.name != sink.name:
                    target.write(line)

    def emit(stream_name: str, text: str) -> None:
        sanitized = registry.sanitize(text)
        target = stdout_sink if stream_name == "stdout" else stderr_sink
        for sink in (target, log_sink):
            sink.write(sanitized)

    report_failures()
    if log_sink.error is not None:
        _drain_sinks(sinks, sink_flush_timeout)

    stdout_splitter = _RecordSplitter()
    stderr_splitter = _RecordSplitter()

    def on_stdout(data: bytes) -> None:
        for record in stdout_splitter.feed(data):
            emit("stdout", record)

    def on_stderr(data: bytes) -> None:
        for record in stderr_splitter.feed(data):
            emit("stderr", record)

    def on_progress(elapsed: float, pid: int) -> None:
        line = format_phase("command", "running", elapsed=elapsed, pid=pid) + "\n"
        for sink in (stderr_sink, log_sink):
            sink.write(line)

    try:
        outcome = _supervise_process(
            command,
            timeout,
            termination_grace,
            on_stdout=on_stdout,
            on_stderr=on_stderr,
            progress=on_progress,
            progress_interval=progress_interval,
            env=env,
        )
    except OSError as error:
        detail = registry.sanitize(f"{type(error).__name__}: {error}")
        line = format_phase(
            "command", "failed", elapsed=0.0, detail=detail
        ) + "\n"
        for sink in sinks:
            sink.write(line)
        _drain_sinks(sinks, sink_flush_timeout)
        report_failures()
        for sink in sinks:
            sink.close(sink_flush_timeout)
        return 1
    except BaseException:
        for sink in sinks:
            sink.close(sink_flush_timeout)
        raise

    for record in stdout_splitter.finish():
        emit("stdout", record)
    for record in stderr_splitter.finish():
        emit("stderr", record)

    # Flush existing output first so a stalled sink is detected before the final
    # status line is written.
    _drain_sinks(sinks, sink_flush_timeout)
    report_failures()

    status = outcome.returncode
    if status == 0 and sink_errors:
        status = 1

    final_line = format_phase(
        "command",
        "ok" if status == 0 else "failed",
        elapsed=outcome.elapsed,
        exit=status,
    ) + "\n"
    for sink in (stderr_sink, log_sink):
        sink.write(final_line)
    _drain_sinks(sinks, sink_flush_timeout)
    report_failures()

    if status == 0 and sink_errors:
        status = 1
        correction = format_phase(
            "command",
            "failed",
            elapsed=outcome.elapsed,
            exit=status,
            detail="output sink failure changed the result",
        ) + "\n"
        for sink in (stderr_sink, log_sink):
            sink.write(correction)
        _drain_sinks(sinks, sink_flush_timeout)
        report_failures()

    for sink in sinks:
        sink.close(sink_flush_timeout)
    report_failures()
    if status == 0 and sink_errors:
        status = 1
    return status
