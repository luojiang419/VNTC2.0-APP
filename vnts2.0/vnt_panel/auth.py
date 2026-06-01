from __future__ import annotations

import hashlib
import json
import secrets
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class SessionRecord:
    username: str
    expires_at: float


@dataclass(slots=True)
class CredentialRecord:
    username: str
    password_hash: str
    salt: str
    updated_at: str


class AuthManager:
    def __init__(
        self,
        username: str,
        password: str,
        ttl_seconds: int,
        credentials_path: Path,
    ) -> None:
        self._ttl_seconds = ttl_seconds
        self._credentials_path = credentials_path
        self._sessions: dict[str, SessionRecord] = {}
        self._lock = threading.Lock()
        self._credentials = self._load_or_initialize(username, password)

    def login(self, username: str, password: str) -> str | None:
        with self._lock:
            self._purge_locked()
            if username != self._credentials.username:
                return None
            if not self._verify_password_locked(password):
                return None
            token = secrets.token_urlsafe(32)
            self._sessions[token] = SessionRecord(
                username=username,
                expires_at=time.time() + self._ttl_seconds,
            )
            return token

    def logout(self, token: str | None) -> None:
        if not token:
            return
        with self._lock:
            self._sessions.pop(token, None)

    def current_user(self, token: str | None) -> str | None:
        if not token:
            return None
        with self._lock:
            self._purge_locked()
            record = self._sessions.get(token)
            return record.username if record else None

    def account_summary(self) -> dict[str, Any]:
        with self._lock:
            return self._account_summary_locked()

    def update_credentials(self, username: str, password: str) -> dict[str, Any]:
        username = username.strip()
        if not username:
            raise ValueError("用户名不能为空。")
        if len(username) < 3:
            raise ValueError("用户名至少需要 3 个字符。")
        if not password:
            raise ValueError("密码不能为空。")
        if len(password) < 4:
            raise ValueError("密码至少需要 4 个字符。")

        with self._lock:
            self._credentials = self._create_credentials(username, password)
            for record in self._sessions.values():
                record.username = username
            self._persist_locked()
            return self._account_summary_locked()

    def _load_or_initialize(self, username: str, password: str) -> CredentialRecord:
        if self._credentials_path.exists():
            try:
                data = json.loads(self._credentials_path.read_text(encoding="utf-8"))
                return CredentialRecord(
                    username=str(data["username"]),
                    password_hash=str(data["password_hash"]),
                    salt=str(data["salt"]),
                    updated_at=str(data.get("updated_at", self._now_string())),
                )
            except Exception:
                pass

        credentials = self._create_credentials(username, password)
        with self._lock:
            self._credentials = credentials
            self._persist_locked()
        return credentials

    def _verify_password_locked(self, password: str) -> bool:
        password_hash = self._hash_password(password, self._credentials.salt)
        return secrets.compare_digest(password_hash, self._credentials.password_hash)

    def _create_credentials(self, username: str, password: str) -> CredentialRecord:
        salt = secrets.token_hex(16)
        return CredentialRecord(
            username=username,
            password_hash=self._hash_password(password, salt),
            salt=salt,
            updated_at=self._now_string(),
        )

    def _persist_locked(self) -> None:
        self._credentials_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "username": self._credentials.username,
            "password_hash": self._credentials.password_hash,
            "salt": self._credentials.salt,
            "updated_at": self._credentials.updated_at,
        }
        self._credentials_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        try:
            self._credentials_path.chmod(0o600)
        except OSError:
            pass

    def _account_summary_locked(self) -> dict[str, Any]:
        return {
            "username": self._credentials.username,
            "updated_at": self._credentials.updated_at,
            "credentials_path": str(self._credentials_path),
        }

    def _purge_locked(self) -> None:
        now = time.time()
        expired = [token for token, record in self._sessions.items() if record.expires_at <= now]
        for token in expired:
            self._sessions.pop(token, None)

    @staticmethod
    def _hash_password(password: str, salt: str) -> str:
        raw = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            salt.encode("utf-8"),
            120_000,
        )
        return raw.hex()

    @staticmethod
    def _now_string() -> str:
        return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
