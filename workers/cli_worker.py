"""Tier-2 CLI worker with whitelist validation and durable audit logging.

The worker is intentionally self-contained so it can live in ``dev-workspace``
without depending on the orchestrator package being importable. Callers
register named command rules and execute only those rules. Every invocation:

- is classified as Tier 2 / guarded
- requires an explicit ``dry_run`` flag in the payload
- captures stdout/stderr with truncation
- enforces a timeout
- appends a JSONL audit record on success, dry-run preview, timeout, or error

Example:

    from pathlib import Path
    from workers.cli_worker import CliWorker, CommandRule

    worker = CliWorker(
        rules={
            "workspace.health": CommandRule(
                argv_prefix=("bash", "/home/moses/projects/dev-workspace/scripts/dws-health.sh"),
                timeout_seconds=10,
            ),
        },
    )
    preview = worker.execute("workspace.health", {"dry_run": True})
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import IntEnum
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

try:  # pragma: no cover - optional dependency path
    from wrkflo_orchestrator.gateway import Tier as _Tier
except Exception:  # pragma: no cover - fallback when sibling package is absent
    class _Tier(IntEnum):
        READ = 0
        SAFE_DEV = 1
        GUARDED = 2


Tier = _Tier
CommandRunner = Callable[..., subprocess.CompletedProcess[str]]

DEFAULT_AUDIT_LOG = Path.home() / ".local" / "state" / "dev-workspace" / "cli-worker-audit.jsonl"


@dataclass(frozen=True)
class CommandRule:
    """Whitelist entry for one named command.

    ``argv_prefix`` is the immutable start of the command. Callers can append
    optional ``args`` only when ``allow_extra_args`` is true.
    """

    argv_prefix: tuple[str, ...]
    description: str = ""
    timeout_seconds: int = 30
    allow_extra_args: bool = True
    cwd: Path | str | None = None
    allowed_roots: tuple[Path | str, ...] = ()
    env_allowlist: tuple[str, ...] = ()


class CliWorkerError(RuntimeError):
    """Raised when a CLI worker request is invalid or execution fails."""

    def __init__(self, message: str, *, command: Sequence[str] | None = None) -> None:
        super().__init__(message)
        self.command = list(command or ())


@dataclass
class CliWorker:
    """Execute only whitelisted shell commands with audit logging."""

    rules: Mapping[str, CommandRule] = field(default_factory=dict)
    audit_log_path: Path | str = DEFAULT_AUDIT_LOG
    command_runner: CommandRunner | None = None
    capture_limit: int = 8192
    tier: Tier = Tier.GUARDED

    def __post_init__(self) -> None:
        self.audit_log_path = Path(self.audit_log_path).expanduser().resolve()
        self.command_runner = self.command_runner or _run_command
        self._rules: dict[str, CommandRule] = {}
        for name, rule in self.rules.items():
            self.register(name, rule)

    def register(self, tool: str, rule: CommandRule) -> None:
        """Register one named command rule."""

        if not tool:
            raise ValueError("tool name is required")
        if tool in self._rules:
            raise ValueError(f"tool already registered: {tool}")
        if not rule.argv_prefix:
            raise ValueError(f"{tool} must define argv_prefix")
        self._rules[tool] = _normalize_rule(rule)

    def tools(self) -> dict[str, dict[str, Any]]:
        """Return the whitelist for inspection."""

        return {
            name: {
                "tier": int(self.tier),
                "argv_prefix": list(rule.argv_prefix),
                "description": rule.description,
                "timeout_seconds": rule.timeout_seconds,
                "allow_extra_args": rule.allow_extra_args,
                "cwd": str(rule.cwd) if rule.cwd else "",
                "allowed_roots": [str(path) for path in rule.allowed_roots],
                "env_allowlist": list(rule.env_allowlist),
            }
            for name, rule in self._rules.items()
        }

    def execute(
        self,
        tool: str,
        payload: Mapping[str, Any],
        *,
        requester: str = "cli-worker",
    ) -> dict[str, Any]:
        """Execute one whitelisted command.

        Required payload:
        - ``dry_run``: bool-like value; omitting it is an error

        Optional payload:
        - ``args``: trailing argv entries appended after the whitelisted prefix
        - ``cwd``: override working directory, optionally constrained by rule roots
        - ``env``: environment overrides limited to ``env_allowlist``
        - ``timeout_seconds``: lower or equal to the rule timeout
        """

        if tool not in self._rules:
            raise CliWorkerError(f"unsupported cli tool: {tool}")
        if "dry_run" not in payload:
            raise CliWorkerError("dry_run is required for Tier-2 CLI execution")

        rule = self._rules[tool]
        prepared = self._prepare(tool, rule, payload)
        audit_base = {
            "tool": tool,
            "tier": int(self.tier),
            "requester": requester,
            "dry_run": prepared["dry_run"],
            "command": prepared["argv"],
            "command_text": shlex.join(prepared["argv"]),
            "cwd": str(prepared["cwd"]) if prepared["cwd"] else "",
            "timeout_seconds": prepared["timeout_seconds"],
            "env_keys": prepared["env_keys"],
        }

        started = time.monotonic()
        if prepared["dry_run"]:
            result = {
                **audit_base,
                "exit_code": None,
                "stdout": "",
                "stderr": "",
                "stdout_truncated": False,
                "stderr_truncated": False,
                "duration_ms": 0,
            }
            self._record_audit({**result, "timestamp_utc": _utc_now(), "outcome": "dry_run"})
            return result

        try:
            completed = self.command_runner(
                prepared["argv"],
                cwd=prepared["cwd"],
                env=prepared["env"],
                timeout=prepared["timeout_seconds"],
            )
        except subprocess.TimeoutExpired as exc:
            duration_ms = int((time.monotonic() - started) * 1000)
            stdout, stdout_truncated = _capture_output(exc.stdout, self.capture_limit)
            stderr, stderr_truncated = _capture_output(exc.stderr, self.capture_limit)
            entry = {
                **audit_base,
                "timestamp_utc": _utc_now(),
                "outcome": "timeout",
                "exit_code": None,
                "stdout": stdout,
                "stderr": stderr,
                "stdout_truncated": stdout_truncated,
                "stderr_truncated": stderr_truncated,
                "duration_ms": duration_ms,
                "error": f"timed out after {prepared['timeout_seconds']}s",
            }
            self._record_audit(entry)
            raise CliWorkerError(entry["error"], command=prepared["argv"]) from exc
        except OSError as exc:
            duration_ms = int((time.monotonic() - started) * 1000)
            entry = {
                **audit_base,
                "timestamp_utc": _utc_now(),
                "outcome": "error",
                "exit_code": None,
                "stdout": "",
                "stderr": "",
                "stdout_truncated": False,
                "stderr_truncated": False,
                "duration_ms": duration_ms,
                "error": str(exc),
            }
            self._record_audit(entry)
            raise CliWorkerError(str(exc), command=prepared["argv"]) from exc

        duration_ms = int((time.monotonic() - started) * 1000)
        stdout, stdout_truncated = _capture_output(completed.stdout, self.capture_limit)
        stderr, stderr_truncated = _capture_output(completed.stderr, self.capture_limit)
        result = {
            **audit_base,
            "exit_code": completed.returncode,
            "stdout": stdout,
            "stderr": stderr,
            "stdout_truncated": stdout_truncated,
            "stderr_truncated": stderr_truncated,
            "duration_ms": duration_ms,
        }

        if completed.returncode != 0:
            entry = {
                **result,
                "timestamp_utc": _utc_now(),
                "outcome": "error",
                "error": _error_text(completed, fallback="command failed"),
            }
            self._record_audit(entry)
            raise CliWorkerError(entry["error"], command=prepared["argv"])

        self._record_audit({**result, "timestamp_utc": _utc_now(), "outcome": "ok"})
        return result

    def _prepare(
        self,
        tool: str,
        rule: CommandRule,
        payload: Mapping[str, Any],
    ) -> dict[str, Any]:
        dry_run = _coerce_bool(payload["dry_run"], "dry_run")
        args = _coerce_args(payload.get("args", ()))
        if args and not rule.allow_extra_args:
            raise CliWorkerError(f"{tool} does not allow extra args")
        argv = [*rule.argv_prefix, *args]
        cwd = _resolve_cwd(rule, payload.get("cwd"))
        env = _prepare_env(rule, payload.get("env"))
        timeout_seconds = _resolve_timeout(rule, payload.get("timeout_seconds"))
        return {
            "dry_run": dry_run,
            "argv": argv,
            "cwd": cwd,
            "env": env,
            "env_keys": sorted(env.keys()),
            "timeout_seconds": timeout_seconds,
        }

    def _record_audit(self, entry: Mapping[str, Any]) -> None:
        self.audit_log_path.parent.mkdir(parents=True, exist_ok=True)
        with self.audit_log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(dict(entry), sort_keys=True))
            handle.write("\n")


def default_dev_workspace_rules(root: Path | str | None = None) -> dict[str, CommandRule]:
    """Return a small default whitelist for common dev-workspace scripts."""

    workspace = Path(root or Path.home() / "projects" / "dev-workspace").expanduser().resolve()
    scripts = workspace / "scripts"
    return {
        "workspace.health_check": CommandRule(
            argv_prefix=("bash", str(scripts / "dws-health-check.sh")),
            timeout_seconds=15,
            cwd=workspace,
        ),
        "workspace.cleanup": CommandRule(
            argv_prefix=("bash", str(scripts / "dws-cleanup.sh")),
            timeout_seconds=60,
            cwd=workspace,
            allow_extra_args=True,
        ),
        "workspace.sync_all": CommandRule(
            argv_prefix=("bash", str(scripts / "dws-sync-all.sh")),
            timeout_seconds=300,
            cwd=workspace,
            allow_extra_args=True,
        ),
        "workspace.doctor": CommandRule(
            argv_prefix=("bash", str(workspace / "bin" / "dws-doctor.sh")),
            timeout_seconds=30,
            cwd=workspace,
        ),
    }


def _normalize_rule(rule: CommandRule) -> CommandRule:
    cwd = _normalize_path(rule.cwd) if rule.cwd else None
    allowed_roots = tuple(_normalize_path(path) for path in rule.allowed_roots)
    return CommandRule(
        argv_prefix=tuple(str(part) for part in rule.argv_prefix),
        description=rule.description,
        timeout_seconds=_coerce_positive_int(rule.timeout_seconds, "timeout_seconds"),
        allow_extra_args=bool(rule.allow_extra_args),
        cwd=cwd,
        allowed_roots=allowed_roots,
        env_allowlist=tuple(sorted({str(name) for name in rule.env_allowlist})),
    )


def _coerce_args(raw: Any) -> list[str]:
    if raw in (None, ""):
        return []
    if isinstance(raw, (list, tuple)):
        return [str(item) for item in raw]
    raise CliWorkerError("args must be a list or tuple of command arguments")


def _coerce_bool(raw: Any, field_name: str) -> bool:
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, str):
        value = raw.strip().lower()
        if value in {"1", "true", "yes", "on"}:
            return True
        if value in {"0", "false", "no", "off"}:
            return False
    raise CliWorkerError(f"{field_name} must be a boolean value")


def _coerce_positive_int(raw: Any, field_name: str) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise CliWorkerError(f"{field_name} must be an integer") from exc
    if value <= 0:
        raise CliWorkerError(f"{field_name} must be > 0")
    return value


def _resolve_timeout(rule: CommandRule, raw: Any) -> int:
    if raw in (None, ""):
        return rule.timeout_seconds
    requested = _coerce_positive_int(raw, "timeout_seconds")
    if requested > rule.timeout_seconds:
        raise CliWorkerError(
            f"timeout_seconds exceeds rule limit ({requested}s > {rule.timeout_seconds}s)"
        )
    return requested


def _resolve_cwd(rule: CommandRule, raw: Any) -> Path | None:
    if raw in (None, ""):
        return rule.cwd
    path = _normalize_path(str(raw))
    allowed_roots = rule.allowed_roots
    if not allowed_roots and rule.cwd:
        allowed_roots = (rule.cwd,)
    if allowed_roots and not any(_matches_allowed_root(path, root) for root in allowed_roots):
        raise CliWorkerError(f"cwd escapes allowed roots: {path}")
    return path


def _prepare_env(rule: CommandRule, raw: Any) -> dict[str, str]:
    if raw in (None, ""):
        return {}
    if not isinstance(raw, Mapping):
        raise CliWorkerError("env must be a mapping of environment overrides")
    env: dict[str, str] = {}
    for key, value in raw.items():
        name = str(key)
        if name not in rule.env_allowlist:
            raise CliWorkerError(f"env override not allowed: {name}")
        env[name] = str(value)
    return env


def _capture_output(raw: Any, limit: int) -> tuple[str, bool]:
    text = _coerce_text(raw)
    if len(text) <= limit:
        return text, False
    return text[:limit], True


def _coerce_text(raw: Any) -> str:
    if raw in (None, ""):
        return ""
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace")
    return str(raw)


def _error_text(result: subprocess.CompletedProcess[str], *, fallback: str) -> str:
    return _coerce_text(result.stderr).strip() or _coerce_text(result.stdout).strip() or fallback


def _is_relative_to(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _matches_allowed_root(path: Path, root: Path) -> bool:
    path_candidates = {path.absolute()}
    root_candidates = {root.absolute()}
    try:
        path_candidates.add(path.resolve())
    except OSError:  # pragma: no cover - defensive
        pass
    try:
        root_candidates.add(root.resolve())
    except OSError:  # pragma: no cover - defensive
        pass
    return any(_is_relative_to(candidate, base) for candidate in path_candidates for base in root_candidates)


def _normalize_path(raw: Path | str) -> Path:
    path = Path(raw).expanduser()
    return path if path.is_absolute() else path.resolve()


def _run_command(
    argv: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update({str(key): str(value) for key, value in env.items()})
    return subprocess.run(
        list(argv),
        cwd=str(cwd) if cwd else None,
        env=merged_env,
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
    )


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


__all__ = [
    "CliWorker",
    "CliWorkerError",
    "CommandRule",
    "DEFAULT_AUDIT_LOG",
    "Tier",
    "default_dev_workspace_rules",
]
