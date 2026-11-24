# 架构说明

## 1. 整体分层（如实反映当前多端实现）

```text
┌────────────────────────────────────┐    ┌─────────────────────────────────────────┐
│ androidApp (Jetpack Compose M3)    │    │ iosApp (SwiftUI · iOS 26/27 Liquid Glass)│
│ 单 Activity + ViewModel/StateFlow  │    │ GlassEffectContainer + .glassEffect     │
│ CameraX + ZXing Core 扫码          │    │ AVFoundation 扫码 + Keychain 安全存储    │
│ Android Keystore AES-GCM 加密仓库   │    │ 独立 Swift 协议引擎 + RainCheckTests     │
└─────────────────┬──────────────────┘    └────────────────────┬────────────────────┘
                  │ 共享 Kotlin core (JVM/Android)             │ 独立原生 Swift 实现
┌─────────────────▼──────────────────┐                         │ （逐字节共用同一
│ cli/ (JVM 命令行)                  │                         │  profile.json 与
│ parse / accounts / login / signin  │                         │  qr_cases.json）
│ context / probe (支持 --profile)   │                         │
└─────────────────┬──────────────────┘                         │
                  ▼                                            ▼
┌───────────────────────────────────────────────────────────────────────────────────┐
│ 核心协议语义（Kotlin core 与 Swift iosApp 保持 100% 行为对齐）                       │
│  · SignInEngine   多账号并发编排、策略链回退、重试退避、域名白名单、DRY_RUN 零请求   │
│  · LoginService   pre-info → wait-for-scan → login → login-with-code → basic-info │
│  · RainCheckApi   双载体鉴权 (Bearer + Cookie/CSRF)、响应头会话回填、errcode 兼容   │
│  · QrParser       动态码 / 静态课堂码 / 登录码解析（全量向量对齐 qr_cases.json）     │
│  · ProtocolProfile + Template   协议数据化（端点 / 请求体 / 策略 / 关键字）         │
└───────────────────────────────────────┬───────────────────────────────────────────┘
                                        │ protocol/profile.json（单一事实来源）
┌───────────────────────────────────────▼───────────────────────────────────────────┐
│ 离线验证工具链                                                                      │
│  · tools/mock_server.py      严格协议校验 + source=14 拒签回退 + 双载体鉴权 + 登录链 │
│  · tools/demo.py             6 组端到端全场景验收（跨 Windows / Linux / macOS）     │
│  · tools/check_artifacts.py  协议 SHA-256 / JUnit XML / V1+V2+V3 APK / iOS YAML校验 │
│  · tools/verify.ps1          Windows 一键离线全量验收                               │
└───────────────────────────────────────────────────────────────────────────────────┘
```

> **关于 KMP 范围的诚实说明**：`core/` 是 Kotlin Multiplatform 模块，当前实际由 **`androidApp`** 与 **`cli`（JVM）** 共同直接依赖；`iosApp/` **未链接** KMP `core` 框架，而是使用纯 Swift 实现了同契约协议引擎，并配有原生 `RainCheckTests` 单元测试靶标。两端通过同一份 `protocol/profile.json` 与 `protocol/vectors/qr_cases.json` 保证行为一致，CI 对协议文件执行严格字节级一致性校验。

---

## 2. 协议数据化与配置同步

将站点列表、请求头、端点路径、请求体模板、策略顺序与状态判定关键字集中保存在 [`protocol/profile.json`](../protocol/profile.json)：

1. **单一事实来源**：Android (`androidApp/src/main/assets/protocol_profile.json`)、iOS (`iosApp/Resources/protocol_profile.json`) 与 CLI (`cli.jar::profile.json`) 均以 `protocol/profile.json` 为准，本地 `verify.ps1` 与 GitHub Actions CI 均执行严格 SHA-256 逐字节比对，拒绝任何漂移。
2. **配置生效边界**：
   - **CLI**：支持运行时通过 `--profile <path>` 加载外部 JSON 协议文件，便于快速验证接口变化。
   - **Android / iOS 移动端**：**不支持外部 profile 热更新**；更新协议时修改 `protocol/profile.json` 并同步两端副本与内置兜底配置（`FallbackProfile.kt` / `ProfileStore.swift`）后重新构建。
3. **类型保真模板**：整串占位符（如 `"{source}"`）保留原 JSON 数值/布尔类型，混合字符串执行插值，数组与嵌套对象递归渲染，路径段自动做 URL 编码。

---

## 3. 签到状态机与安全护栏

```text
               ┌─────── dryRun == true ────────► 跳过所有网络请求 ──► 生成轨迹 ──► DRY_RUN
               │
 QR ─ parse ───┼─────── ticket.lessonId 有值 ──────────────────────────┐
               │                                                       ├──► 策略链
               └─────── 无 lessonId ─► discover(activeLesson) ─────────┘
                                         │ 401/403 ──► AUTH_REQUIRED
                                         │ 网络异常 ──► ERROR
                                         │ 无课且无可用策略 ──► NO_CONTEXT

策略链（按 protocol/profile.json 顺序，命中即停）：
  DYN_TICKET_14 ─► DYN_TICKET_5 ─► LESSON_DESKTOP ─► LESSON_WEB ─► QR_URL_POST* ─► QR_URL_GET*
  (* 强制通过 Scheme + Host 白名单校验，禁止向非白名单域名发包或吸收响应头)

单策略判定优先级（与 core / iosApp 引擎完全对齐）：
  1. httpStatus == -1（网络异常）                   → 指数退避重试 → 耗尽收敛为 ERROR
  2. HTTP 401/403                                   → AUTH_REQUIRED（立即终止，不重试）
  3. 命中 alreadyKeywords（优先于 okCodes / code==0）→ ALREADY（成功态）
  4. 2xx 且 code/errcode ∈ okCodes                   → SUCCESS
  5. 业务响应（含 HTTP 200）命中 authKeywords        → AUTH_REQUIRED（立即终止，不重试）
  6. 命中 expiredKeywords（即便 5xx）                 → TICKET_EXPIRED（立即终止重试，默认中止策略链）
  7. HTTP 408/425/429/5xx                           → 指数退避重试（默认 3 次 / 800ms 起）→ 耗尽收敛为 ERROR
  8. 其它业务拒绝                                     → 尝试下一策略；全链耗尽 → FAILED
```

状态枚举：`SUCCESS` / `ALREADY` / `DRY_RUN` / `FAILED` / `AUTH_REQUIRED` / `TICKET_EXPIRED` / `NO_CONTEXT` / `ERROR`。

---

## 4. 并发、取消与会话自愈

- **并发控制**：
  - 账号之间：信号量限流（`concurrency` 支持 1–32，默认 4）+ `staggerMs` 起步错开（默认 60ms），结果保持输入账号顺序。
  - 账号内部：严格串行执行策略链，避免单会话并发提交触发风控或竞争写回。
  - HTTP 连接池：JVM/Android OkHttp 显式配置 `Dispatcher(maxRequests = 64, maxRequestsPerHost = 32)` 并托管引擎生命周期，解除默认单域 5 并发瓶颈且 `api.close()` 无线程池泄漏；iOS Darwin/URLSession 禁用共享 `HTTPCookieStorage`（使用 `ephemeral` 会话），彻底杜绝多账号串 Cookie。
  - 取消传播：Kotlin 协程全链路重抛 `CancellationException`；iOS `AsyncSemaphore` 使用 `withTaskCancellationHandler` 支持任务取消。
- **会话自愈（Session Refresh）**：
  - 任一响应（含课堂发现与签到尝试）携带 `set-auth` / `Authorization` 或有效 `Set-Cookie`（忽略空值与 `Max-Age=0` 过期清理）时：
    1. 立即合并到当前请求上下文的 `current` 账号对象，后续重试与后续策略立刻使用新凭据；
    2. 仅在凭据实际变化时触发安全回写；回写时保留账号当前启用态，且绝不复活并发期间已被用户删除的账号。

---

## 5. 双端架构与凭据安全设计

| 维度 | Android 端（`androidApp/`） | iOS 端（`iosApp/`） | CLI（`cli/`） |
|---|---|---|---|
| **UI 框架** | Jetpack Compose + Material 3（极光毛玻璃风格，单 Activity + `ViewModel`/`StateFlow`） | SwiftUI · iOS 26/27 原生 Liquid Glass（`GlassEffectContainer` / `.glassEffect` + `#available(iOS 26.0, *)` 优雅降级） | JVM 命令行 |
| **扫码实现** | AndroidX CameraX + ZXing Core（无 GMS 依赖、原生竖屏、防抖单次回调） | AVFoundation（串行队列隔离、即扫即停防双回调、支持横竖屏） | 命令行 `--qr` / `@文件` |
| **自动签到保护** | 默认关闭，用户确认后触发 | 默认关闭（`autoSignOnScan = false`），防恶意码零点击外泄 | 显式执行 `signin` |
| **凭据存储** | Android Keystore `AES/GCM/NoPadding` 加密仓库 + 原子替换 + 坏文件备份 | iOS **Keychain**（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）+ `.completeFileProtection` + 排除 iCloud 备份 | `ReentrantLock` + 原子文件替换 + `0600`/当前用户 ACL + 支持 `--token-stdin`/`RAINCHECK_TOKEN` |
| **网络安全** | `network_security_config.xml` 全局强制 HTTPS，仅放行 `127.0.0.1`/`localhost`；`data_extraction_rules.xml` 排除凭据备份 | ATS 默认强制 HTTPS，仅开启 `NSAllowsLocalNetworking = true` 供本地 mock | 遵循账号/站点 scheme 配置 |
| **报告导出安全** | 写入私有 `cacheDir/reports/` 通过 `FileProvider` 分享，零凭据 | `SignResult.CodingKeys` 永久排除 `refreshedAccount`，零凭据 | `--json` 仅导出轨迹摘要，零凭据 |

---

## 6. 测试与持续验证体系

| 层级 | 工具 / 靶标 | 验证内容 |
|---|---|---|
| **协议与引擎单测（JVM）** | `:core:jvmTest --rerun` + JUnit XML 断言（>= 20 用例、0 失败 0 跳过） | 自动加载真实 `protocol/vectors/qr_cases.json` 与 `protocol/profile.json`，覆盖解析、策略回退、`QR_URL_*` 恶意域阻断、`JsonNull`、会话回填、`ALREADY`、HTTP 200 鉴权、`DRY_RUN`、`LoginService` 全状态流转 |
| **iOS 原生单测** | `iosApp` `RainCheckTests`（GitHub Actions `macos-26` Simulator 运行） | 加载 `qr_cases.json` 与 `profile.json`，覆盖解析、策略回退、恶意域拦截、`JSONAssist` 布尔陷阱修复、导出 JSON 零凭据、`LoginService` |
| **端到端离线验证** | `tools/demo.py` + `tools/mock_server.py` | 6 组完整场景：严格 Header/JSON/CSRF/签名拦截、8 账号并发 16 次真实策略回退、严格 `7 SUCCESS + 1 ALREADY`、Cookie+CSRF、会话回填、401 `AUTH_REQUIRED`、过期二维码立即中止 `TICKET_EXPIRED`、零请求 `DRY_RUN`、完整扫码与 4 位验证码登录链 |
| **产物与未签名门禁** | `tools/check_artifacts.py` / `tools/verify.ps1` / GitHub Actions | 源码 + `cli.jar` + APK 内嵌协议 SHA-256 逐字节一致；APK 同时校验无 V1 与 V2/V3 签名块；IPA 校验无 `_CodeSignature` 与 `embedded.mobileprovision` |

---

## 7. 扩展点

- **新增公开站点**：在 `protocol/profile.json` 的 `editions` 中追加条目并同步两端资源与兜底配置。
- **调整策略与端点**：更新 `protocol/profile.json` 的 `endpoints` 与 `strategies`，先通过 CLI `--profile` 与 `mock_server.py` 验证后再同步构建移动端。
- **定位签到（未实现）**：`protocol/profile.json` 仅保留基于 IPA 静态逆向记录的路径模板，客户端当前未接入任何定位签到逻辑，待获授权实测字段语义后再决定是否开发。
