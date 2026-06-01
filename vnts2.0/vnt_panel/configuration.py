from __future__ import annotations

import json
import re
import shutil
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - exercised in compatibility test subprocess
    import tomli as tomllib


CONFIG_FIELD_ORDER = (
    "tcp_bind",
    "quic_bind",
    "ws_bind",
    "network",
    "white_list",
    "lease_duration",
    "web_bind",
    "username",
    "password",
    "persistence",
    "cert",
    "key",
    "server_quic_bind",
    "peer_servers",
    "server_token",
)


class VNTConfigManager:
    def __init__(self, config_path: Path, backup_dir: Path) -> None:
        self.config_path = config_path
        self.backup_dir = backup_dir

    def load(self) -> dict[str, Any]:
        try:
            if self.config_path.exists():
                raw = self.config_path.read_text(encoding="utf-8")
            else:
                raw = self.render(self.default_payload())
        except PermissionError as exc:
            raise RuntimeError(
                f"无法读取配置文件 {self.config_path}，请确认面板进程有足够权限。"
            ) from exc
        except OSError as exc:
            raise RuntimeError(f"读取配置文件失败：{exc}") from exc
        parsed = tomllib.loads(raw)
        return {
            "path": str(self.config_path),
            "raw": raw,
            "structured": self.extract_structured(parsed),
            "updated_at": self._format_timestamp(self.config_path) if self.config_path.exists() else None,
        }

    def save_structured(self, payload: dict[str, Any]) -> dict[str, Any]:
        normalized = self.normalize_payload(payload)
        self.validate_structured(normalized)
        raw = self.render(normalized)
        return self._write(raw)

    def save_raw(self, raw: str) -> dict[str, Any]:
        if not raw.strip():
            raise ValueError("TOML 内容不能为空。")
        tomllib.loads(raw)
        return self._write(raw.rstrip() + "\n")

    def default_payload(self) -> dict[str, Any]:
        return {
            "tcp_bind": "0.0.0.0:2222",
            "quic_bind": "0.0.0.0:2222",
            "ws_bind": "0.0.0.0:2222",
            "network": "10.26.0.0/24",
            "white_list": [],
            "lease_duration": 86400,
            "web_bind": "",
            "username": "",
            "password": "",
            "persistence": True,
            "cert": "",
            "key": "",
            "server_quic_bind": "",
            "peer_servers": [],
            "server_token": "",
            "custom_nets": [],
        }

    def extract_structured(self, parsed: dict[str, Any]) -> dict[str, Any]:
        payload = self.default_payload()
        for field in CONFIG_FIELD_ORDER:
            if field not in parsed:
                continue
            payload[field] = parsed[field]
        payload["white_list"] = self._string_list(parsed.get("white_list", []))
        payload["peer_servers"] = self._string_list(parsed.get("peer_servers", []))
        payload["lease_duration"] = int(parsed.get("lease_duration", payload["lease_duration"]))
        payload["persistence"] = bool(parsed.get("persistence", payload["persistence"]))
        payload["custom_nets"] = [
            {"name": str(name), "cidr": str(cidr)}
            for name, cidr in parsed.get("custom_nets", {}).items()
        ]
        for key in ("tcp_bind", "quic_bind", "ws_bind", "network", "web_bind", "username", "password", "cert", "key", "server_quic_bind", "server_token"):
            payload[key] = str(payload.get(key, "") or "")
        return payload

    def normalize_payload(self, payload: dict[str, Any]) -> dict[str, Any]:
        normalized = self.default_payload()
        for field in CONFIG_FIELD_ORDER:
            if field not in payload:
                continue
            if field in {"white_list", "peer_servers"}:
                normalized[field] = self._string_list(payload.get(field, []))
            elif field == "lease_duration":
                normalized[field] = int(payload.get(field, normalized[field]))
            elif field == "persistence":
                normalized[field] = bool(payload.get(field))
            else:
                normalized[field] = str(payload.get(field, "") or "").strip()
        normalized["custom_nets"] = []
        for item in payload.get("custom_nets", []):
            name = str((item or {}).get("name", "")).strip()
            cidr = str((item or {}).get("cidr", "")).strip()
            if name or cidr:
                normalized["custom_nets"].append({"name": name, "cidr": cidr})
        return normalized

    def validate_structured(self, payload: dict[str, Any]) -> None:
        if not payload["network"]:
            raise ValueError("默认虚拟网段 network 不能为空。")
        if payload["lease_duration"] <= 0:
            raise ValueError("IP 租约时长 lease_duration 必须大于 0。")
        if not any(payload[field] for field in ("tcp_bind", "quic_bind", "ws_bind")):
            raise ValueError("至少需要启用一个连接监听：tcp_bind、quic_bind、ws_bind。")
        if payload["web_bind"] and (not payload["username"] or not payload["password"]):
            raise ValueError("启用 web_bind 时，username 和 password 也必须填写。")
        for field in ("tcp_bind", "quic_bind", "ws_bind", "web_bind", "server_quic_bind"):
            value = payload[field]
            if value and ":" not in value:
                raise ValueError(f"{field} 需要使用 host:port 格式。")
        for item in payload["custom_nets"]:
            if not item["name"] or not item["cidr"]:
                raise ValueError("自定义网段 custom_nets 的名称和 CIDR 都必须填写。")
            if not re.fullmatch(r"[A-Za-z0-9_-]+", item["name"]):
                raise ValueError(f"自定义网段名称 {item['name']} 只能包含字母、数字、下划线和中横线。")

    def render(self, payload: dict[str, Any]) -> str:
        lines: list[str] = []
        self._append_optional_string(lines, "tcp_bind", payload["tcp_bind"])
        self._append_optional_string(lines, "quic_bind", payload["quic_bind"])
        self._append_optional_string(lines, "ws_bind", payload["ws_bind"])
        self._append_required(lines, "network", payload["network"])
        lines.append(f"white_list = {json.dumps(payload['white_list'], ensure_ascii=False)}")
        lines.append(f"lease_duration = {int(payload['lease_duration'])}")
        self._append_optional_string(lines, "web_bind", payload["web_bind"])
        self._append_optional_string(lines, "username", payload["username"])
        self._append_optional_string(lines, "password", payload["password"])
        lines.append(f"persistence = {str(bool(payload['persistence'])).lower()}")
        self._append_optional_string(lines, "cert", payload["cert"])
        self._append_optional_string(lines, "key", payload["key"])
        self._append_optional_string(lines, "server_quic_bind", payload["server_quic_bind"])
        if payload["peer_servers"]:
            lines.append(f"peer_servers = {json.dumps(payload['peer_servers'], ensure_ascii=False)}")
        self._append_optional_string(lines, "server_token", payload["server_token"])
        lines.append("")
        lines.append("[custom_nets]")
        for item in payload["custom_nets"]:
            lines.append(f"{item['name']} = {json.dumps(item['cidr'], ensure_ascii=False)}")
        return "\n".join(lines).rstrip() + "\n"

    def _write(self, raw: str) -> dict[str, Any]:
        try:
            self.config_path.parent.mkdir(parents=True, exist_ok=True)
            backup_path = self._backup_existing_file()
            self.config_path.write_text(raw, encoding="utf-8")
        except PermissionError as exc:
            raise RuntimeError(
                f"无法写入配置文件 {self.config_path}，请确认面板进程有足够权限。"
            ) from exc
        except OSError as exc:
            raise RuntimeError(f"写入配置文件失败：{exc}") from exc
        snapshot = self.load()
        snapshot["backup_path"] = str(backup_path) if backup_path else None
        return snapshot

    def _backup_existing_file(self) -> Path | None:
        if not self.config_path.exists():
            return None
        self.backup_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = self.backup_dir / f"{self.config_path.stem}-{timestamp}.toml"
        shutil.copy2(self.config_path, backup_path)
        return backup_path

    @staticmethod
    def _append_optional_string(lines: list[str], key: str, value: str) -> None:
        if value:
            lines.append(f"{key} = {json.dumps(value, ensure_ascii=False)}")

    @staticmethod
    def _append_required(lines: list[str], key: str, value: str) -> None:
        lines.append(f"{key} = {json.dumps(value, ensure_ascii=False)}")

    @staticmethod
    def _string_list(values: Any) -> list[str]:
        if not isinstance(values, list):
            return []
        result: list[str] = []
        for item in values:
            value = str(item).strip()
            if value:
                result.append(value)
        return result

    @staticmethod
    def _format_timestamp(path: Path) -> str | None:
        if not path.exists():
            return None
        return datetime.fromtimestamp(path.stat().st_mtime).astimezone().isoformat(timespec="seconds")
