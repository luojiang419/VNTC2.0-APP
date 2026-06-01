from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vnt_panel.auth import AuthManager
from vnt_panel.configuration import VNTConfigManager
from vnt_panel.settings import PanelSettings
from vnt_panel.system import ServiceManager


class AuthManagerTests(unittest.TestCase):
    def test_login_and_logout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            auth = AuthManager("admin", "secret", 30, Path(tmp) / "auth.json")
            token = auth.login("admin", "secret")
            self.assertIsNotNone(token)
            self.assertEqual(auth.current_user(token), "admin")
            auth.logout(token)
            self.assertIsNone(auth.current_user(token))

    def test_update_credentials_takes_effect_immediately(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            auth = AuthManager("admin", "secret", 30, Path(tmp) / "auth.json")
            token = auth.login("admin", "secret")
            self.assertIsNotNone(token)
            account = auth.update_credentials("luojiang", "luojiang")
            self.assertEqual(account["username"], "luojiang")
            self.assertEqual(auth.current_user(token), "luojiang")
            self.assertIsNotNone(auth.login("luojiang", "luojiang"))


class ConfigManagerTests(unittest.TestCase):
    def test_load_existing_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_path = root / "config.toml"
            config_path.write_text(
                '\n'.join(
                    [
                        'tcp_bind = "0.0.0.0:2222"',
                        'network = "10.26.0.0/24"',
                        "white_list = [\"alpha\", \"beta\"]",
                        "lease_duration = 7200",
                        "persistence = true",
                        "",
                        "[custom_nets]",
                        'office = "10.99.0.0/24"',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            manager = VNTConfigManager(config_path, root / ".backups")
            snapshot = manager.load()
            self.assertEqual(snapshot["structured"]["tcp_bind"], "0.0.0.0:2222")
            self.assertEqual(snapshot["structured"]["white_list"], ["alpha", "beta"])
            self.assertEqual(snapshot["structured"]["custom_nets"][0]["name"], "office")

    def test_save_structured_creates_backup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_path = root / "config.toml"
            config_path.write_text('network = "10.26.0.0/24"\n', encoding="utf-8")
            manager = VNTConfigManager(config_path, root / ".backups")
            snapshot = manager.save_structured(
                {
                    "tcp_bind": "0.0.0.0:2222",
                    "quic_bind": "0.0.0.0:2222",
                    "ws_bind": "0.0.0.0:2222",
                    "network": "10.26.0.0/24",
                    "white_list": [],
                    "lease_duration": 86400,
                    "persistence": True,
                    "custom_nets": [{"name": "net1", "cidr": "10.25.0.0/24"}],
                }
            )
            self.assertTrue(Path(snapshot["backup_path"]).exists())
            self.assertIn('net1 = "10.25.0.0/24"', snapshot["raw"])


class PanelSettingsTests(unittest.TestCase):
    def test_windows_defaults_point_to_windows_deploy_directory(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "VNT_SERVICE_PLATFORM": "windows",
            },
            clear=False,
        ):
            settings = PanelSettings.from_env()
            self.assertEqual(settings.platform, "windows")
            self.assertEqual(settings.service_name, "vnts2")
            self.assertEqual(settings.config_path.name, "config.toml")
            self.assertEqual(settings.config_path.parent.name, "windows-deploy")
            self.assertEqual(settings.log_path.parent.name, "logs")


class ServiceManagerTests(unittest.TestCase):
    def test_windows_logs_return_hint_when_file_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log_path = Path(tmp) / "logs" / "vnts2.log"
            manager = ServiceManager("vnts2", log_path=log_path, platform="windows")
            payload = manager.logs(20)
            self.assertEqual(payload["requested"], 20)
            self.assertIn("日志文件不存在", payload["lines"][0])

    def test_windows_logs_tail_latest_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log_path = Path(tmp) / "logs" / "vnts2.log"
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text("line1\nline2\nline3\n", encoding="utf-8")
            manager = ServiceManager("vnts2", log_path=log_path, platform="windows")
            payload = manager.logs(20)
            self.assertEqual(payload["lines"], ["line1", "line2", "line3"])


if __name__ == "__main__":
    unittest.main()
