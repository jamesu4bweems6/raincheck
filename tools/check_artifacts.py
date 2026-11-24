#!/usr/bin/env python3
"""RainCheck 产物、协议一致性、测试报告与 iOS 工程结构校验工具（零第三方依赖）。"""
from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from typing import Any

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

APK_SIG_BLOCK_MAGIC = b"APK Sig Block 42"
EOCD_SIGNATURE = b"PK\x05\x06"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


# ------------------------------------------------------------------ 1. 协议同步校验


def cmd_profile_sync(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    master = root / "protocol" / "profile.json"
    if not master.is_file():
        print(f"[FAIL] 缺少主协议文件: {master}")
        return 1
    expected_hash = sha256_file(master)
    print(f"master protocol/profile.json sha256={expected_hash}")

    targets: list[tuple[str, str]] = []
    for rel in (
        "androidApp/src/main/assets/protocol_profile.json",
        "iosApp/Resources/protocol_profile.json",
    ):
        p = root / rel
        if not p.is_file():
            print(f"[FAIL] 缺少协议副本: {rel}")
            return 1
        actual = sha256_file(p)
        targets.append((rel, actual))
        if actual != expected_hash:
            print(f"[FAIL] 协议漂移: {rel} sha256={actual} != {expected_hash}")
            return 1

    if args.check_cli_jar:
        lib_dir = root / "cli" / "build" / "install" / "cli" / "lib"
        if not lib_dir.is_dir():
            print(f"[FAIL] 未找到 CLI lib 目录: {lib_dir}（请先执行 :cli:installDist）")
            return 1
        cli_jars = sorted(lib_dir.glob("cli*.jar"))
        matched_jar: Path | None = None
        embedded_hash: str | None = None
        for jar in cli_jars:
            with zipfile.ZipFile(jar) as zf:
                if "profile.json" in zf.namelist():
                    matched_jar = jar
                    embedded_hash = sha256_bytes(zf.read("profile.json"))
                    break
        if matched_jar is None or embedded_hash is None:
            print(f"[FAIL] 在 {lib_dir}/cli*.jar 中未找到内嵌 profile.json")
            return 1
        rel_jar = f"{matched_jar.relative_to(root)}::profile.json"
        targets.append((rel_jar, embedded_hash))
        if embedded_hash != expected_hash:
            print(f"[FAIL] CLI jar 内嵌协议不一致: {rel_jar} sha256={embedded_hash} != {expected_hash}")
            return 1

    for apk_arg in args.apk or []:
        apk_path = Path(apk_arg)
        if not apk_path.is_absolute():
            apk_path = (root / apk_path).resolve()
        if not apk_path.is_file():
            print(f"[FAIL] 找不到 APK: {apk_path}")
            return 1
        with zipfile.ZipFile(apk_path) as zf:
            if "assets/protocol_profile.json" not in zf.namelist():
                print(f"[FAIL] APK 缺少 assets/protocol_profile.json: {apk_path}")
                return 1
            actual = sha256_bytes(zf.read("assets/protocol_profile.json"))
        label = f"{apk_path.name}::assets/protocol_profile.json"
        targets.append((label, actual))
        if actual != expected_hash:
            print(f"[FAIL] APK 内嵌协议不一致: {label} sha256={actual} != {expected_hash}")
            return 1

    for label, digest in targets:
        print(f"  OK  {label} ({digest[:16]}...)")
    return 0


# ------------------------------------------------------------------ 2. JUnit XML 单测断言


def cmd_junit_xml(args: argparse.Namespace) -> int:
    xml_dir = Path(args.dir).resolve()
    if not xml_dir.is_dir():
        print(f"[FAIL] 找不到测试报告目录: {xml_dir}")
        return 1
    xml_files = sorted(xml_dir.glob("TEST-*.xml"))
    if not xml_files:
        print(f"[FAIL] 测试报告目录中没有任何 TEST-*.xml: {xml_dir}")
        return 1

    total_tests = 0
    total_failures = 0
    total_errors = 0
    total_skipped = 0

    for xf in xml_files:
        root = ET.parse(xf).getroot()
        suites = [root] if root.tag == "testsuite" else list(root.findall(".//testsuite"))
        for suite in suites:
            name = suite.attrib.get("name", xf.name)
            t = int(suite.attrib.get("tests", "0"))
            f = int(suite.attrib.get("failures", "0"))
            e = int(suite.attrib.get("errors", "0"))
            s = int(suite.attrib.get("skipped", "0"))
            total_tests += t
            total_failures += f
            total_errors += e
            total_skipped += s
            print(f"  suite {name}: tests={t}, failures={f}, errors={e}, skipped={s}")

    print(
        f"JUnit 汇总: tests={total_tests}, failures={total_failures}, "
        f"errors={total_errors}, skipped={total_skipped} (min={args.min_tests})"
    )
    if total_failures != 0 or total_errors != 0 or total_skipped != 0:
        print("[FAIL] 存在失败、异常或被跳过的单元测试")
        return 1
    if total_tests < args.min_tests:
        print(f"[FAIL] 测试总数不足: actual={total_tests} < min={args.min_tests}")
        return 1
    return 0


# ------------------------------------------------------------------ 3. APK V1 + V2/V3 未签名校验


def find_zip_cd_offset(data: bytes) -> int:
    search_start = max(0, len(data) - 65557)
    idx = data.rfind(EOCD_SIGNATURE, search_start)
    if idx < 0 or idx + 22 > len(data):
        raise ValueError("无法定位 ZIP EOCD 记录，APK 文件结构异常")
    _, _, _, _, _, _, cd_offset, _ = struct.unpack_from("<IHHHHIIH", data, idx)
    if cd_offset > idx:
        raise ValueError(f"ZIP Central Directory 偏移非法: {cd_offset} > {idx}")
    return cd_offset


def cmd_apk_unsigned(args: argparse.Namespace) -> int:
    apk_path = Path(args.apk).resolve()
    if not apk_path.is_file():
        print(f"[FAIL] 找不到 APK: {apk_path}")
        return 1

    raw = apk_path.read_bytes()
    with zipfile.ZipFile(apk_path) as zf:
        names = zf.namelist()
    v1_hits = [
        n
        for n in names
        if n.upper().startswith("META-INF/") and n.upper().endswith((".RSA", ".DSA", ".EC", ".SF"))
    ]

    cd_offset = find_zip_cd_offset(raw)
    tail_magic = cd_offset >= 16 and raw[cd_offset - 16 : cd_offset] == APK_SIG_BLOCK_MAGIC
    any_magic = APK_SIG_BLOCK_MAGIC in raw[:cd_offset]
    v2_v3_signed = tail_magic or any_magic

    size_mb = len(raw) / (1024 * 1024)
    print(
        f"APK 核验: {apk_path.name} ({size_mb:.2f} MiB, {len(names)} entries) | "
        f"v1_signed={bool(v1_hits)} | v2_v3_signed={v2_v3_signed}"
    )
    if v1_hits:
        print(f"[FAIL] 检测到 V1 签名条目: {v1_hits}")
        return 1
    if v2_v3_signed:
        print("[FAIL] 检测到 V2/V3 APK Signing Block ('APK Sig Block 42')，APK 带有签名")
        return 1
    return 0


# ------------------------------------------------------------------ 4. iOS 工程结构校验（纯标准库 YAML 解析）


def _strip_yaml_comment(line: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    for idx, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if ch == "\\" and in_double:
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            if idx == 0 or line[idx - 1].isspace():
                return line[:idx]
    return line


def _parse_yaml_scalar(raw: str) -> Any:
    s = raw.strip()
    if s == "":
        return ""
    if s == "[]":
        return []
    if s == "{}":
        return {}
    if s.startswith("[") and s.endswith("]"):
        inner = s[1:-1].strip()
        if not inner:
            return []
        return [_parse_yaml_scalar(part) for part in inner.split(",")]
    if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
        return s[1:-1]
    lower = s.lower()
    if lower == "true":
        return True
    if lower == "false":
        return False
    if lower in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    return s


def _split_yaml_kv(text: str) -> tuple[str, str] | None:
    in_single = False
    in_double = False
    for idx, ch in enumerate(text):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == ":" and not in_single and not in_double:
            if idx + 1 == len(text) or text[idx + 1].isspace():
                key = text[:idx].strip().strip('"').strip("'")
                val = text[idx + 1 :].strip()
                return key, val
    return None


def parse_simple_yaml(text: str) -> Any:
    try:
        import yaml  # type: ignore

        return yaml.safe_load(text)
    except Exception:
        pass

    tokens: list[tuple[int, str]] = []
    for raw_line in text.splitlines():
        cleaned = _strip_yaml_comment(raw_line).rstrip()
        if not cleaned.strip():
            continue
        indent = len(cleaned) - len(cleaned.lstrip(" "))
        tokens.append((indent, cleaned.lstrip(" ")))

    def parse_block(index: int, min_indent: int) -> tuple[Any, int]:
        if index >= len(tokens):
            return {}, index
        indent, first = tokens[index]
        is_list = first == "-" or first.startswith("- ")
        if is_list:
            items: list[Any] = []
            while index < len(tokens):
                cur_indent, line = tokens[index]
                if cur_indent < min_indent or not (line == "-" or line.startswith("- ")):
                    break
                if cur_indent > min_indent:
                    break
                rest = line[1:].strip()
                index += 1
                if not rest:
                    if index < len(tokens) and tokens[index][0] > cur_indent:
                        child, index = parse_block(index, tokens[index][0])
                        items.append(child)
                    else:
                        items.append(None)
                else:
                    kv = _split_yaml_kv(rest)
                    if kv is not None:
                        k, v = kv
                        obj: dict[str, Any] = {}
                        if v:
                            obj[k] = _parse_yaml_scalar(v)
                        elif index < len(tokens) and tokens[index][0] > cur_indent + 2:
                            obj[k], index = parse_block(index, tokens[index][0])
                        else:
                            obj[k] = {}
                        if index < len(tokens) and tokens[index][0] > cur_indent:
                            extra, index = parse_block(index, tokens[index][0])
                            if isinstance(extra, dict):
                                obj.update(extra)
                        items.append(obj)
                    else:
                        items.append(_parse_yaml_scalar(rest))
            return items, index

        mapping: dict[str, Any] = {}
        while index < len(tokens):
            cur_indent, line = tokens[index]
            if cur_indent < min_indent:
                break
            if cur_indent > min_indent:
                break
            if line == "-" or line.startswith("- "):
                break
            kv = _split_yaml_kv(line)
            if kv is None:
                raise ValueError(f"无法解析 YAML 行: {line}")
            k, v = kv
            index += 1
            if v:
                mapping[k] = _parse_yaml_scalar(v)
            else:
                if index < len(tokens) and tokens[index][0] > cur_indent:
                    child, index = parse_block(index, tokens[index][0])
                    mapping[k] = child
                else:
                    mapping[k] = {}
        return mapping, index

    parsed, _ = parse_block(0, tokens[0][0] if tokens else 0)
    return parsed


def _is_no_setting(value: Any) -> bool:
    if isinstance(value, bool):
        return value is False
    if isinstance(value, str):
        return value.strip().upper() == "NO"
    return False


def _is_true_setting(value: Any) -> bool:
    if isinstance(value, bool):
        return value is True
    if isinstance(value, str):
        return value.strip().upper() in {"YES", "TRUE", "1"}
    return False


def _extract_brace_block(text: str, start_idx: int) -> str:
    brace_start = text.find("{", start_idx)
    if brace_start < 0:
        return ""
    depth = 0
    for idx in range(brace_start, len(text)):
        ch = text[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace_start : idx + 1]
    return ""


def _check_ats_local_networking(ios_dir: Path, project: dict[str, Any], target: dict[str, Any]) -> bool:
    # 1) XcodeGen target.info.properties.NSAppTransportSecurity.NSAllowsLocalNetworking
    info = target.get("info")
    if isinstance(info, dict):
        props = info.get("properties")
        if isinstance(props, dict):
            ats = props.get("NSAppTransportSecurity")
            if isinstance(ats, dict) and _is_true_setting(ats.get("NSAllowsLocalNetworking")):
                return True
        info_path = info.get("path")
        if isinstance(info_path, str):
            plist_file = ios_dir / info_path
            if plist_file.is_file():
                plist_data = plistlib.loads(plist_file.read_bytes())
                ats = plist_data.get("NSAppTransportSecurity")
                if isinstance(ats, dict) and _is_true_setting(ats.get("NSAllowsLocalNetworking")):
                    return True

    # 2) settings.base.INFOPLIST_FILE -> Info.plist
    settings = target.get("settings")
    base = settings.get("base") if isinstance(settings, dict) else {}
    if isinstance(base, dict):
        plist_rel = base.get("INFOPLIST_FILE")
        if isinstance(plist_rel, str):
            plist_file = ios_dir / plist_rel
            if plist_file.is_file():
                plist_data = plistlib.loads(plist_file.read_bytes())
                ats = plist_data.get("NSAppTransportSecurity")
                if isinstance(ats, dict) and _is_true_setting(ats.get("NSAllowsLocalNetworking")):
                    return True
        # 3) Direct INFOPLIST_KEY_NSAppTransportSecurity_*
        for k, v in base.items():
            if "NSAllowsLocalNetworking" in str(k) and _is_true_setting(v):
                return True

    # 4) Fallback: scan any Info.plist under iosApp
    for plist_file in ios_dir.rglob("Info.plist"):
        try:
            plist_data = plistlib.loads(plist_file.read_bytes())
        except Exception:
            continue
        ats = plist_data.get("NSAppTransportSecurity")
        if isinstance(ats, dict) and _is_true_setting(ats.get("NSAllowsLocalNetworking")):
            return True

    return False


def cmd_ios_project(args: argparse.Namespace) -> int:
    ios_dir = Path(args.ios_dir).resolve()
    project_yml = ios_dir / "project.yml"
    if not project_yml.is_file():
        print(f"[FAIL] 缺少 {project_yml}")
        return 1

    project = parse_simple_yaml(project_yml.read_text(encoding="utf-8"))
    if not isinstance(project, dict):
        print("[FAIL] iosApp/project.yml 解析结果不是合法映射")
        return 1

    targets = project.get("targets")
    if not isinstance(targets, dict) or "RainCheck" not in targets:
        print("[FAIL] project.yml 缺少 targets.RainCheck")
        return 1

    app_target = targets["RainCheck"]
    top_base = (project.get("settings") or {}).get("base") or {}
    app_base = (app_target.get("settings") or {}).get("base") or {}
    merged_settings = {**top_base, **app_base}

    # 1) 严格未签名配置值
    if not _is_no_setting(merged_settings.get("CODE_SIGNING_ALLOWED")):
        print(f"[FAIL] CODE_SIGNING_ALLOWED 必须为 NO，实际: {merged_settings.get('CODE_SIGNING_ALLOWED')!r}")
        return 1
    if not _is_no_setting(merged_settings.get("CODE_SIGNING_REQUIRED")):
        print(f"[FAIL] CODE_SIGNING_REQUIRED 必须为 NO，实际: {merged_settings.get('CODE_SIGNING_REQUIRED')!r}")
        return 1

    # 2) ATS NSAllowsLocalNetworking
    if not _check_ats_local_networking(ios_dir, project, app_target):
        print("[FAIL] iOS 工程未正确启用 NSAppTransportSecurity.NSAllowsLocalNetworking = true")
        return 1

    # 3) RainCheckTests 测试目标与 scheme 绑定
    if "RainCheckTests" not in targets:
        print("[FAIL] project.yml 缺少 RainCheckTests 测试目标")
        return 1
    test_target = targets["RainCheckTests"]
    if str(test_target.get("type") or "") != "bundle.unit-test":
        print(f"[FAIL] RainCheckTests.type 应为 bundle.unit-test，实际: {test_target.get('type')!r}")
        return 1

    scheme_wired = False
    app_scheme = app_target.get("scheme")
    if isinstance(app_scheme, dict):
        t_list = app_scheme.get("testTargets") or []
        for item in t_list:
            if item == "RainCheckTests" or (isinstance(item, dict) and item.get("name") == "RainCheckTests"):
                scheme_wired = True
    top_schemes = project.get("schemes")
    if isinstance(top_schemes, dict):
        rc_scheme = top_schemes.get("RainCheck")
        if isinstance(rc_scheme, dict):
            test_cfg = rc_scheme.get("test")
            if isinstance(test_cfg, dict):
                for item in test_cfg.get("targets") or []:
                    if item == "RainCheckTests" or (isinstance(item, dict) and item.get("name") == "RainCheckTests"):
                        scheme_wired = True
    if not scheme_wired:
        print("[FAIL] RainCheck scheme 未关联 RainCheckTests 测试目标")
        return 1

    test_files = sorted(ios_dir.rglob("*Tests.swift"))
    if len(test_files) < 2:
        print(f"[FAIL] RainCheckTests 单元测试文件过少: {[f.name for f in test_files]}")
        return 1

    # 4) Liquid Glass 核心文件与 iOS 26 兼容护栏
    sources_dir = ios_dir / "Sources"
    swift_files = sorted(sources_dir.rglob("*.swift")) if sources_dir.is_dir() else []
    swift_names = {f.name for f in swift_files}
    if len(swift_files) < 8:
        print(f"[FAIL] iOS Swift 源文件数量过少: {len(swift_files)}")
        return 1

    required_liquid_files = [
        "LiquidGlassTheme.swift",
    ]
    missing_liquid = [name for name in required_liquid_files if name not in swift_names]
    if missing_liquid:
        print(f"[FAIL] 缺少液态玻璃核心文件: {missing_liquid}")
        return 1

    theme_file = next(f for f in swift_files if f.name == "LiquidGlassTheme.swift")
    theme_src = theme_file.read_text(encoding="utf-8")
    if "glassEffect" not in theme_src or "GlassEffectContainer" not in theme_src:
        print("[FAIL] LiquidGlassTheme.swift 未包含原生 iOS 26/27 Liquid Glass API (glassEffect / GlassEffectContainer)")
        return 1
    if "#available(iOS 26" not in theme_src:
        print("[FAIL] LiquidGlassTheme.swift 缺少 #available(iOS 26.0, *) 兼容护栏")
        return 1

    # 5) SignResult 不得序列化明文凭据（必须通过 CodingKeys 排除 refreshedAccount）
    sign_result_checked = False
    for sf in swift_files:
        src = sf.read_text(encoding="utf-8")
        m = re.search(r"\bstruct\s+SignResult\b[^{]*\{", src)
        if not m:
            continue
        block = _extract_brace_block(src, m.start())
        ck_match = re.search(r"\benum\s+CodingKeys\b[^{]*\{", block)
        if not ck_match:
            print(f"[FAIL] {sf.name} 中 SignResult 未显式声明 CodingKeys，存在导出明文凭据风险")
            return 1
        ck_block = _extract_brace_block(block, ck_match.start())
        for forbidden in ("refreshedAccount", "bearer", "sessionId", "csrfToken"):
            if re.search(rf"\bcase\s+{forbidden}\b", ck_block):
                print(f"[FAIL] {sf.name} SignResult.CodingKeys 包含敏感凭据字段: {forbidden}")
                return 1
        sign_result_checked = True
        break

    if not sign_result_checked:
        print("[FAIL] 未在 iosApp/Sources 中找到 struct SignResult 定义")
        return 1

    print(
        f"iOS 工程核验通过: {len(swift_files)} Swift 源文件, {len(test_files)} 测试文件, "
        f"CODE_SIGNING_ALLOWED=NO, CODE_SIGNING_REQUIRED=NO, NSAllowsLocalNetworking=true, "
        f"LiquidGlassTheme 就绪, SignResult.CodingKeys 排除凭据"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="RainCheck 产物与工程校验")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_sync = sub.add_parser("profile-sync", help="校验 protocol/profile.json 与各端及打包产物一致")
    p_sync.add_argument("--root", default=".")
    p_sync.add_argument("--check-cli-jar", action="store_true")
    p_sync.add_argument("--apk", action="append", default=[])
    p_sync.set_defaults(func=cmd_profile_sync)

    p_junit = sub.add_parser("junit-xml", help="解析 JUnit XML 并断言测试总数与 0 失败 0 跳过")
    p_junit.add_argument("--dir", required=True)
    p_junit.add_argument("--min-tests", type=int, default=20)
    p_junit.set_defaults(func=cmd_junit_xml)

    p_apk = sub.add_parser("apk-unsigned", help="检查 APK 同时无 V1 与 V2/V3 签名")
    p_apk.add_argument("apk")
    p_apk.set_defaults(func=cmd_apk_unsigned)

    p_ios = sub.add_parser("ios-project", help="结构化校验 iOS project.yml、测试目标、液态玻璃与凭据安全")
    p_ios.add_argument("--ios-dir", default="iosApp")
    p_ios.set_defaults(func=cmd_ios_project)

    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
