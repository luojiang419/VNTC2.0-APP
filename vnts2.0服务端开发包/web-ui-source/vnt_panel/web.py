from __future__ import annotations

import argparse
import json
import mimetypes
import select
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .auth import AuthManager
from .configuration import VNTConfigManager
from .settings import PanelSettings
from .system import ServiceManager


class VNTPanelServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        request_handler_class: type[BaseHTTPRequestHandler],
        settings: PanelSettings,
    ) -> None:
        super().__init__(server_address, request_handler_class)
        self.settings = settings
        self.auth = AuthManager(
            username=settings.username,
            password=settings.password,
            ttl_seconds=settings.session_ttl_seconds,
            credentials_path=settings.credentials_path,
        )
        self.config_manager = VNTConfigManager(
            config_path=settings.config_path,
            backup_dir=settings.backup_dir,
        )
        self.service_manager = ServiceManager(
            settings.service_name,
            log_path=settings.log_path,
            platform=settings.platform,
        )


class RequestHandler(BaseHTTPRequestHandler):
    server: VNTPanelServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/"):
            self._dispatch_api("GET", parsed)
            return
        self._serve_static(parsed.path)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        self._dispatch_api("POST", parsed)

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        self._dispatch_api("PUT", parsed)

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def _dispatch_api(self, method: str, parsed) -> None:
        try:
            if parsed.path == "/api/session" and method == "GET":
                self._handle_session()
                return
            if parsed.path == "/api/login" and method == "POST":
                self._handle_login()
                return
            if parsed.path == "/api/logout" and method == "POST":
                self._handle_logout()
                return

            user = self._require_session()
            if not user:
                return

            if parsed.path == "/api/overview" and method == "GET":
                self._send_json(
                    {
                        "meta": self._meta_payload(),
                        "status": self.server.service_manager.status(),
                        "config": self.server.config_manager.load(),
                        "account": self.server.auth.account_summary(),
                    }
                )
                return
            if parsed.path == "/api/settings/account" and method == "GET":
                self._send_json(self.server.auth.account_summary())
                return
            if parsed.path == "/api/status" and method == "GET":
                self._send_json(self.server.service_manager.status())
                return
            if parsed.path == "/api/logs" and method == "GET":
                lines = self._int_query(parsed, "lines", default=200)
                self._send_json(self.server.service_manager.logs(lines))
                return
            if parsed.path == "/api/logs/stream" and method == "GET":
                lines = self._int_query(parsed, "lines", default=80)
                self._stream_logs(lines)
                return
            if parsed.path == "/api/config" and method == "GET":
                self._send_json(self.server.config_manager.load())
                return
            if parsed.path == "/api/config/structured" and method == "PUT":
                payload = self._read_json()
                restart = bool(payload.pop("restart", False))
                config = self.server.config_manager.save_structured(payload)
                if restart:
                    self.server.service_manager.control("restart")
                self._send_json(
                    {
                        "message": "结构化配置已保存。",
                        "config": config,
                        "status": self.server.service_manager.status(),
                    }
                )
                return
            if parsed.path == "/api/config/raw" and method == "PUT":
                payload = self._read_json()
                raw = str(payload.get("raw", ""))
                restart = bool(payload.get("restart", False))
                config = self.server.config_manager.save_raw(raw)
                if restart:
                    self.server.service_manager.control("restart")
                self._send_json(
                    {
                        "message": "TOML 配置已保存。",
                        "config": config,
                        "status": self.server.service_manager.status(),
                    }
                )
                return
            if parsed.path == "/api/service" and method == "POST":
                payload = self._read_json()
                action = str(payload.get("action", ""))
                status = self.server.service_manager.control(action)
                self._send_json(
                    {
                        "message": f"服务已执行 {action}。",
                        "status": status,
                    }
                )
                return
            if parsed.path == "/api/settings/account" and method == "PUT":
                payload = self._read_json()
                username = str(payload.get("username", ""))
                password = str(payload.get("password", ""))
                confirm_password = str(payload.get("confirm_password", ""))
                if password != confirm_password:
                    raise ValueError("两次输入的密码不一致。")
                account = self.server.auth.update_credentials(username=username, password=password)
                self._send_json(
                    {
                        "message": "登录账号已更新，新的账号密码已立即生效。",
                        "account": account,
                    }
                )
                return
            self._send_error_json(HTTPStatus.NOT_FOUND, "接口不存在。")
        except ValueError as exc:
            self._send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
        except RuntimeError as exc:
            self._send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, str(exc))
        except Exception as exc:  # pragma: no cover
            self._send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, f"服务器内部错误：{exc}")

    def _handle_session(self) -> None:
        user = self.server.auth.current_user(self._session_token())
        self._send_json({"authenticated": bool(user), "user": user})

    def _handle_login(self) -> None:
        payload = self._read_json()
        token = self.server.auth.login(
            str(payload.get("username", "")),
            str(payload.get("password", "")),
        )
        if not token:
            self._send_error_json(HTTPStatus.UNAUTHORIZED, "用户名或密码不正确。")
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header(
            "Set-Cookie",
            f"vnt_panel_session={token}; HttpOnly; SameSite=Strict; Path=/",
        )
        self.end_headers()
        self.wfile.write(json.dumps({"authenticated": True}, ensure_ascii=False).encode("utf-8"))

    def _handle_logout(self) -> None:
        token = self._session_token()
        self.server.auth.logout(token)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header(
            "Set-Cookie",
            "vnt_panel_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0",
        )
        self.end_headers()
        self.wfile.write(json.dumps({"authenticated": False}, ensure_ascii=False).encode("utf-8"))

    def _require_session(self) -> str | None:
        user = self.server.auth.current_user(self._session_token())
        if not user:
            self._send_error_json(HTTPStatus.UNAUTHORIZED, "请先登录。")
            return None
        return user

    def _session_token(self) -> str | None:
        cookie_header = self.headers.get("Cookie")
        if not cookie_header:
            return None
        cookie = SimpleCookie()
        cookie.load(cookie_header)
        morsel = cookie.get("vnt_panel_session")
        return morsel.value if morsel else None

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8") if length else "{}"
        return json.loads(raw or "{}")

    def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, status: HTTPStatus, message: str) -> None:
        self._send_json({"error": message}, status=status)

    def _serve_static(self, raw_path: str) -> None:
        path = raw_path if raw_path not in {"", "/"} else "/index.html"
        relative = path.lstrip("/")
        file_path = (self.server.settings.static_dir / relative).resolve()
        static_root = self.server.settings.static_dir.resolve()
        if static_root not in file_path.parents and file_path != static_root:
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        if not file_path.exists() or file_path.is_dir():
            file_path = static_root / "index.html"
        content_type, _ = mimetypes.guess_type(file_path.name)
        self.send_response(HTTPStatus.OK)
        self.send_header(
            "Content-Type",
            f"{content_type or 'text/html'}; charset=utf-8",
        )
        data = file_path.read_bytes()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _stream_logs(self, lines: int) -> None:
        process = self.server.service_manager.stream_logs_process(lines)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        try:
            stdout = process.stdout
            if stdout is None:
                return
            while True:
                ready, _, _ = select.select([stdout], [], [], 12)
                if ready:
                    line = stdout.readline()
                    if not line:
                        break
                    payload = json.dumps({"line": line.rstrip()}, ensure_ascii=False)
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                else:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            process.terminate()
            try:
                process.wait(timeout=2)
            except Exception:
                process.kill()

    def _meta_payload(self) -> dict[str, Any]:
        return {
            "panel_name": "VNTS 2.0 Control Panel",
            "platform": self.server.settings.platform,
            "service_name": self.server.settings.service_name,
            "config_path": str(self.server.settings.config_path),
            "backup_dir": str(self.server.settings.backup_dir),
            "log_path": str(self.server.settings.log_path),
            "working_dir": str(self.server.settings.working_dir),
        }

    @staticmethod
    def _int_query(parsed, key: str, default: int) -> int:
        query = parse_qs(parsed.query)
        raw = query.get(key, [str(default)])[0]
        return int(raw)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="VNTS 2.0 控制面板")
    parser.add_argument("--host", help="监听地址")
    parser.add_argument("--port", type=int, help="监听端口")
    return parser


def main() -> int:
    settings = PanelSettings.from_env()
    args = build_arg_parser().parse_args()
    if args.host:
        settings.host = args.host
    if args.port:
        settings.port = args.port
    httpd = VNTPanelServer((settings.host, settings.port), RequestHandler, settings)
    print(
        f"VNT panel listening on http://{settings.host}:{settings.port} "
        f"for service {settings.service_name}"
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        httpd.server_close()
    return 0
