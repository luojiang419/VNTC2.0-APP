from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path


@dataclass(slots=True)
class PanelSettings:
    host: str
    port: int
    username: str
    password: str
    session_ttl_seconds: int
    session_secret: str
    service_name: str
    config_path: Path
    backup_dir: Path
    credentials_path: Path
    static_dir: Path

    @property
    def working_dir(self) -> Path:
        return self.config_path.parent

    @classmethod
    def from_env(cls) -> "PanelSettings":
        root_dir = Path(__file__).resolve().parent.parent
        config_path = Path(
            os.getenv("VNT_CONFIG_PATH", "/root/vnts2/config.toml")
        ).expanduser()
        backup_dir = Path(
            os.getenv(
                "VNT_CONFIG_BACKUP_DIR",
                str(config_path.parent / ".backups"),
            )
        ).expanduser()
        credentials_path = Path(
            os.getenv(
                "VNT_PANEL_AUTH_FILE",
                str(root_dir / "data" / "vnts-auth.json"),
            )
        ).expanduser()
        return cls(
            host=os.getenv("VNT_PANEL_HOST", "0.0.0.0"),
            port=int(os.getenv("VNT_PANEL_PORT", "2223")),
            username=os.getenv("VNT_PANEL_USERNAME", "luojiang"),
            password=os.getenv("VNT_PANEL_PASSWORD", "luojiang"),
            session_ttl_seconds=int(os.getenv("VNT_PANEL_SESSION_TTL", "43200")),
            session_secret=os.getenv("VNT_PANEL_SECRET") or secrets.token_urlsafe(48),
            service_name=os.getenv("VNT_SERVICE_NAME", "vnts2.service"),
            config_path=config_path,
            backup_dir=backup_dir,
            credentials_path=credentials_path,
            static_dir=root_dir / "static",
        )
