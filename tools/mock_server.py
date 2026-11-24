#!/usr/bin/env python3
"""RainCheck 本地演练服务端（零依赖，仅标准库）。

用于离线全链路验证：
  1. 登录：扫码登录（pre-info / wait-for-scan / login / login-with-code）与
     Web 手机短信登录（/pc/login/send_sms_login_code/、/pc/login/verify_pwd_login/）及 basic-info
  2. 课堂上下文：on-lesson-upcoming-exam / checkin-list / checkin/detail / lesson/basic-info
  3. 签到：lesson/checkin（支持静态码、动态 ticket/t/s 强校验、source=14 拒绝回退、
     重复签到、过期码、双载体 Bearer + Cookie/CSRF 鉴权、响应头会话刷新）
  4. 管理：/admin/reset、/admin/lesson、/admin/ticket、/admin/qr、/admin/scan、
     /admin/attend、/admin/state

所有业务响应结构与真实服务保持一致：{"code": 0, "msg": "...", "data": {...}}
（Web /pc/login/* 接口按官方返回 {"success": true/false, "status_code": ..., "msg": "...", "data": {...}}）
"""
from __future__ import annotations

import argparse
import json
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

STATE_LOCK = threading.Lock()
CLIENT_DISCONNECT_ERRORS = (ConnectionResetError, BrokenPipeError, ConnectionAbortedError)
MAINLAND_PHONE_RE = re.compile(r"^1[3456789]\d{9}$")
SMS_CODE_RE = re.compile(r"^\d{4,8}$")


class BadJsonError(ValueError):
    """请求体不是合法的 JSON 对象。"""


class World:
    def __init__(
        self,
        *,
        require_ticket: bool = False,
        reject_source_14: bool = False,
        strict_headers: bool = True,
        strict_csrf: bool = True,
        refresh_session: bool = False,
        ticket_ttl: float = 8.0,
        login_ttl: float = 120.0,
    ) -> None:
        self.default_require_ticket = require_ticket
        self.default_reject_source_14 = reject_source_14
        self.default_strict_headers = strict_headers
        self.default_strict_csrf = strict_csrf
        self.default_refresh_session = refresh_session
        self.default_ticket_ttl = ticket_ttl
        self.default_login_ttl = login_ttl
        self._ticket_seq = 0
        self._login_seq = 0
        self._sms_seq = 0
        self._refresh_seq = 0
        self.reset()

    def configure_defaults(
        self,
        *,
        require_ticket: bool,
        reject_source_14: bool,
        strict_headers: bool,
        strict_csrf: bool,
        refresh_session: bool,
        ticket_ttl: float = 8.0,
        login_ttl: float = 120.0,
    ) -> None:
        self.default_require_ticket = require_ticket
        self.default_reject_source_14 = reject_source_14
        self.default_strict_headers = strict_headers
        self.default_strict_csrf = strict_csrf
        self.default_refresh_session = refresh_session
        self.default_ticket_ttl = ticket_ttl
        self.default_login_ttl = login_ttl
        self.reset()

    def reset(self) -> None:
        self.lesson_id = "1529274209982060032"
        self.classroom_id = "2876543"
        self.lesson_name = "演武堂·签到演练"
        self.require_ticket = self.default_require_ticket
        self.reject_source_14 = self.default_reject_source_14
        self.strict_headers = self.default_strict_headers
        self.strict_csrf = self.default_strict_csrf
        self.refresh_session = self.default_refresh_session
        self.ticket_ttl = self.default_ticket_ttl
        self.login_ttl = self.default_login_ttl

        self.tickets: dict[str, dict[str, Any]] = {}
        self.sessions: dict[str, dict[str, Any]] = {}       # token/sid -> user dict
        self.login_flows: dict[str, dict[str, Any]] = {}    # login_token -> flow dict
        self.verify_tokens: dict[str, str] = {}             # verify_token -> login_token
        self.sms_codes: dict[str, dict[str, Any]] = {}      # mobile -> sms code state
        self.attendance: dict[str, dict[str, Any]] = {}     # uid -> record

        self.requests: list[dict[str, Any]] = []
        self.total_requests = 0
        self.path_counts: dict[str, int] = {}
        self.checkin_stats: dict[str, Any] = {
            "total": 0,
            "bySource": {},
            "accepted": 0,
            "already": 0,
            "rejected": 0,
        }

        self.users = {
            "u1001": "张三",
            "u1002": "李四",
            "u1003": "王五",
            "u1004": "赵六",
            "u1005": "钱七",
            "u1006": "孙八",
            "u1007": "周九",
            "u1008": "吴十",
        }
        for uid, name in self.users.items():
            csrf = f"csrf-{uid}"
            self.sessions[f"token-{uid}"] = {"id": uid, "name": name, "csrf": csrf}
            self.sessions[f"sid-{uid}"] = {"id": uid, "name": name, "csrf": csrf}

    def issue_ticket(self, ttl: float | None = None) -> dict[str, str]:
        self._ticket_seq += 1
        code = f"{self._ticket_seq:04d}{uuid.uuid4().hex[:8]}"
        ts = str(int(time.time()))
        sig = f"sig-{code[-6:]}-{ts[-4:]}"
        effective_ttl = self.ticket_ttl if ttl is None else float(ttl)
        self.tickets[code] = {
            "lessonId": self.lesson_id,
            "classroomId": self.classroom_id,
            "issued": time.time(),
            "ttl": effective_ttl,
            "t": ts,
            "s": sig,
            "v": "2",
        }
        return {
            "qr": f"c={code}&t={ts}&s={sig}&v=2",
            "c": code,
            "t": ts,
            "s": sig,
            "v": "2",
        }

    def create_login_flow(self, ttl: float | None = None) -> tuple[str, dict[str, Any]]:
        self._login_seq += 1
        token = f"login-{self._login_seq:04d}-{uuid.uuid4().hex[:8]}"
        flow = {
            "state": "pending",
            "user": None,
            "created": time.time(),
            "ttl": self.login_ttl if ttl is None else float(ttl),
            "verify_token": None,
            "expected_code": "",
        }
        self.login_flows[token] = flow
        return token, flow

    def issue_refreshed_session(self, user: dict[str, Any]) -> list[tuple[str, str]]:
        self._refresh_seq += 1
        uid = user["id"]
        new_token = f"refreshed-{uid}-{self._refresh_seq:04d}"
        new_csrf = f"csrf-{uid}-{self._refresh_seq:04d}"
        self.sessions[new_token] = {"id": uid, "name": user["name"], "csrf": new_csrf}
        return [
            ("set-auth", f"Bearer {new_token}"),
            ("Set-Cookie", f"sessionid={new_token}; Path=/; HttpOnly"),
            ("Set-Cookie", f"csrftoken={new_csrf}; Path=/"),
        ]


WORLD = World()


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request: Any, client_address: Any) -> None:
        _, exc, _ = sys_exc_info()
        if isinstance(exc, CLIENT_DISCONNECT_ERRORS):
            return
        super().handle_error(request, client_address)


def sys_exc_info() -> tuple[Any, Any, Any]:
    import sys

    return sys.exc_info()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "RainCheckMock/2.0"

    # ------------------------------------------------------------------ 基础

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        pass

    def handle(self) -> None:
        try:
            super().handle()
        except CLIENT_DISCONNECT_ERRORS:
            return

    def handle_one_request(self) -> None:
        try:
            super().handle_one_request()
        except CLIENT_DISCONNECT_ERRORS:
            self.close_connection = True

    def _read_json(self) -> dict[str, Any]:
        raw_len = self.headers.get("Content-Length")
        if raw_len is None or raw_len.strip() == "":
            return {}
        try:
            length = int(raw_len)
        except ValueError as exc:
            raise BadJsonError("无效的 Content-Length") from exc
        if length < 0:
            raise BadJsonError("Content-Length 不能为负数")
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            raise BadJsonError("请求体不是合法 JSON") from exc
        if not isinstance(parsed, dict):
            raise BadJsonError("JSON 请求体必须为对象")
        return parsed

    def _send(
        self,
        status: int,
        payload: dict[str, Any],
        headers: list[tuple[str, str]] | dict[str, str] | None = None,
    ) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            if isinstance(headers, dict):
                for key, value in headers.items():
                    self.send_header(key, value)
            elif headers:
                for key, value in headers:
                    self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)
        except CLIENT_DISCONNECT_ERRORS:
            self.close_connection = True

    def _ok(
        self,
        data: Any = None,
        msg: str = "success",
        headers: list[tuple[str, str]] | dict[str, str] | None = None,
    ) -> None:
        self._send(200, {"code": 0, "msg": msg, "data": data if data is not None else {}}, headers)

    def _fail(
        self,
        code: int,
        msg: str,
        status: int = 200,
        data: Any = None,
        headers: list[tuple[str, str]] | dict[str, str] | None = None,
    ) -> None:
        self._send(status, {"code": code, "msg": msg, "data": data}, headers)

    def _parse_cookies(self) -> dict[str, str]:
        result: dict[str, str] = {}
        raw_values = self.headers.get_all("Cookie") or []
        for header_val in raw_values:
            for item in header_val.split(";"):
                if "=" not in item:
                    continue
                key, value = item.split("=", 1)
                key = key.strip()
                if key:
                    result[key] = value.strip()
        return result

    def _authenticate(self, require_csrf: bool = False) -> tuple[dict[str, Any] | None, str | None, str | None, int]:
        """双载体鉴权：支持 Authorization: Bearer 与 Cookie: sessionid (+ X-CSRFToken)。

        返回 (user, auth_mode, error_msg, error_http_status)。
        """
        auth = (self.headers.get("Authorization") or "").strip()
        if auth.lower().startswith("bearer "):
            token = auth[7:].strip()
            user = WORLD.sessions.get(token)
            if user is not None:
                return user, "bearer", None, 200
            # 如果显式带了无效 Bearer 且没带有效 Cookie，直接判定未授权
            cookies = self._parse_cookies()
            sid = cookies.get("sessionid") or cookies.get("sid") or ""
            if not sid:
                return None, "bearer", "登录态已失效", 401

        cookies = self._parse_cookies()
        sid = cookies.get("sessionid") or cookies.get("sid") or ""
        if sid:
            user = WORLD.sessions.get(sid)
            if user is None:
                return None, "cookie", "会话 Cookie 已失效", 401
            if require_csrf:
                csrf_cookie = cookies.get("csrftoken") or ""
                csrf_header = (self.headers.get("X-CSRFToken") or "").strip()
                expected_csrf = str(user.get("csrf") or "")
                if WORLD.strict_csrf:
                    if not csrf_header or not csrf_cookie or csrf_header != csrf_cookie:
                        return None, "cookie", "缺少或无效的 X-CSRFToken", 403
                    if expected_csrf and csrf_header != expected_csrf:
                        return None, "cookie", "X-CSRFToken 与会话不匹配", 403
                elif csrf_cookie and csrf_header and csrf_header != csrf_cookie:
                    return None, "cookie", "X-CSRFToken 与 csrftoken 不一致", 403
            return user, "cookie", None, 200

        return None, None, "未登录", 401

    def _validate_business_headers(self) -> str | None:
        if not WORLD.strict_headers:
            return None
        missing = []
        if not (self.headers.get("xtbz") or "").strip():
            missing.append("xtbz")
        if not (self.headers.get("X-Client") or "").strip():
            missing.append("X-Client")
        if missing:
            return f"缺少必要协议请求头: {', '.join(missing)}"
        return None

    def _record(self, method: str, path_only: str, full_path: str) -> None:
        with STATE_LOCK:
            WORLD.total_requests += 1
            key = f"{method} {path_only}"
            WORLD.path_counts[key] = WORLD.path_counts.get(key, 0) + 1
            has_bearer = bool((self.headers.get("Authorization") or "").strip())
            has_cookie = bool((self.headers.get("Cookie") or "").strip())
            WORLD.requests.append(
                {
                    "at": time.strftime("%H:%M:%S"),
                    "method": method,
                    "path": full_path,
                    "auth": has_bearer or has_cookie,
                    "authMode": "bearer" if has_bearer else ("cookie" if has_cookie else "none"),
                }
            )
            if len(WORLD.requests) > 500:
                del WORLD.requests[:200]

    # ------------------------------------------------------------------ 路由

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        self._record("GET", path, self.path)
        with STATE_LOCK:
            if path.startswith("/api/"):
                header_err = self._validate_business_headers()
                if header_err:
                    return self._fail(40010, header_err, status=400)

            if path == "/api/v3/user/login/pre-info":
                return self._login_pre_info()
            if path == "/api/v3/user/basic-info":
                return self._basic_info()
            if path == "/api/v3/classroom/on-lesson-upcoming-exam":
                return self._active_lesson()
            if path == "/api/v3/lesson/checkin-list":
                return self._checkin_list(query)
            if path == "/api/v3/lesson/checkin/detail":
                return self._checkin_detail(query)
            if path == "/api/v3/lesson/basic-info":
                return self._lesson_basic(query)
            if path == "/admin/state":
                return self._ok(self._world_state())
            if path == "/admin/qr":
                return self._ok(WORLD.issue_ticket())
            if path == "/health":
                return self._ok({"ok": True})
        return self._fail(40400, f"未知路径 {path}", status=404)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        self._record("POST", path, self.path)
        try:
            body = self._read_json()
        except BadJsonError as exc:
            return self._fail(40000, str(exc), status=400)

        with STATE_LOCK:
            if path.startswith("/api/"):
                header_err = self._validate_business_headers()
                if header_err:
                    return self._fail(40010, header_err, status=400)

            if path == "/pc/login/send_sms_login_code/":
                return self._pc_send_sms(body)
            if path == "/pc/login/verify_pwd_login/":
                return self._pc_verify_pwd_login(body)
            if path == "/api/v3/user/login/wait-for-scan":
                return self._login_wait(body)
            if path == "/api/v3/user/login":
                return self._login_poll(body)
            if path == "/api/v3/user/login/login-with-code":
                return self._login_code(body)
            if path == "/api/v3/lesson/checkin":
                return self._checkin(body)
            if path == "/api/v3/lesson/checkin-list":
                return self._checkin_list({"lesson_id": [str(body.get("lesson_id") or body.get("lessonId") or "")]})
            if path == "/api/v3/lesson/checkin/detail":
                return self._checkin_detail(
                    {"checkinId": [str(body.get("checkin_id") or body.get("checkinId") or "")]}
                )
            if path == "/api/lesson/web_check_in":
                return self._fail(40400, "接口不存在", status=404)

            if path == "/admin/reset":
                WORLD.reset()
                if "requireTicket" in body:
                    WORLD.require_ticket = bool(body["requireTicket"])
                if "rejectSource14" in body:
                    WORLD.reject_source_14 = bool(body["rejectSource14"])
                if "strictHeaders" in body:
                    WORLD.strict_headers = bool(body["strictHeaders"])
                if "strictCsrf" in body:
                    WORLD.strict_csrf = bool(body["strictCsrf"])
                if "refreshSession" in body:
                    WORLD.refresh_session = bool(body["refreshSession"])
                return self._ok({"reset": True, "state": self._world_state()})
            if path == "/admin/lesson":
                WORLD.lesson_id = str(body.get("lessonId") or WORLD.lesson_id)
                WORLD.classroom_id = str(body.get("classroomId") or WORLD.classroom_id)
                WORLD.lesson_name = str(body.get("name") or WORLD.lesson_name)
                if "requireTicket" in body:
                    WORLD.require_ticket = bool(body["requireTicket"])
                if "rejectSource14" in body:
                    WORLD.reject_source_14 = bool(body["rejectSource14"])
                if "strictHeaders" in body:
                    WORLD.strict_headers = bool(body["strictHeaders"])
                if "strictCsrf" in body:
                    WORLD.strict_csrf = bool(body["strictCsrf"])
                if "refreshSession" in body:
                    WORLD.refresh_session = bool(body["refreshSession"])
                return self._ok(self._world_state())
            if path == "/admin/ticket":
                ttl = body.get("ttl")
                return self._ok(WORLD.issue_ticket(float(ttl) if ttl is not None else None))
            if path == "/admin/scan":
                return self._admin_scan(body)
            if path == "/admin/attend":
                user = str(body.get("user") or "")
                WORLD.attendance[user] = {
                    "user": user,
                    "at": time.time(),
                    "via": "admin",
                    "lessonId": WORLD.lesson_id,
                }
                return self._ok({"user": user, "seeded": True})
        return self._fail(40400, f"未知路径 {path}", status=404)

    # ------------------------------------------------------------------ 登录

    def _is_flow_expired(self, flow: dict[str, Any]) -> bool:
        return (time.time() - float(flow["created"])) > float(flow["ttl"])

    def _login_pre_info(self) -> None:
        token, _ = WORLD.create_login_flow()
        qr = (
            "https://open.weixin.qq.com/connect/qrconnect?appid=wxb60db2584bf82ac1"
            f"&redirect_uri=https%3A%2F%2Fwww.yuketang.cn%2Fapi%2Fv3%2Fuser%2Flogin%2Fwait-for-scan&state={token}"
        )
        return self._ok({"qrContent": qr, "token": token})

    def _login_wait(self, body: dict[str, Any]) -> None:
        token = str(body.get("token") or "")
        flow = WORLD.login_flows.get(token)
        if flow is None:
            return self._fail(50000, "二维码已失效")
        if self._is_flow_expired(flow) or flow["state"] == "expired":
            return self._fail(50001, "二维码已过期")
        if flow["state"] == "pending":
            return self._fail(40001, "等待扫码")
        if flow["state"] == "scanned":
            return self._ok({"scanned": True}, msg="已扫码，等待确认")
        if flow["state"] == "need_code":
            return self._fail(
                40006,
                "扫码成功，需要 4 位验证码",
                data={"verify_token": flow["verify_token"]},
            )
        if flow["state"] == "confirmed":
            return self._ok({"confirmed": True}, msg="已确认")
        return self._fail(50001, "二维码已过期")

    def _login_poll(self, body: dict[str, Any]) -> None:
        token = str(body.get("token") or "")
        flow = WORLD.login_flows.get(token)
        if flow is None:
            return self._fail(50000, "二维码已失效")
        if self._is_flow_expired(flow) or flow["state"] == "expired":
            return self._fail(50001, "二维码已过期")
        if flow["state"] == "need_code":
            return self._fail(
                40006,
                "扫码成功，需要 4 位验证码",
                data={"verify_token": flow["verify_token"]},
            )
        if flow["state"] == "scanned":
            return self._fail(40007, "已扫码，等待确认")
        if flow["state"] != "confirmed":
            return self._fail(40002, "等待扫码")

        uid = str(flow["user"] or "")
        user_name = WORLD.users.get(uid)
        if user_name is None:
            return self._fail(40003, "账号不存在")

        session_token = f"session-{uid}"
        csrf_token = f"csrf-{uid}"
        WORLD.sessions[session_token] = {"id": uid, "name": user_name, "csrf": csrf_token}
        return self._ok(
            {"id": uid, "name": user_name},
            msg="登录成功",
            headers=[
                ("set-auth", f"Bearer {session_token}"),
                ("Set-Cookie", f"sessionid={session_token}; Path=/; HttpOnly"),
                ("Set-Cookie", f"csrftoken={csrf_token}; Path=/"),
            ],
        )

    def _login_code(self, body: dict[str, Any]) -> None:
        raw_token = str(body.get("token") or "")
        code = str(body.get("code") or "")
        if len(code) != 4 or not code.isdigit():
            return self._fail(40004, "验证码格式错误")

        login_token = WORLD.verify_tokens.get(raw_token, raw_token)
        flow = WORLD.login_flows.get(login_token)
        if flow is None:
            return self._fail(50000, "二维码已失效")
        if self._is_flow_expired(flow) or flow["state"] == "expired":
            return self._fail(50001, "二维码已过期")
        expected_code = str(flow.get("expected_code") or "")
        if expected_code and code != expected_code:
            return self._fail(40004, "验证码错误")

        uid = str(flow.get("user") or f"u{code}")
        user_name = WORLD.users.get(uid) or f"验证码用户{code}"
        session_token = f"session-{uid}-{code}"
        csrf_token = f"csrf-{uid}-{code}"
        WORLD.sessions[session_token] = {"id": uid, "name": user_name, "csrf": csrf_token}
        flow["state"] = "confirmed"
        return self._ok(
            {"verified": True, "id": uid, "name": user_name},
            msg="登录成功",
            headers=[
                ("set-auth", f"Bearer {session_token}"),
                ("Set-Cookie", f"sessionid={session_token}; Path=/; HttpOnly"),
                ("Set-Cookie", f"csrftoken={csrf_token}; Path=/"),
            ],
        )

    def _pc_send_sms(self, body: dict[str, Any]) -> None:
        mobile = str(body.get("mobile") or "").strip()
        if not MAINLAND_PHONE_RE.fullmatch(mobile):
            return self._send(
                200,
                {"success": False, "status_code": 300402, "msg": "无效的手机号格式", "data": {}},
            )
        if "login" in body and body["login"] is not True:
            return self._send(
                200,
                {"success": False, "status_code": 300411, "msg": "错误的登录类型", "data": {}},
            )

        code = "123456"
        WORLD.sms_codes[mobile] = {
            "code": code,
            "issued": time.time(),
            "ttl": WORLD.login_ttl,
            "used": False,
        }
        return self._send(
            200,
            {
                "success": True,
                "msg": "验证码已发送",
                "data": {"mobile": mobile, "code": code},
            },
        )

    def _pc_verify_pwd_login(self, body: dict[str, Any]) -> None:
        login_type = str(body.get("type") or "").strip()
        if login_type != "PC":
            return self._send(
                200,
                {"success": False, "status_code": 300411, "msg": "错误的登录类型", "data": {}},
            )
        mobile = str(body.get("name") or "").strip()
        if not MAINLAND_PHONE_RE.fullmatch(mobile):
            return self._send(
                200,
                {"success": False, "status_code": 300402, "msg": "无效的手机号格式", "data": {}},
            )
        pwd = str(body.get("pwd") or "").strip()
        if not SMS_CODE_RE.fullmatch(pwd):
            return self._send(
                200,
                {"success": False, "status_code": 300405, "msg": "验证码错误", "data": {}},
            )

        record = WORLD.sms_codes.get(mobile)
        if record is None or record.get("used"):
            return self._send(
                200,
                {"success": False, "status_code": 300404, "msg": "验证码已过期或已被使用", "data": {}},
            )
        if (time.time() - float(record["issued"])) > float(record["ttl"]):
            return self._send(
                200,
                {"success": False, "status_code": 300404, "msg": "验证码已过期或已被使用", "data": {}},
            )
        if pwd != str(record["code"]):
            return self._send(
                200,
                {"success": False, "status_code": 300405, "msg": "验证码错误", "data": {}},
            )

        record["used"] = True
        WORLD._sms_seq += 1
        suffix4 = mobile[-4:]
        uid = f"phone-{suffix4}"
        user_name = WORLD.users.get(uid) or f"演练用户({suffix4})"
        WORLD.users[uid] = user_name
        session_id = f"sms-sid-{suffix4}-{WORLD._sms_seq:04d}"
        csrf_token = f"sms-csrf-{suffix4}-{WORLD._sms_seq:04d}"
        WORLD.sessions[session_id] = {"id": uid, "name": user_name, "csrf": csrf_token}
        return self._send(
            200,
            {"success": True, "msg": "", "data": {"id": uid, "name": user_name}},
            headers=[
                ("Set-Cookie", f"sessionid={session_id}; Path=/; HttpOnly"),
                ("Set-Cookie", f"csrftoken={csrf_token}; Path=/"),
            ],
        )

    def _basic_info(self) -> None:
        user, _, err, status = self._authenticate(require_csrf=False)
        if user is None:
            return self._fail(40100 if status == 401 else 40301, err or "未登录", status=status)
        return self._ok(
            {
                "id": user["id"],
                "name": user["name"],
                "universityId": 1,
                "identityId": 1,
            }
        )

    # ------------------------------------------------------------------ 课堂

    def _active_lesson(self) -> None:
        user, _, err, status = self._authenticate(require_csrf=False)
        if user is None:
            return self._fail(40100 if status == 401 else 40301, err or "未登录", status=status)
        return self._ok(
            {
                "onLessonClassrooms": [
                    {
                        "lessonId": WORLD.lesson_id,
                        "classroomId": WORLD.classroom_id,
                        "courseName": WORLD.lesson_name,
                        "lessonName": WORLD.lesson_name,
                    }
                ]
            }
        )

    def _checkin_list(self, query: dict[str, list[str]]) -> None:
        user, _, err, status = self._authenticate(require_csrf=False)
        if user is None:
            return self._fail(40100 if status == 401 else 40301, err or "未登录", status=status)
        lesson_id = (query.get("lesson_id") or query.get("lessonId") or [""])[0]
        if lesson_id != WORLD.lesson_id:
            return self._fail(40001, "课堂不存在")
        return self._ok(
            {
                "activities": [
                    {
                        "checkinId": "ck-0001",
                        "lessonId": WORLD.lesson_id,
                        "checkinType": 0,
                        "createdAt": int(time.time()),
                    }
                ]
            }
        )

    def _checkin_detail(self, query: dict[str, list[str]]) -> None:
        user, _, err, status = self._authenticate(require_csrf=False)
        if user is None:
            return self._fail(40100 if status == 401 else 40301, err or "未登录", status=status)
        return self._ok(
            {
                "checkinId": (query.get("checkinId") or [""])[0],
                "lessonId": WORLD.lesson_id,
                "classroomId": WORLD.classroom_id,
            }
        )

    def _lesson_basic(self, query: dict[str, list[str]]) -> None:
        user, _, err, status = self._authenticate(require_csrf=False)
        if user is None:
            return self._fail(40100 if status == 401 else 40301, err or "未登录", status=status)
        lesson_id = (query.get("lesson_id") or query.get("lessonId") or [""])[0]
        if lesson_id and lesson_id != WORLD.lesson_id:
            return self._fail(40001, "课堂不存在")
        return self._ok(
            {
                "lessonId": WORLD.lesson_id,
                "classroomId": WORLD.classroom_id,
                "title": WORLD.lesson_name,
            }
        )

    # ------------------------------------------------------------------ 签到

    def _checkin(self, body: dict[str, Any]) -> None:
        user, auth_mode, err, status = self._authenticate(require_csrf=True)
        if user is None:
            return self._fail(40100 if status == 401 else 40301, err or "未登录", status=status)

        lesson_id = str(body.get("lessonId") or "")
        if lesson_id != WORLD.lesson_id:
            return self._fail(40001, "课堂不存在")

        source = body.get("source")
        if not isinstance(source, int) or isinstance(source, bool):
            WORLD.checkin_stats["rejected"] += 1
            return self._fail(40006, "source 必须为整数", status=400)

        WORLD.checkin_stats["total"] += 1
        src_key = str(source)
        WORLD.checkin_stats["bySource"][src_key] = WORLD.checkin_stats["bySource"].get(src_key, 0) + 1

        ticket_code = str(body.get("ticket") or "").strip()
        ts_val = str(body.get("t") or "").strip()
        signature = str(body.get("s") or "").strip()

        if WORLD.require_ticket:
            if not ticket_code or not ts_val or not signature:
                WORLD.checkin_stats["rejected"] += 1
                return self._fail(40002, "动态签到必须同时提供完整的 ticket/t/s 参数")
            ticket = WORLD.tickets.get(ticket_code)
            if ticket is None:
                WORLD.checkin_stats["rejected"] += 1
                return self._fail(40002, "动态二维码无效")
            if time.time() - float(ticket["issued"]) > float(ticket["ttl"]):
                WORLD.checkin_stats["rejected"] += 1
                return self._fail(40003, "二维码已失效")
            if ts_val != ticket["t"] or signature != ticket["s"]:
                WORLD.checkin_stats["rejected"] += 1
                return self._fail(40005, "动态二维码签名校验失败")

        if WORLD.reject_source_14 and source == 14:
            WORLD.checkin_stats["rejected"] += 1
            return self._fail(40014, "当前课堂不支持 source=14，请换渠道")

        refresh_headers = WORLD.issue_refreshed_session(user) if WORLD.refresh_session else None

        if user["id"] in WORLD.attendance:
            WORLD.checkin_stats["already"] += 1
            return self._ok({"signed": True, "already": True}, msg="已签到", headers=refresh_headers)

        WORLD.attendance[user["id"]] = {
            "user": user["id"],
            "name": user["name"],
            "at": time.time(),
            "via": "ticket" if ticket_code else "lesson",
            "source": source,
            "authMode": auth_mode,
            "lessonId": lesson_id,
        }
        WORLD.checkin_stats["accepted"] += 1
        return self._ok({"signed": True}, msg="签到成功", headers=refresh_headers)

    # ------------------------------------------------------------------ 管理

    def _admin_scan(self, body: dict[str, Any]) -> None:
        token = str(body.get("token") or "")
        user = str(body.get("user") or "u1001")
        mode = str(body.get("mode") or "confirmed").strip().lower()
        if mode not in {"confirmed", "scanned", "need_code", "expired"}:
            return self._fail(40008, f"不支持的 mode: {mode}", status=400)

        flow = WORLD.login_flows.get(token)
        if flow is None:
            return self._fail(50000, "登录 token 不存在")
        if self._is_flow_expired(flow) and mode != "expired":
            return self._fail(50001, "登录二维码已过期")

        flow["state"] = mode
        flow["user"] = user
        resp: dict[str, Any] = {"token": token, "user": user, "state": mode}
        if mode == "need_code":
            verify_token = f"verify-{uuid.uuid4().hex[:8]}"
            flow["verify_token"] = verify_token
            flow["expected_code"] = str(body.get("code") or "")
            WORLD.verify_tokens[verify_token] = token
            resp["verifyToken"] = verify_token
        elif mode == "expired":
            flow["ttl"] = -1.0
        return self._ok(resp)

    def _world_state(self) -> dict[str, Any]:
        return {
            "lessonId": WORLD.lesson_id,
            "classroomId": WORLD.classroom_id,
            "lessonName": WORLD.lesson_name,
            "requireTicket": WORLD.require_ticket,
            "rejectSource14": WORLD.reject_source_14,
            "strictHeaders": WORLD.strict_headers,
            "strictCsrf": WORLD.strict_csrf,
            "refreshSession": WORLD.refresh_session,
            "attendance": sorted(WORLD.attendance.keys()),
            "attendanceCount": len(WORLD.attendance),
            "users": WORLD.users,
            "sessions": len(WORLD.sessions),
            "totalRequests": WORLD.total_requests,
            "pathCounts": dict(WORLD.path_counts),
            "checkinStats": {
                "total": WORLD.checkin_stats["total"],
                "bySource": dict(WORLD.checkin_stats["bySource"]),
                "accepted": WORLD.checkin_stats["accepted"],
                "already": WORLD.checkin_stats["already"],
                "rejected": WORLD.checkin_stats["rejected"],
            },
            "requests": WORLD.requests[-30:],
        }


def main() -> None:
    parser = argparse.ArgumentParser(description="RainCheck mock server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--require-ticket", action="store_true", help="强制要求完整且未过期的动态二维码 ticket/t/s")
    parser.add_argument("--reject-source-14", action="store_true", help="拒绝 source=14 以触发策略链回退到 source=5")
    parser.add_argument(
        "--strict-headers",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="校验业务接口关键请求头（默认开启）",
    )
    parser.add_argument(
        "--strict-csrf",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Cookie 鉴权的非 GET 请求强制校验 X-CSRFToken（默认开启）",
    )
    parser.add_argument(
        "--refresh-session",
        action="store_true",
        help="签到响应中下发新的 set-auth 与 Set-Cookie 供验证会话回填",
    )
    parser.add_argument("--ticket-ttl", type=float, default=8.0, help="动态二维码默认有效期（秒）")
    parser.add_argument("--login-ttl", type=float, default=120.0, help="登录二维码默认有效期（秒）")
    parser.add_argument("--reset-every", type=float, default=0.0, help="每隔 N 秒重置世界（压测用）")
    args = parser.parse_args()

    WORLD.configure_defaults(
        require_ticket=args.require_ticket,
        reject_source_14=args.reject_source_14,
        strict_headers=args.strict_headers,
        strict_csrf=args.strict_csrf,
        refresh_session=args.refresh_session,
        ticket_ttl=args.ticket_ttl,
        login_ttl=args.login_ttl,
    )
    server = QuietThreadingHTTPServer((args.host, args.port), Handler)
    print(
        f"RainCheck mock server on http://{args.host}:{args.port} "
        f"(require_ticket={WORLD.require_ticket}, reject_source_14={WORLD.reject_source_14}, "
        f"strict_headers={WORLD.strict_headers}, refresh_session={WORLD.refresh_session})",
        flush=True,
    )

    if args.reset_every > 0:
        def looper() -> None:
            while True:
                time.sleep(args.reset_every)
                with STATE_LOCK:
                    WORLD.reset()

        threading.Thread(target=looper, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
