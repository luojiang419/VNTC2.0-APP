from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from vnt_panel.auth import AuthManager
from vnt_panel.configuration import VNTConfigManager


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
    def test_configuration_module_supports_tomli_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tomli.py").write_text(
                "def loads(raw):\n    return {'fallback': True, 'raw': raw}\n",
                encoding="utf-8",
            )
            script = textwrap.dedent(
                f"""
                import builtins
                import sys

                real_import = builtins.__import__

                def fake_import(name, globals=None, locals=None, fromlist=(), level=0):
                    if name == "tomllib":
                        raise ModuleNotFoundError("No module named 'tomllib'")
                    return real_import(name, globals, locals, fromlist, level)

                builtins.__import__ = fake_import
                sys.path.insert(0, {str(root)!r})
                sys.path.insert(0, {str(Path(__file__).resolve().parents[1])!r})

                import vnt_panel.configuration as configuration

                parsed = configuration.tomllib.loads("network = 'demo'\\n")
                assert parsed["fallback"] is True
                """
            )
            completed = subprocess.run(
                [sys.executable, "-c", script],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=completed.stderr or completed.stdout,
            )

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


class StaticThemeAssetsTests(unittest.TestCase):
    def test_theme_assets_cover_system_follow_and_login_sidebar_tokens(self) -> None:
        static_root = Path(__file__).resolve().parents[1] / "static"
        app_js = (static_root / "app.js").read_text(encoding="utf-8")
        styles_css = (static_root / "styles.css").read_text(encoding="utf-8")
        index_html = (static_root / "index.html").read_text(encoding="utf-8")

        self.assertIn('return stored === "dark" || stored === "light" ? stored : "system";', app_js)
        self.assertIn("prefers-color-scheme: dark", app_js)
        self.assertIn('document.documentElement.setAttribute("data-theme-source", normalizedPreference);', app_js)
        self.assertIn("--sidebar-shell-bg", styles_css)
        self.assertIn("--login-ink", styles_css)
        self.assertIn("--stream-ink", styles_css)
        self.assertIn("跟随系统", index_html)


if __name__ == "__main__":
    unittest.main()
