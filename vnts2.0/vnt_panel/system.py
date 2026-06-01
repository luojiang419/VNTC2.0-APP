from __future__ import annotations

import subprocess
from dataclasses import dataclass
from typing import Any


@dataclass(slots=True)
class CommandResult:
    stdout: str
    stderr: str
    returncode: int


class ServiceManager:
    def __init__(self, service_name: str) -> None:
        self.service_name = service_name

    def status(self) -> dict[str, Any]:
        show = self._run(
            [
                "systemctl",
                "show",
                self.service_name,
                "--property",
                ",".join(
                    [
                        "Id",
                        "Description",
                        "LoadState",
                        "ActiveState",
                        "SubState",
                        "UnitFileState",
                        "ExecMainPID",
                        "ExecMainStatus",
                        "ExecMainCode",
                        "ActiveEnterTimestamp",
                        "FragmentPath",
                    ]
                ),
            ]
        )
        details = self._parse_systemctl_show(show.stdout)
        pid = int(details.get("ExecMainPID", "0") or "0")
        process = self._process_stats(pid)
        return {
            "service_name": self.service_name,
            "description": details.get("Description", ""),
            "load_state": details.get("LoadState", ""),
            "active_state": details.get("ActiveState", ""),
            "sub_state": details.get("SubState", ""),
            "unit_file_state": details.get("UnitFileState", ""),
            "pid": pid,
            "main_code": details.get("ExecMainCode", ""),
            "main_status": details.get("ExecMainStatus", ""),
            "active_since": details.get("ActiveEnterTimestamp", ""),
            "fragment_path": details.get("FragmentPath", ""),
            "is_active": details.get("ActiveState", "") == "active",
            "process": process,
        }

    def control(self, action: str) -> dict[str, Any]:
        if action not in {"start", "stop", "restart"}:
            raise ValueError("不支持的服务操作。")
        self._run(["systemctl", action, self.service_name])
        return self.status()

    def logs(self, lines: int = 200) -> dict[str, Any]:
        safe_lines = max(20, min(lines, 500))
        result = self._run(
            [
                "journalctl",
                "-u",
                self.service_name,
                "-n",
                str(safe_lines),
                "--no-pager",
                "-o",
                "short-iso",
            ],
            check=False,
        )
        merged = result.stdout or result.stderr
        entries = [line.rstrip() for line in merged.splitlines() if line.strip()]
        return {"lines": entries, "requested": safe_lines}

    def stream_logs_process(self, lines: int = 80) -> subprocess.Popen[str]:
        safe_lines = max(20, min(lines, 300))
        return subprocess.Popen(
            [
                "journalctl",
                "-u",
                self.service_name,
                "-n",
                str(safe_lines),
                "-f",
                "--no-pager",
                "-o",
                "short-iso",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )

    def _process_stats(self, pid: int) -> dict[str, Any]:
        if pid <= 0:
            return {}
        result = self._run(
            [
                "ps",
                "-p",
                str(pid),
                "-o",
                "%cpu=",
                "-o",
                "%mem=",
                "-o",
                "etime=",
                "-o",
                "command=",
            ],
            check=False,
        )
        line = result.stdout.strip()
        if not line:
            return {}
        cpu, memory, elapsed, command = line.split(None, 3)
        return {
            "cpu_percent": cpu,
            "memory_percent": memory,
            "elapsed": elapsed,
            "command": command,
        }

    @staticmethod
    def _parse_systemctl_show(raw: str) -> dict[str, str]:
        parsed: dict[str, str] = {}
        for line in raw.splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            parsed[key] = value
        return parsed

    @staticmethod
    def _run(command: list[str], check: bool = True) -> CommandResult:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=20,
            check=False,
        )
        if check and completed.returncode != 0:
            message = completed.stderr.strip() or completed.stdout.strip() or "命令执行失败。"
            raise RuntimeError(message)
        return CommandResult(
            stdout=completed.stdout,
            stderr=completed.stderr,
            returncode=completed.returncode,
        )
