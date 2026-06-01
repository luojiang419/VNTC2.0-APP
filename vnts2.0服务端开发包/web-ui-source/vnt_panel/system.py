from __future__ import annotations

import json
import subprocess
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class CommandResult:
    stdout: str
    stderr: str
    returncode: int


class ServiceManager:
    def __init__(
        self,
        service_name: str,
        log_path: Path | None = None,
        platform: str = "linux",
    ) -> None:
        self.service_name = service_name
        self.log_path = Path(log_path) if log_path else None
        self.platform = "windows" if platform == "windows" else "linux"

    def status(self) -> dict[str, Any]:
        if self.platform == "windows":
            return self._windows_status()
        return self._linux_status()

    def control(self, action: str) -> dict[str, Any]:
        if action not in {"start", "stop", "restart"}:
            raise ValueError("不支持的服务操作。")
        if self.platform == "windows":
            self._windows_control(action)
        else:
            self._linux_control(action)
        return self.status()

    def logs(self, lines: int = 200) -> dict[str, Any]:
        safe_lines = max(20, min(lines, 500))
        if self.platform == "windows":
            return self._tail_log_file(safe_lines)
        return self._linux_logs(safe_lines)

    def stream_logs_process(self, lines: int = 80) -> subprocess.Popen[str]:
        safe_lines = max(20, min(lines, 300))
        if self.platform == "windows":
            return self._windows_stream_logs_process(safe_lines)
        return self._linux_stream_logs_process(safe_lines)

    def _linux_status(self) -> dict[str, Any]:
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

    def _linux_control(self, action: str) -> None:
        self._run(["systemctl", action, self.service_name])

    def _linux_logs(self, safe_lines: int) -> dict[str, Any]:
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

    def _linux_stream_logs_process(self, safe_lines: int) -> subprocess.Popen[str]:
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

    def _windows_status(self) -> dict[str, Any]:
        payload = self._run_powershell_json(
            f"""
$ErrorActionPreference = 'Stop'
$service = Get-CimInstance Win32_Service -Filter "Name='{self._ps_single_quote(self.service_name)}'"
if ($null -eq $service) {{
    throw "找不到 Windows 服务：{self.service_name}"
}}
$processPayload = $null
$activeSince = ""
if ([int]$service.ProcessId -gt 0) {{
    try {{
        $proc = Get-Process -Id $service.ProcessId -ErrorAction Stop
        $activeSince = $proc.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
        $elapsedSeconds = [int]((Get-Date) - $proc.StartTime).TotalSeconds
        $days = [int]($elapsedSeconds / 86400)
        $hours = [int](($elapsedSeconds % 86400) / 3600)
        $minutes = [int](($elapsedSeconds % 3600) / 60)
        $seconds = [int]($elapsedSeconds % 60)
        $elapsedText = "{0:00}.{1:00}:{2:00}:{3:00}" -f $days, $hours, $minutes, $seconds
        $processPayload = [pscustomobject]@{{
            cpu_percent = ""
            memory_percent = ""
            cpu_display = if ($null -ne $proc.CPU) {{ "{0:N1} s" -f $proc.CPU }} else {{ "" }}
            memory_display = "{0:N1} MB" -f ($proc.WorkingSet64 / 1MB)
            elapsed = $elapsedText
            command = $service.PathName
        }}
    }} catch {{
        $processPayload = $null
    }}
}}
[pscustomobject]@{{
    service_name = $service.Name
    description = $service.Description
    load_state = "loaded"
    active_state = $service.State
    sub_state = $service.Status
    unit_file_state = $service.StartMode
    pid = [int]$service.ProcessId
    main_code = [string]$service.ExitCode
    main_status = [string]$service.ServiceSpecificExitCode
    active_since = $activeSince
    fragment_path = $service.PathName
    is_active = ($service.State -eq "Running")
    process = $processPayload
}} | ConvertTo-Json -Depth 4 -Compress
"""
        )
        if not isinstance(payload, dict):
            raise RuntimeError("读取 Windows 服务状态失败。")
        return payload

    def _windows_control(self, action: str) -> None:
        self._run_powershell(
            f"""
$ErrorActionPreference = 'Stop'
$name = '{self._ps_single_quote(self.service_name)}'
$service = Get-Service -Name $name -ErrorAction Stop
switch ('{action}') {{
    'start' {{
        if ($service.Status -ne 'Running') {{
            Start-Service -Name $name -ErrorAction Stop
        }}
    }}
    'stop' {{
        if ($service.Status -ne 'Stopped') {{
            Stop-Service -Name $name -Force -ErrorAction Stop
        }}
    }}
    'restart' {{
        if ($service.Status -eq 'Stopped') {{
            Start-Service -Name $name -ErrorAction Stop
        }} else {{
            Restart-Service -Name $name -Force -ErrorAction Stop
        }}
    }}
}}
Start-Sleep -Milliseconds 800
"""
        )

    def _windows_stream_logs_process(self, safe_lines: int) -> subprocess.Popen[str]:
        if self.log_path and self.log_path.exists():
            script = (
                f"$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
                f"Get-Content -Path '{self._ps_single_quote(str(self.log_path))}' "
                f"-Tail {safe_lines} -Wait -Encoding UTF8"
            )
        else:
            message = self._windows_log_hint()
            script = (
                f"$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
                f"Write-Output '{self._ps_single_quote(message)}'; "
                "while ($true) { Start-Sleep -Seconds 30 }"
            )
        return subprocess.Popen(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                script,
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

    def _tail_log_file(self, safe_lines: int) -> dict[str, Any]:
        if not self.log_path:
            return {"lines": ["未配置日志文件路径。"], "requested": safe_lines}
        if not self.log_path.exists():
            return {"lines": [self._windows_log_hint()], "requested": safe_lines}
        with self.log_path.open("r", encoding="utf-8", errors="replace") as handle:
            entries = deque((line.rstrip() for line in handle if line.strip()), maxlen=safe_lines)
        return {"lines": list(entries), "requested": safe_lines}

    def _windows_log_hint(self) -> str:
        if not self.log_path:
            return "未配置日志文件路径。"
        return f"日志文件不存在：{self.log_path}"

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

    @classmethod
    def _run_powershell_json(cls, script: str) -> dict[str, Any]:
        result = cls._run_powershell(script)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError(result.stdout.strip() or "PowerShell JSON 输出解析失败。") from exc

    @classmethod
    def _run_powershell(cls, script: str) -> CommandResult:
        return cls._run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                script,
            ]
        )

    @staticmethod
    def _ps_single_quote(value: str) -> str:
        return value.replace("'", "''")
