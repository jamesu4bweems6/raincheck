#!/usr/bin/env python3
r"""端到端全场景演练：本地 mock server + CLI 多账号并发签到与登录闭环。

验证内容：
  0. mock_server 协议严格性自检（非法 JSON 400、缺业务 Header 400、缺签名 s 拒绝、Cookie POST 缺 CSRF 403）；
  1. 8 账号并发签到（含 Bearer 与 Cookie+CSRF 双载体），开启 --require-ticket --reject-source-14 --refresh-session：
     - 严格断言 POST /api/v3/lesson/checkin == 16 次（8 账号 × 2 策略，真实触发策略链回退）；
     - 预置 u1001 已签到，严格断言结果分布 SUCCESS == 7 且 ALREADY == 1；
     - 断言响应头 set-auth / Set-Cookie 会话回填落盘且新凭据通过 basic-info 校验；
  2. 401 过期/无效凭据账号严格判定 AUTH_REQUIRED；
  3. 过期二维码立即中止策略链（TICKET_EXPIRED，仅发 1 次 checkin 请求）；
  4. --dry-run 严格零网络请求（mock /api/* 请求数零增长，状态 DRY_RUN）；
  5. 完整扫码登录链（pre-info -> admin/scan(scanned -> confirmed) -> poll -> basic-info）
     与 4 位验证码登录链（need_code -> login-with-code -> basic-info）。

用法（在 raincheck 目录下）：
    python tools/demo.py                # 自动启动 mock server（日志写临时目录）
    python tools/demo.py --no-server    # 复用已启动服务
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
BASE = "http://127.0.0.1:8787"
ACCOUNTS = [f"u100{i}" for i in range(1, 9)]


def http_raw(
    method: str,
    path: str,
    raw_body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 15.0,
) -> tuple[int, dict[str, Any], dict[str, str]]:
    req = urllib.request.Request(
        BASE + path,
        data=raw_body,
        method=method,
        headers=headers or {},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(text) if text else {}, dict(resp.headers.items())
    except urllib.error.HTTPError as err:
        text = err.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text) if text else {}
        except Exception:
            parsed = {"raw": text}
        return err.code, parsed, dict(err.headers.items())


def http(method: str, path: str, payload: dict[str, Any] | None = None, timeout: float = 15.0) -> dict[str, Any]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"} if data is not None else {}
    status, body, _ = http_raw(method, path, data, headers=headers, timeout=timeout)
    if status >= 400:
        raise RuntimeError(f"HTTP {status} {method} {path}: {body}")
    return body


def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def wait_health(server: subprocess.Popen[str] | None, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if server is not None and server.poll() is not None:
            return False
        try:
            res = http("GET", "/health", timeout=2.0)
            if res.get("code") == 0:
                return True
        except Exception:
            time.sleep(0.25)
    return False


def cli_path() -> Path:
    exe_dir = ROOT / "cli" / "build" / "install" / "cli" / "bin"
    candidates = ("cli.bat", "cli") if os.name == "nt" else ("cli",)
    for name in candidates:
        candidate = exe_dir / name
        if candidate.exists():
            if os.name != "nt" and not os.access(candidate, os.X_OK):
                os.chmod(candidate, candidate.stat().st_mode | 0o111)
            return candidate
    hint = r".\gradlew.bat :cli:installDist" if os.name == "nt" else "./gradlew :cli:installDist"
    raise SystemExit(f"找不到 CLI 可执行文件（{exe_dir}），请先运行: {hint}")


def build_cli_cmd(args: list[str], store: Path, profile_path: Path | None = None) -> list[str]:
    cmd = [str(cli_path()), *args, "--store", str(store)]
    if profile_path is not None:
        cmd.extend(["--profile", str(profile_path)])
    return cmd


def run_cli(
    args: list[str],
    store: Path,
    *,
    profile_path: Path | None = None,
    expect_rc: int | None = 0,
    timeout: float = 60.0,
) -> subprocess.CompletedProcess[str]:
    cmd = build_cli_cmd(args, store, profile_path)
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )
    if expect_rc is not None and proc.returncode != expect_rc:
        raise AssertionError(
            f"CLI 命令退出码不符合预期: expected={expect_rc}, actual={proc.returncode}\n"
            f"cmd: {' '.join(cmd)}\n"
            f"stdout:\n{proc.stdout}\n"
            f"stderr:\n{proc.stderr}"
        )
    return proc


def api_request_count(state: dict[str, Any]) -> int:
    path_counts: dict[str, int] = state.get("pathCounts") or {}
    return sum(count for key, count in path_counts.items() if " /api/" in key)


def verify_mock_strictness() -> None:
    print("[0/6] 校验 mock_server 协议严格性...")
    biz_headers = {
        "Content-Type": "application/json",
        "xtbz": "ykt",
        "X-Client": "desktop",
        "Authorization": "Bearer token-u1001",
    }

    # 1) 非法 JSON -> HTTP 400
    status, body, _ = http_raw("POST", "/api/v3/lesson/checkin", b"{bad-json", headers=biz_headers)
    assert status == 400, f"非法 JSON 应返回 400，实际 {status}: {body}"

    # 2) 缺失关键 Header (xtbz / X-Client) -> HTTP 400
    status, body, _ = http_raw(
        "GET",
        "/api/v3/user/basic-info",
        headers={"Authorization": "Bearer token-u1001"},
    )
    assert status == 400, f"缺失业务 Header 应返回 400，实际 {status}: {body}"

    # 3) --require-ticket 下省略签名 s -> 必拒
    qr_info = http("GET", "/admin/qr")["data"]
    state = http("GET", "/admin/state")["data"]
    payload_no_sig = json.dumps(
        {
            "lessonId": state["lessonId"],
            "source": 5,
            "ticket": qr_info["c"],
            "t": qr_info["t"],
        }
    ).encode("utf-8")
    status, body, _ = http_raw("POST", "/api/v3/lesson/checkin", payload_no_sig, headers=biz_headers)
    assert body.get("code") != 0, f"省略签名 s 必须被拒绝，实际 {status}: {body}"

    # 4) Cookie 鉴权 POST 缺少 X-CSRFToken -> HTTP 403
    cookie_no_csrf = {
        "Content-Type": "application/json",
        "xtbz": "ykt",
        "X-Client": "desktop",
        "Cookie": "sessionid=sid-u1002; csrftoken=csrf-u1002",
    }
    payload_ok = json.dumps(
        {
            "lessonId": state["lessonId"],
            "source": 5,
            "ticket": qr_info["c"],
            "t": qr_info["t"],
            "s": qr_info["s"],
        }
    ).encode("utf-8")
    status, body, _ = http_raw("POST", "/api/v3/lesson/checkin", payload_ok, headers=cookie_no_csrf)
    assert status == 403, f"Cookie POST 缺 X-CSRFToken 应返回 403，实际 {status}: {body}"
    print("  -> OK（非法 JSON / 缺 Header / 缺签名 s / 缺 CSRF 均严格拦截）")


def run_cli_login_flow(
    *,
    port: int,
    tmp: Path,
    profile_path: Path | None,
    label: str,
    user: str,
    expected_name: str,
    mode: str,
    verify_code: str | None = None,
) -> None:
    store = tmp / f"login_{mode}_{user}.json"
    cmd = build_cli_cmd(
        [
            "login",
            "--host", f"127.0.0.1:{port}",
            "--label", label,
            "--timeout", "20000",
        ],
        store,
        profile_path,
    )
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    lines: list[str] = []
    token_holder: dict[str, str] = {}
    token_found = threading.Event()

    def reader() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            lines.append(line)
            if "state=" in line and "token" not in token_holder:
                m = re.search(r"state=([A-Za-z0-9._-]+)", line)
                if m:
                    token_holder["token"] = m.group(1)
                    token_found.set()

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    try:
        if not token_found.wait(timeout=15.0):
            proc.kill()
            stderr_text = proc.stderr.read() if proc.stderr else ""
            raise AssertionError(
                f"login 未输出含 state=<token> 的二维码内容\nstdout:\n{''.join(lines)}\nstderr:\n{stderr_text}"
            )

        login_token = token_holder["token"]
        if mode == "confirmed":
            # 先模拟已扫码（SCANNED），再模拟确认（CONFIRMED）
            http("POST", "/admin/scan", {"token": login_token, "user": user, "mode": "scanned"})
            time.sleep(0.35)
            http("POST", "/admin/scan", {"token": login_token, "user": user, "mode": "confirmed"})
        elif mode == "need_code":
            assert verify_code is not None
            http("POST", "/admin/scan", {"token": login_token, "user": user, "mode": "need_code", "code": verify_code})
            assert proc.stdin is not None
            proc.stdin.write(f"{verify_code}\n")
            proc.stdin.flush()
            proc.stdin.close()
        else:
            raise ValueError(f"unsupported mode: {mode}")

        rc = proc.wait(timeout=20.0)
        t.join(timeout=2.0)
        stderr_text = proc.stderr.read() if proc.stderr else ""
        stdout_text = "".join(lines)
        assert rc == 0, f"cli login ({mode}) 失败 rc={rc}\nstdout:\n{stdout_text}\nstderr:\n{stderr_text}"
    finally:
        if proc.poll() is None:
            proc.kill()

    saved = json.loads(store.read_text(encoding="utf-8"))
    assert len(saved) == 1, f"login ({mode}) 应写入 1 个账号，实际 {len(saved)}"
    acct = saved[0]
    assert acct.get("userId") == user, f"login ({mode}) 未通过 basic-info 写入 userId={user}: {acct}"
    assert acct.get("bearer", "").startswith("session-"), f"login ({mode}) 未回填 bearer: {acct}"
    assert acct.get("sessionId", "").startswith("session-"), f"login ({mode}) 未回填 sessionId: {acct}"

    # 用刚登录落盘的账号再次调 basic-info 验证会话真实有效
    probe = run_cli(
        ["probe", "--method", "GET", "--path", "/api/v3/user/basic-info", "--id", acct["id"]],
        store,
        profile_path=profile_path,
        expect_rc=0,
    )
    assert expected_name in probe.stdout and user in probe.stdout, (
        f"login ({mode}) 后 basic-info 校验未返回预期用户 {user}/{expected_name}:\n{probe.stdout}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="RainCheck 端到端全场景验证")
    parser.add_argument("--no-server", action="store_true", help="复用已启动的 mock server")
    parser.add_argument("--port", type=int, default=8787, help="mock server 端口（默认 8787）")
    args = parser.parse_args()

    global BASE
    BASE = f"http://127.0.0.1:{args.port}"

    tmp = Path(tempfile.mkdtemp(prefix="raincheck-demo-"))
    log_path = tmp / "mock-server.log"
    server: subprocess.Popen[str] | None = None
    log_file = None

    try:
        # 若使用非默认端口，生成临时 profile 覆盖 mock edition 的端口；默认 8787 直接使用内置 profile
        profile_override: Path | None = None
        if args.port != 8787:
            prof = json.loads((ROOT / "protocol" / "profile.json").read_text(encoding="utf-8"))
            for ed in prof.get("editions", []):
                if ed.get("id") == "mock":
                    ed["host"] = f"127.0.0.1:{args.port}"
                    ed["scheme"] = "http"
            allowed_hosts = prof.setdefault("qr", {}).setdefault("allowedUrlHosts", [])
            custom_host = f"127.0.0.1:{args.port}"
            if custom_host not in allowed_hosts:
                allowed_hosts.append(custom_host)
            profile_override = tmp / "profile.json"
            profile_override.write_text(json.dumps(prof, ensure_ascii=False, indent=2), encoding="utf-8")

        if not args.no_server:
            if port_in_use(args.port):
                print(f"[FAIL] 端口 127.0.0.1:{args.port} 已被占用，拒绝假通过（请关闭旧进程或改用 --port）")
                return 2
            log_file = open(log_path, "w", encoding="utf-8")
            server = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "tools" / "mock_server.py"),
                    "--port", str(args.port),
                    "--require-ticket",
                    "--reject-source-14",
                    "--strict-headers",
                    "--strict-csrf",
                    "--refresh-session",
                ],
                stdout=log_file,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
            )

        if not wait_health(server):
            print("[FAIL] mock server 未就绪或启动退出")
            if log_file is not None:
                log_file.flush()
            if log_path.exists():
                print(log_path.read_text(encoding="utf-8", errors="replace"))
            return 2

        # 0) 严格性自检
        http("POST", "/admin/reset", {
            "requireTicket": True,
            "rejectSource14": True,
            "strictHeaders": True,
            "strictCsrf": True,
            "refreshSession": True,
        })
        verify_mock_strictness()

        # 1) 8 账号并发签到 + 策略链真实回退 + Cookie+CSRF + ALREADY 严格区分 + 会话回填
        print("\n[1/6] 8 账号并发签到（require_ticket + reject_source_14 + Cookie/CSRF + 会话回填）...")
        http("POST", "/admin/reset", {
            "requireTicket": True,
            "rejectSource14": True,
            "strictHeaders": True,
            "strictCsrf": True,
            "refreshSession": True,
        })
        http("POST", "/admin/attend", {"user": ACCOUNTS[0]})  # 预签到 u1001

        store = tmp / "accounts.json"
        # u1001: Bearer 鉴权导入
        run_cli(
            [
                "accounts", "import",
                "--label", f"账号1-{ACCOUNTS[0]}",
                "--token", f"token-{ACCOUNTS[0]}",
                "--host", f"127.0.0.1:{args.port}",
                "--scheme", "http",
            ],
            store,
            profile_path=profile_override,
            expect_rc=0,
        )
        # u1002: Cookie + CSRF 鉴权导入（验证双载体）
        run_cli(
            [
                "accounts", "import",
                "--label", f"账号2-{ACCOUNTS[1]}",
                "--sessionid", f"sid-{ACCOUNTS[1]}",
                "--csrf", f"csrf-{ACCOUNTS[1]}",
                "--host", f"127.0.0.1:{args.port}",
                "--scheme", "http",
            ],
            store,
            profile_path=profile_override,
            expect_rc=0,
        )

        # u1003..u1008 批量写入同一账号池 JSON，避免 6 次重复 JVM 启动
        accounts = json.loads(store.read_text(encoding="utf-8"))
        bearer_template = dict(accounts[0])
        for idx, uid in enumerate(ACCOUNTS[2:], start=3):
            item = dict(bearer_template)
            item.update(
                {
                    "id": f"demo-{uid}",
                    "label": f"账号{idx}-{uid}",
                    "bearer": f"token-{uid}",
                    "sessionId": None,
                    "csrfToken": None,
                }
            )
            accounts.append(item)
        store.write_text(json.dumps(accounts, ensure_ascii=False, indent=2), encoding="utf-8")

        listed = run_cli(["accounts", "list"], store, profile_path=profile_override, expect_rc=0)
        print(listed.stdout.strip())

        qr = http("GET", "/admin/qr")["data"]["qr"]
        print(f"动态二维码: {qr}")

        report_path = tmp / "report.json"
        qr_file = tmp / "qr.txt"
        qr_file.write_text(qr, encoding="utf-8")

        started = time.time()
        signin_res = run_cli(
            ["signin", "--qr", f"@{qr_file}", "--concurrency", "8", "--json", str(report_path)],
            store,
            profile_path=profile_override,
            expect_rc=0,
        )
        elapsed = time.time() - started
        print(signin_res.stdout.strip())
        if signin_res.stderr.strip():
            print("[stderr]", signin_res.stderr.strip())

        state = http("GET", "/admin/state")["data"]
        checkin_posts = state["pathCounts"].get("POST /api/v3/lesson/checkin", 0)
        by_source = state["checkinStats"]["bySource"]
        print(
            f"mock 端考勤: {state['attendanceCount']} 人 | "
            f"POST checkin={checkin_posts} (source=14: {by_source.get('14', 0)}, source=5: {by_source.get('5', 0)}) | "
            f"耗时 {elapsed:.2f}s"
        )

        assert checkin_posts == 16, f"预期 POST /api/v3/lesson/checkin == 16（8账号×2策略），实际 {checkin_posts}"
        assert by_source.get("14") == 8 and by_source.get("5") == 8, (
            f"策略回退计数不符预期（应为 source=14×8 且 source=5×8），实际 {by_source}"
        )
        assert set(ACCOUNTS).issubset(set(state["attendance"])), f"考勤人数不全: {state['attendance']}"

        detail = json.loads(report_path.read_text(encoding="utf-8"))
        results = detail.get("results") or []
        states: dict[str, int] = {}
        for item in results:
            states[item["state"]] = states.get(item["state"], 0) + 1
        print(f"结果分布: {states}")

        assert len(results) == 8, f"预期 8 条结果，实际 {len(results)}"
        assert states.get("SUCCESS", 0) == 7 and states.get("ALREADY", 0) == 1, (
            f"预期严格分布 SUCCESS==7 且 ALREADY==1，实际 {states}"
        )
        for item in results:
            assert item["strategy"] == "DYN_TICKET_5", f"应回退到 DYN_TICKET_5 成功，实际 {item}"
            assert len(item["attempts"]) == 2, f"每账号应有 2 次策略尝试，实际 {len(item['attempts'])}"

        # 验证响应头会话回填落盘且新凭据真实可用
        refreshed_accounts = json.loads(store.read_text(encoding="utf-8"))
        for acct in refreshed_accounts:
            assert str(acct.get("bearer") or "").startswith("refreshed-"), f"账号未回填 set-auth: {acct}"
            assert str(acct.get("sessionId") or "").startswith("refreshed-"), f"账号未回填 Set-Cookie sessionid: {acct}"
            assert str(acct.get("csrfToken") or "").startswith("csrf-"), f"账号未回填 Set-Cookie csrftoken: {acct}"

        cookie_acct_id = refreshed_accounts[1]["id"]
        probe_res = run_cli(
            ["probe", "--method", "GET", "--path", "/api/v3/user/basic-info", "--id", cookie_acct_id],
            store,
            profile_path=profile_override,
            expect_rc=0,
        )
        assert "u1002" in probe_res.stdout and "李四" in probe_res.stdout, (
            f"会话回填后 basic-info 校验失败:\n{probe_res.stdout}"
        )
        print("  -> OK（16 次策略回退、7 SUCCESS + 1 ALREADY、Cookie+CSRF 与会话回填全部实证）")

        # 2) 401 过期账号判定 AUTH_REQUIRED
        print("\n[2/6] 验证 401 过期账号 -> AUTH_REQUIRED...")
        store_401 = tmp / "accounts_401.json"
        run_cli(
            [
                "accounts", "import",
                "--label", "过期账号",
                "--token", "expired-invalid-token",
                "--host", f"127.0.0.1:{args.port}",
                "--scheme", "http",
            ],
            store_401,
            profile_path=profile_override,
            expect_rc=0,
        )
        qr_401 = tmp / "qr_401.txt"
        qr_401.write_text(http("GET", "/admin/qr")["data"]["qr"], encoding="utf-8")
        report_401 = tmp / "report_401.json"
        run_cli(
            ["signin", "--qr", f"@{qr_401}", "--json", str(report_401)],
            store_401,
            profile_path=profile_override,
            expect_rc=1,
        )
        res_401 = json.loads(report_401.read_text(encoding="utf-8"))["results"]
        assert len(res_401) == 1 and res_401[0]["state"] == "AUTH_REQUIRED", f"预期 AUTH_REQUIRED，实际 {res_401}"
        print("  -> OK（AUTH_REQUIRED 精准识别并终止）")

        # 3) 过期二维码立即中止策略链 -> TICKET_EXPIRED
        print("\n[3/6] 验证过期二维码立即中止策略链 -> TICKET_EXPIRED...")
        before_exp = http("GET", "/admin/state")["data"]["pathCounts"].get("POST /api/v3/lesson/checkin", 0)
        expired_qr = http("POST", "/admin/ticket", {"ttl": -1})["data"]["qr"]
        qr_exp_file = tmp / "qr_expired.txt"
        qr_exp_file.write_text(expired_qr, encoding="utf-8")
        report_exp = tmp / "report_expired.json"
        run_cli(
            [
                "signin",
                "--qr", f"@{qr_exp_file}",
                "--only", f"账号1-{ACCOUNTS[0]}",
                "--json", str(report_exp),
            ],
            store,
            profile_path=profile_override,
            expect_rc=1,
        )
        after_exp = http("GET", "/admin/state")["data"]["pathCounts"].get("POST /api/v3/lesson/checkin", 0)
        res_exp = json.loads(report_exp.read_text(encoding="utf-8"))["results"]
        assert len(res_exp) == 1 and res_exp[0]["state"] == "TICKET_EXPIRED", f"预期 TICKET_EXPIRED，实际 {res_exp}"
        assert after_exp - before_exp == 1, (
            f"过期二维码应在第 1 策略立即中止（增量=1），实际增量={after_exp - before_exp}"
        )
        print("  -> OK（TICKET_EXPIRED 在第 1 次尝试即中止策略链）")

        # 4) --dry-run 严格零网络请求
        print("\n[4/6] 验证 --dry-run 零网络请求...")
        api_before_dry = api_request_count(http("GET", "/admin/state")["data"])
        report_dry = tmp / "report_dry.json"
        run_cli(
            ["signin", "--qr", f"@{qr_file}", "--dry-run", "--concurrency", "8", "--json", str(report_dry)],
            store,
            profile_path=profile_override,
            expect_rc=0,
        )
        api_after_dry = api_request_count(http("GET", "/admin/state")["data"])
        assert api_after_dry == api_before_dry, (
            f"--dry-run 不得发出任何 /api/* 请求（before={api_before_dry}, after={api_after_dry}）"
        )
        res_dry = json.loads(report_dry.read_text(encoding="utf-8"))["results"]
        assert len(res_dry) == 8, f"dry-run 应返回 8 条记录，实际 {len(res_dry)}"
        assert all(r["state"] == "DRY_RUN" and len(r["attempts"]) >= 1 for r in res_dry), (
            f"dry-run 状态或轨迹异常: {[r['state'] for r in res_dry]}"
        )
        print("  -> OK（/api/* 请求增量 0，全部 8 账号输出 DRY_RUN 轨迹）")

        # 5) 完整扫码登录链（pre-info -> admin/scan(scanned -> confirmed) -> poll -> basic-info）
        print("\n[5/6] 验证完整扫码登录链（scanned -> confirmed -> basic-info）...")
        run_cli_login_flow(
            port=args.port,
            tmp=tmp,
            profile_path=profile_override,
            label="扫码测试-u1003",
            user="u1003",
            expected_name="王五",
            mode="confirmed",
        )
        print("  -> OK（pre-info -> scanned -> confirmed -> set-auth/Set-Cookie -> basic-info 200）")

        # 6) 4 位验证码登录链（need_code -> login-with-code -> basic-info）
        print("\n[6/6] 验证 4 位验证码登录链（need_code -> login-with-code -> basic-info）...")
        run_cli_login_flow(
            port=args.port,
            tmp=tmp,
            profile_path=profile_override,
            label="验证码测试-u1004",
            user="u1004",
            expected_name="赵六",
            mode="need_code",
            verify_code="2468",
        )
        print("  -> OK（need_code -> login-with-code -> set-auth/Set-Cookie -> basic-info 200）")

        # 确认 mock server 日志中无未捕获异常堆栈
        if log_file is not None:
            log_file.flush()
        if log_path.exists():
            server_log = log_path.read_text(encoding="utf-8", errors="replace")
            assert "Traceback (most recent call last)" not in server_log, (
                f"mock server 日志出现未捕获异常堆栈:\n{server_log[-2000:]}"
            )

        print("\n[PASS] 全部 6 组端到端场景（策略回退 / 严格 ALREADY / Cookie+CSRF / 401 / 过期中止 / 零请求 dry-run / 扫码与验证码登录 / 会话回填）验证通过")
        return 0
    except AssertionError as exc:
        print(f"\n[FAIL] 断言失败: {exc}")
        if log_file is not None:
            log_file.flush()
        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace").strip()
            if text:
                print("\n--- mock_server log (tail) ---\n" + text[-2000:])
        return 1
    except Exception as exc:
        print(f"\n[FAIL] 运行异常: {exc}")
        if log_file is not None:
            log_file.flush()
        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace").strip()
            if text:
                print("\n--- mock_server log (tail) ---\n" + text[-2000:])
        return 2
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
        if log_file is not None:
            log_file.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
