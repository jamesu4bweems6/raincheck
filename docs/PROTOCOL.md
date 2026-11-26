# 雨课堂签到协议事实集（IPA 1.3.6 静态逆向 + 外部脚本推断边界）

本文件是 RainCheck 多端（`core` / CLI / Android / iOS）共用的协议基线与证据溯源说明。
本仓库**严格区分两类来源**，不做混淆：

1. **IPA 1.3.6 ARM64 静态逆向实证**：提取自本地 `雨课堂_1.3.6.ipa`（`work/rainclassroom-ipa/`，基于 Dart 3.11.5 AOT `arm64` `App.framework/App` 的 ROData 字符串表、全局 ObjectPool、InstructionsTable 与 Capstone 反汇编，全程离线、未做实网抓包）。
2. **Web 端浏览器接口适配**：面向雨课堂网页端上下文的 `X-Client: web`、`xtbz: ykt`/`xt`、同源 `Origin`/`Referer` 以及 Web PC 手机号短信登录路由（`/pc/login/send_sms_login_code/`、`/pc/login/verify_pwd_login/`）；该组 Web 路径在 IPA 1.3.6 全包 721 文件中 **0 命中**（IPA 移动端对应 `/api/v3/user/code/send` 与 `/api/v3/user/login/app`）。
3. **`⚠️ 未实网验证（外部桌面脚本推断）`**：参考公开桌面端实现（`ZhengXieGang/YuKeTang-CheckIn-Helper`）交叉推断的扫码登录 4 端点轮询链与 `source=14/5/1` + `ticket/t/s` 动态码兜底载荷；该部分在 IPA 1.3.6 全包 721 文件中 **0 命中**，尚未经真实课堂动态抓包验证。

> **关于配置生效方式**：协议端点、请求体模板与策略顺序集中维护在 [`protocol/profile.json`](../protocol/profile.json)。**仅 CLI 支持运行时通过 `--profile <path>` 切换外部协议文件**；Android 与 iOS 客户端不提供外部 profile 热更新，变更协议时需同步更新 `protocol/profile.json` 及两端资源副本后重新构建（CI 强制校验字节级 SHA-256 一致）。

---

## 0. 核心结论与静态逆向未决风险

- 从离线 ARM64 反汇编证据与公开桌面脚本综合判断，签到核心链路可分为：
  1. 账号会话获取（iOS 端 Web 手机号短信验证码登录、CLI/Android 扫码登录或导入已有会话凭据）；
  2. **官方 App 两步扫码签到（IPA 1.3.6 ARM64 实证，Priority #1）**：先 `POST /api/v3/app/scan`（`{"url": "<原始二维码字符串>"}`，`x-client: app`）由服务端校验动态二维码签名并返回 `data.type="checkin"` 与 `data.value`（`lessonId`），紧接着立即 `POST /api/v3/lesson/checkin`（`{"source": 21, "lessonId": "<data.value>", "joinIfNotIn": true}`，`x-client: app`）——全程无需前置 `on-lesson-upcoming-exam`，首包直达以应对 5–8 秒刷新的动态码；
  3. 课堂上下文查询与兜底策略链（当 `app/scan` 不可用或纯课堂号签到时，按需查询 `on-lesson-upcoming-exam` 并回退至 `DYN_TICKET_*` / `LESSON_*` / `QR_URL_*`）。
- 动态二维码（老师端高频刷新）在公开桌面脚本中携带 `c / t / s / v` 参数；多账号场景下需在有效期内以并发方式提交（账号间并发、账号内策略串行回退）。
- **必须透明披露的 4 项逆向未决风险**（摘自 `work/rainclassroom-ipa/report.md` 静态离线边界）：
  1. **第一方 1024-bit RSA 加密（`F-001`）**：`App.framework` 实存 `encrypt_helper.dart` / `simple_rsa3` 与 1024 位 RSA 密钥，静态分析未确认其具体加密哪些业务字段（如口令、登录参数或签到载荷）。
  2. **实时长连接 `wss://<host>/wsapp/`**：官方 App 通过 `package:rain/websocket/ws_connector.dart` 建立 TLS WebSocket 接收课件、弹幕、点名与实时态事件；RainCheck 当前仅覆盖 HTTP 签到接口，未接入 WebSocket。
  3. **双人机验证码风控**：IPA 集成腾讯防水墙（`flutter_tencent_captcha`，加载 `https://turing.captcha.qcloud.com/TCaptcha.js`，`appId=2091064951`）与 `hCaptcha`（`/authorize/hcaptcha_app`）；iOS 手机登录仅展示官方交互式验证页由用户手工完成，本工具不做任何自动识别或绕过。
  4. **静态未验证的 TLS 校验与风控指纹（`F-004` / `E-203`）**：静态分析虽未在 Dart 业务代码中直接观测到证书固定（TLS Pinning），但原生层存在 `TXCHttpsSendRecv`、`JCORESSLSocket.checkCert:`、`flutter_inappwebview_ios` 等回调，运行期 Dart `HttpClient` 与服务端 TLS/风控校验策略**尚未经实网抓包验证**，因此不能断言「必然不依赖任何证书或客户端校验」。

---

## 1. 证据来源与溯源矩阵

| 来源类别 | 位置 | 覆盖内容 | 实网验证状态 |
|---|---|---|---|
| **IPA 1.3.6 静态逆向** | `work/rainclassroom-ipa/extracted/.../App.framework/App`、`evidence/E-303-static-api-surface.md`、`scratch-binary/strings_checkin.txt` | 5 个核心生产域名、215 条路由（含移动端 `/api/v3/user/code/send`、`/api/v3/user/login/app`）、双载体鉴权头、`Set-Auth`/`set-cookie`、腾讯防水墙 `appId=2091064951`、`dynamic_qr_error`、`app://yuketang`、定位签到接口族、RSA/WS/Captcha 风险面 | 静态实证（离线） |
| **Web PC 端接口适配** | `protocol/profile.json`、`iosApp/.../PhoneLoginClient.swift`、`tools/mock_server.py` | Web 请求头（`X-Client: web`、`xtbz: ykt`/`xt`、同源 `Origin`/`Referer`）、Web 手机短信登录 `/pc/login/send_sms_login_code/` 与 `/pc/login/verify_pwd_login/` | Web 端协议（IPA 0 命中；本地 mock 与单测覆盖） |
| **外部桌面脚本** | `ZhengXieGang/YuKeTang-CheckIn-Helper:yuketang_helper.py`、`test_checkin_bypass.py` | 扫码登录 4 端点轮询链、`c/t/s/v` 动态码载荷与 `source=14/5/1` 提交体 | **`⚠️ 未实网验证（外部桌面脚本推断）`** |

### 1.1 IPA 1.3.6 实证的核心站点域

| Edition ID | 站点名称 | Host | 来源说明 |
|---|---|---|---|
| `www` | 雨课堂 | `www.yuketang.cn` | IPA 实证 |
| `pro` | 雨课堂 Pro（专业版） | `pro.yuketang.cn` | IPA 实证 |
| `tsinghua` | 荷塘雨课堂 | `pro.yuketang.cn` | IPA 仅见 4 套校园版，`pro.yuketang.cn` 对应荷塘/专业版（已修正旧版错配 `www.yuketang.cn`） |
| `changjiang` | 长江雨课堂 | `changjiang.yuketang.cn` | IPA 实证 |
| `huanghe` | 黄河雨课堂 | `huanghe.yuketang.cn` | IPA 实证 |
| `xuetangx` | 学堂在线 | `www.xuetangx.com` | IPA `Runner` 及 `applinks:www.xuetangx.com` 实证 |
| `mock` | 本地演练环境 | `127.0.0.1:8787`（`http`） | 仅用于离线本地 mock 演练 |

### 1.2 IPA 1.3.6 二进制直接提取的关键路由与符号（原文）

```text
# 签到与扫码相关（含学生端与教师端）
/api/v3/lesson/checkin              /api/lesson/web_check_in
/wxapi/lesson_check_in              /api/v3/app/scan
/api/v3/lesson/checkin-list         /api/v3/lesson/checkin/detail
/api/v3/lesson/checkin/revise       /api/v3/lesson/checkin/delete
/api/v3/lesson/uncheckin-list

# 定位签到接口族
/api/v3/lesson/location-checkin/{eligibility,end,extend,overview,preview,session,submit}
/api/v3/location-checkin/mobile-setup/{detail,submit,verify}
/api/v3/location-checkin/update-session
/api/v3/tencent-lbs/proxy

# 课堂与用户
/api/v3/classroom/on-lesson-upcoming-exam    (onLessonClassrooms)
/api/v3/lesson/basic-info                    (IPA 仅见 ?lesson_id=)
/api/v3/user/basic-info
/api/v3/user/code/send
/api/v3/user/code/verify
/api/v3/user/login/app
/api/v3/user/login/app/wechat
/api/v3/user/login/scan-handler

# 关键业务字符串与协议头
Authorization / Bearer / Cookie (sessionid, csrftoken) / X-CSRFToken
Set-Auth / set-cookie / X-UID / classroom-id / x-client / ?xtbz=ykt-app
errcode / errmsg / qrContent / dynamic_qr_error / ticket / app://yuketang
wss://<host>/wsapp/
```

---

## 2. 传输层约定

### 2.1 请求头（Web 端默认 vs App 端点覆盖）

RainCheck 默认采用雨课堂官方 Web 端请求头集合（配置于 `protocol/profile.json` 顶层 `headers`，由 `core/Api.kt` 与 `iosApp/.../RainCheckClient.swift` 动态补齐同源 `Origin`/`Referer` 并按主机自动切换 `xtbz`），同时支持**端点级 `headers` 覆盖**（如 `appScan` 与 `checkinAppScan` 显式声明 `"headers": { "x-client": "app" }`，不再强行改回 `web`）：

| 请求头 | Web 端端点（默认） | IPA 1.3.6 App 扫码/签到端点（ARM64 实证） | 说明 |
|---|---|---|---|
| `xtbz` | `ykt`（学堂在线自动切 `xt`） | `ykt` | 平台业务标识（IPA `func #35482`/`#50101` 实证） |
| `X-Client` / `x-client` | `web` | **`app`**（端点 `headers` 覆盖） | Web 接口用 `web`；`/api/v3/app/scan` 与 `source=21` 签到按 IPA 实证使用 `x-client: app` |
| `Accept` | `application/json, text/plain, */*` | `application/json` | 响应协商 |
| `Content-Type` | `application/json; charset=UTF-8` | `application/json; charset=UTF-8` | JSON 请求体编码 |
| `Origin` | `https://<target-host>` | *(IPA 原生 App 未发送 `Origin`)* | RainCheck 始终与目标 URL 严格同源（修复 `QR_URL_*` 跨站 `Referer` 导致 403） |
| `Referer` | `https://<target-host>/v2/web/index` | *(IPA 原生 App 未发送 `Referer`)* | `/pc/login/*` 为 `/web`；课堂接口可覆盖为 `/v2/web/studentLog/<classroomId>` |
| `Authorization` | `Bearer <token>` | `Bearer <token>` | IPA `func #50105`/`#50106` 实证，响应头 `Set-Auth` 自动回填 |
| `Cookie` | `sessionid=<sid>; csrftoken=<csrf>` | `sessionid=<sid>; csrftoken=<csrf>` | IPA `PersistCookieJar` 实证 |
| `X-CSRFToken` | `<csrf>` | `<csrf>` | IPA 实证从 `Set-Cookie: csrftoken` 提取 |

> **IPA 1.3.6 原生 App 附加头（ARM64 `func #35482` / `#50101` / `#50105` / `#50106` 实证）**：官方 iOS App 还会附带 `User-Agent: iPhone OS`、`xtua: client=app&tag=<...>&platform=iOS`、`X-UID: <uid>`、与 Cookie 同步的 `sessionid: <sid>` / `x-csrftoken: <csrf>` 请求头及设备信息头（`brand`、`systemVersion`、`isPhysicalDevice`、`uuid`、`incremental`、`version`、`buildNumber`）；`App.framework` 中不存在 `Origin` 或 `xt-agent`，`classroom-id` 仅附加于班级维度的接口，**不附加于** `/api/v3/app/scan` 或 `/api/v3/lesson/checkin`。
>
> **实网实证（`www.yuketang.cn` `x-client: app` 与 Web `sessionid` 兼容回退）**：实测 `POST /api/v3/app/scan` 强依赖 `x-client: app`（`X-Client: web` 返回 HTTP 400）且不校验用户登录态；但第二步 `POST /api/v3/lesson/checkin` 在 `x-client: app` 下遇到经由 Web 登录/导入的 `sessionid` 凭据时会返回 `HTTP 200 {"code":50000,"msg":"UNAUTHENTICATED","data":""}`（此时 `X-Client: web` 的 `/api/v3/user/basic-info` 凭据校验仍有效）。RainCheck 在 `x-client: app` 模式下除同步附加 `X-UID` 与 `sessionid` 请求头外，当第二步返回 `UNAUTHENTICATED` / `401` 时，自动切回 `X-Client: web`（`APP_SCAN_CHECKIN_WEB`）重试同载荷，并允许继续复用第一步已解析的 `lessonId` 进入 `DYN_TICKET_*` / `LESSON_DESKTOP`（`source=1`，与雨课堂 Web 全屏课堂 `fullscreen.js` 一致）兜底链，避免将有效 Web 会话误判为登录过期。

- **双载体鉴权（IPA 实证）**：同时支持 `Authorization: Bearer` 与 `Cookie: sessionid` + `X-CSRFToken`，任一有效即可发起业务请求。
- **会话刷新回填（IPA 实证）**：响应头出现 `Set-Auth` / `Authorization` 或 `Set-Cookie` 时自动回填并更新当前会话（`set-auth` 优先级高于 `authorization`；忽略空值或 `Max-Age=0` 的清 Cookie 响应头；失败响应不刷 `lastOkAt`）。
- **响应信封兼容**：主协议为 `{"code": 0, "msg": "...", "data": {...}}`，同时兼容 `errcode` / `error_code` / `status_code`（`altCodeKeys`）、`errmsg` / `errormsg` / `detail` / `error`（`altMessageKeys`）以及布尔成功包 `{"success": true}`。

### 2.2 二维码载荷

| 形态 | 载荷示例 | 解析类型 | 证据状态 |
|---|---|---|---|
| 静态课堂码 | 含 `lessonId` / `lesson_id` 的 URL、深度链接或纯数字课堂号 | `LESSON_ONLY` | `lessonId` 获 IPA 实证；`app://yuketang` 获 IPA 实证；`yuketang://`/`ykt://`/`rainclassroom://` 为 **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 动态签到码 | URL 或裸 query，含 `c`、`t`、`s`、`v` 参数 | `DYNAMIC_CHECKIN` | 动态码机制（`dynamic_qr_error`）获 IPA 实证；**`c/t/s/v` 参数语义为 `⚠️ 未实网验证（外部桌面脚本推断）`** |
| 登录二维码 | `pre-info` 返回的 `qrContent` 或微信 `qrconnect` 链接 | `LOGIN` | `qrContent` 获 IPA 实证；桌面 Web 扫码路径组合为 **`⚠️ 未实网验证（外部桌面脚本推断）`** |

- 解析优先级约定：含显式 `lessonId` 的静态课堂链接优先识别为 `LESSON_ONLY`（即便路径中含有 `qrcode`/`scan` 字样也不误判为 `LOGIN`）；`loginPathHints` 仅匹配 URL `path`（不匹配 `host`）。

---

## 3. 登录协议（Web 手机号短信登录 vs 外部脚本扫码链 vs IPA 移动端接口）

### 3.1 Web 手机号短信验证码登录（iOS 客户端采用，已收敛至 `protocol/profile.json`）

iOS 客户端（`PhoneLoginClient.swift`）使用雨课堂 Web PC 端 `/pc/login/*` 手机号 + 短信验证码登录（端点名 `phoneSendSms` / `phoneVerifyLogin`，本地演练服务端 `tools/mock_server.py` 同步支持）：

```http
POST /pc/login/send_sms_login_code/       # 严格保留末尾斜杠 -> {"mobile":"{mobile}","login":true,"ticket":"{ticket}","randstr":"{randstr}","hcaptcha_token":"{hcaptchaToken}"}
POST /pc/login/verify_pwd_login/          # 严格保留末尾斜杠 -> {"type":"PC","name":"{mobile}","pwd":"{code}"}
GET  /api/v3/user/basic-info              # IPA 实证：校验会话并取回 data.id / data.name
```

- **人机验证**：远端 HTTPS 站点调用 `phoneSendSms` 前由用户在交互式 WebView 完成腾讯防水墙（`appId=2091064951`，`https://turing.captcha.qcloud.com/TCaptcha.js`）或降级 `/authorize/hcaptcha_app`；本地 `mock`（`127.0.0.1:8787`）直接放行。
- **响应与凭据提取**：`/pc/login/*` 响应采用布尔字段 `success`（`true`/`false`）与 `status_code`（`300402..300417`），成功时通过响应头 `Set-Cookie` 下发 `sessionid` 与 `csrftoken`（及可选 `set-auth`），随后请求 `GET /api/v3/user/basic-info` 补全昵称与 `userId`（`basic-info` 临时失败仍保留会话与脱敏标签）。学堂在线（`www.xuetangx.com`）不支持 `/pc/login/*`，仅支持手动导入。
- **与 IPA 1.3.6 移动端接口对照**：上述 `/pc/login/send_sms_login_code/` 与 `/pc/login/verify_pwd_login/` 为 Web PC 端接口，在 IPA 1.3.6 全包中 **0 命中**；官方 IPA 1.3.6 移动端实际使用 `POST /api/v3/user/code/send`、`POST /api/v3/user/code/verify` 与 `POST /api/v3/user/login/app`（以及 `/api/v3/user/login/app/wechat`、`/api/v3/user/login/scan-handler`）。RainCheck 选择 Web `/pc/login/*` 以便与 Web `X-Client: web` + `sessionid`/`csrftoken` 鉴权体系保持统一。

### 3.2 扫码登录链（CLI / Android 保留，`⚠️ 未实网验证（外部桌面脚本推断）`）

以下 4 个登录轮询端点与 `verify_token` 字段均在 IPA 1.3.6 全包 721 文件中 **0 命中**（IPA 移动端实际采用 `/api/v3/user/code/send`、`/api/v3/user/login/app`、`/api/v3/user/login/app/wechat`、`/api/v3/user/login/scan-handler` 及微信 OpenSDK `appid=wxb60db2584bf82ac1`），**仅 `GET /api/v3/user/basic-info` 与 `qrContent` 获 IPA 实证**：

```http
GET  /api/v3/user/login/pre-info          # ⚠️ 未实网验证（外部桌面脚本推断） -> data.qrContent, data.token
POST /api/v3/user/login/wait-for-scan     # ⚠️ 未实网验证（外部桌面脚本推断） {"token": "<loginToken>"}
POST /api/v3/user/login                   # ⚠️ 未实网验证（外部桌面脚本推断） {"token": "<loginToken>"}
POST /api/v3/user/login/login-with-code   # ⚠️ 未实网验证（外部桌面脚本推断） {"token": "<verify_token>", "code": "<4位数字>"}
GET  /api/v3/user/basic-info              # IPA 实证：校验会话并取回 data.id / data.name
```

- 轮询流转：`PENDING` → `SCANNED`（已扫码待确认）→ `NEED_CODE`（返回 `verify_token` 时提示输入 4 位验证码）→ `AUTHORIZED`（提取 `set-auth` / `Set-Cookie` 并校验 `basic-info`）。
- 过期判定优先于验证码判定：`500` / `50000` / `50001` 或命中过期关键字 → `EXPIRED`。
- `finishLogin` 必须校验已取得有效凭据才可进入 `AUTHORIZED`；拿到会话后调用 `basic-info` 补全昵称与 `userId`，若 `basic-info` 偶发失败仍保留有效会话入池（双端行为一致）。

---

## 4. 签到提交

### 4.1 课堂上下文

```http
GET /api/v3/classroom/on-lesson-upcoming-exam   # IPA 实证 -> data.onLessonClassrooms[] { lessonId, classroomId, courseName }
GET /api/v3/lesson/basic-info?lesson_id=<id>    # IPA 实证（IPA 仅见 lesson_id 查询参数）
```

> **重要纠偏（`checkin-list` / `checkin/detail`）**：IPA 静态逆向证实 `/api/v3/lesson/checkin-list` 与 `/api/v3/lesson/checkin/detail` 属于 `remote_control/sign/bean` **教师端遥控接口**，且其方法名均以 `post` 开头（`postSignList` / `postSignDetail`，实为 **`POST`**），旧版文档与配置将其错标为学生端 `GET` 且虚构了 `checkinId`/`signId` 字段（IPA 全包 0 命中）。客户端上下文发现仅使用 `on-lesson-upcoming-exam`，不再调用 `checkinDetail` 兜底。

### 4.2 官方两步扫码签到流（IPA 1.3.6 ARM64 反汇编实证 — Priority #1）

对 `App.framework/App`（Dart 3.11.5 AOT `arm64`）的反汇编证实，官方雨课堂 iOS 1.3.6 **不做客户端本地解析 `c/t/s` 动态参数**（全二进制 68,224 条 Dart 字符串中 `dynamic-qr`、`qr-code`、`ticket/t/s` 载荷均 **0 命中**），而是通过以下两步完成扫码签到：

#### 第一步：`POST /api/v3/app/scan`（`HmsScanPage._loadData` `func #34763 @0x00893a30`）

```http
POST /api/v3/app/scan
x-client: app
xtbz: ykt
Content-Type: application/json; charset=UTF-8

{ "url": "<未修改的原始二维码字符串>" }
```

- **响应结构 `ScanBean`（`func #39800 @0x0094f0e8` / `func #39801 @0x0094f4a0`）**：
  - 顶层字段：`success`、`error_code`、`msg`、`code`、`message`、`status_code`、`data`
  - `data` 字段：`type`、`value`、`title`、`code`、`lesson_id`、`is_teacher`、`classroom_id`、`course_id`、`classroom_name`
- **响应分派（`func #34767 @0x00893d0c`）**：
  - `code == 0` 时按 `data.type` 分派：
    1. **`"checkin"`**：读取 `val = data.value`（回退 `data.lesson_id`）；若 `val.length > 11`（v3 Snowflake `lessonId`），立即调用第二步 `POST /api/v3/lesson/checkin`；若 `val.length <= 11`（旧版 v2 `lesson_id`），官方调 `POST /wxapi/lesson_check_in`（RainCheck 兼容 `checkinAppScan` / `checkinWeb`）。
    2. **`"login"`**：登录二维码（官方调 `POST /api/v3/user/login/scan-handler` `{"scene": data.value}`）；RainCheck 明确返回「服务端识别为登录二维码而非课堂签到码」并中止签到链。
    3. **`"app_web_login"`**：Web 登录确认码；同上中止。
    4. **`"classroom"`**：加课/入班码（官方调 `POST /api/v3/classroom/join` `{"classroomId": data.value}`）；RainCheck 明确提示非签到码。
    5. **`"location_checkin_setup"`**：定位签到配置码（官方调 `POST /api/v3/location-checkin/mobile-setup/verify` `{"qrUrl": rawQr}`）。
  - `code == 51203`：直接向用户展示 `scanBean.msg`（常见于二维码无效或已过期）。

#### 第二步：`POST /api/v3/lesson/checkin`（`HmsScanPage._postLessonCheckin` `func #34813 @0x00897630`）

```http
POST /api/v3/lesson/checkin
x-client: app
xtbz: ykt
Content-Type: application/json; charset=UTF-8

{ "source": 21, "lessonId": "<scanBean.data.value>", "joinIfNotIn": true }
```

- **二进制内全部 6 处 `/api/v3/lesson/checkin` 调用点实证**：
  - `HmsScanPage._postLessonCheckin` (`func #34813`)：`{"source": 21, "lessonId": val, "joinIfNotIn": true}`
  - 课堂暗号/邀请码 (`func #26525` / `#26568` / `#33236`)：`{"inviteCode": code, "source": 22, "joinIfNotIn": true}`（失败回退 `/api/lesson/web_check_in` `{"invite_code": code, "source": 23}`）
  - `ReceiverClassPage._postLessonCheckin` (`func #33170`) / `func #33672`：`{"source": 21|23, "lessonId": val, "joinIfNotIn": true}`
- **响应结构 `LessonCheckinBean`（`func #40144 @0x0096e828` / `func #40145 @0x0096ebe0`）**：
  - 顶层：`success`、`error_code`、`msg`、`code`、`message`、`status_code`、`data`
  - `data`：`role`（`1`/`2` 为教师，其余为学生）、`lessonId`、`lessonToken`、`identityId`、`university_name`、`isGuest`、`hasLiveCaster`、`identityName`、`identityNumber`。

#### 官方业务错误码表（IPA 1.3.6 ARM64 实证）

| 接口 | 业务码 `code` | 官方语义（反汇编定位） | RainCheck 处理 |
|---|---|---|---|
| `/api/v3/app/scan` | **`51203`** | 二维码无效或已过期（`func #34767` 直接展示 `scanBean.msg`） | 原样保留服务端 `msg`；含过期关键词时判 `TICKET_EXPIRED` / `.qrExpired` 并停止重试 |
| `/api/v3/lesson/checkin` | **`50070`** | `ReceiverClassPage` 显示 `dynamic_qr_error`（「该课堂已开启动态二维码签到，请扫码签到进班」）；`HmsScanPage` 映射 `Scan_Info3`（课堂已结束） | 保留业务码与明确诊断文案，绝不被后续 404/HTML 兜底覆盖 |
| `/api/v3/lesson/checkin` | **`50019`** | 未绑定学校身份（`Scan_Info7`） | 明确提示「账号未绑定学校身份（50019）」 |
| `/api/v3/lesson/checkin` | **`50017`** | 教师设置了入班限制（`Scan_Info6`） | 明确提示「教师已设置入班限制（50017）」 |
| `/api/v3/lesson/checkin` | **`50004`** | 课堂已结束，无法加入（`Scan_Info8`） | 明确提示「课堂已结束，无法签到（50004）」 |
| `/api/v3/lesson/checkin` | **`50021`** | 课堂人数已达上限（`Scan_Info9`） | 明确提示「课堂人数已达上限（50021）」 |
| `/api/v3/lesson/checkin` | **`50023` / `50003`** | 邀请码或课堂不存在（`Scan_Info10`） | 明确提示「课堂或签到码不存在」 |
| `/api/v3/classroom/join` | `50015` / `50021` / `50017` | 未绑定身份 / 人数上限 / 加入受限（`func #34783`） | 仅作静态协议参考 |
| `/wxapi/lesson_check_in` | `10042` / `10041` / `10026` / `10028` | 课堂已结束 / 未绑定 / 限制加入 / 人数上限（`func #34808`，使用 `errorcode`/`errormsg`） | 通过 `altCodeKeys`/`altMessageKeys` 兼容解析 |

> **服务端动态码校验机制推断（离线边界）**：由于第二步仅提交 `{"source": 21, "lessonId": data.value, "joinIfNotIn": true}` 而不含 `c/t/s`，服务端必然在第一步 `POST /api/v3/app/scan` 内校验原始二维码的动态签名与时效，并记录当前用户的扫码授权状态（或直接放行该 `lessonId` 的 `source=21` 签到），从而使第二步免于触发 `50070`（`DYNAMIC QR CHECK IN REFUSED`）。

### 4.3 兜底提交策略链（当 `APP_SCAN_CHECKIN` 不可用或纯课堂号签到时）

若扫描到的是完整二维码 URL 或未知二维码串且 `profile.endpoints` 同时配置了 `appScan` 与 `checkinAppScan`，引擎优先执行 **`APP_SCAN_CHECKIN`**（不先调用 `on-lesson-upcoming-exam`，避免浪费动态码有效期；若第一步返回 `lessonId` 而第二步失败，会复用该 `lessonId` 省去发现请求）；若 `/api/v3/app/scan` 返回 HTTP 404/405/5xx 或输入为纯课堂号/裸 query 串，则按 `protocol/profile.json` 中 `strategies` 顺序逐个尝试，命中即停：

| # | 策略 ID | 请求 | 证据状态 |
|---|---|---|---|
| 0 | `APP_SCAN_CHECKIN` | `POST /api/v3/app/scan` `{"url":"<rawQr>"}` → `POST /api/v3/lesson/checkin` `{"source":21,"lessonId":"<value>","joinIfNotIn":true}`（`x-client: app`） | **IPA 1.3.6 ARM64 实证**（引擎内置 Priority #1 阶段，端点定义于 `profile.endpoints.{appScan,checkinAppScan}`） |
| 1 | `DYN_TICKET_14` | `POST /api/v3/lesson/checkin` `{"lessonId":"<id>","source":14,"ticket":"<c>","t":"<t>","s":"<s>"}` | 路径获 IPA 实证；`source=14` 与 `ticket/t/s` 载荷 **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 2 | `DYN_TICKET_5` | 同上，`source=5`（推断小程序来源） | 路径获 IPA 实证；`source=5` **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 3 | `LESSON_DESKTOP` | `POST /api/v3/lesson/checkin` `{"lessonId":"<id>","source":1}` | 路径获 IPA 实证；`source=1` **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 4 | `LESSON_WEB` | `POST /api/lesson/web_check_in` `{"lessonId":"<id>","source":1}` | 路径获 IPA 实证（另 IPA 实存 `/wxapi/lesson_check_in`）；请求体 **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 5 | `QR_URL_POST` | 直接向二维码 URL 发起 POST，体 `{"c","t","s","v"}` | **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 6 | `QR_URL_GET` | 直接向二维码 URL 发起 GET | **`⚠️ 未实网验证（外部桌面脚本推断）`** |

#### 安全约束：`QR_URL_POST` / `QR_URL_GET` 域名与 Scheme 白名单

为彻底杜绝恶意二维码诱导客户端外泄全池凭据（SSRF / Token 窃取 + 响应头会话投毒），引擎（Kotlin `core` 与 Swift `iosApp`）在执行 `QR_URL_POST` / `QR_URL_GET` 前强制执行以下校验：

1. **Scheme 白名单**：仅允许 `https`；仅当目标 host 与当前 `account.host`（显式配置为 `http`）或 `profile.editions` 中声明为 `http` 的站点（如本地 `mock`）精确匹配时，才允许 `http`。
2. **Host 白名单**：二维码 URL 的 `host[:port]`（大小写不敏感）必须匹配当前 `account.host`、`profile.editions`、`profile.qr.allowedUrlHosts`（内置 6 个合法站点域），或**标准 HTTPS 443 端口的雨课堂高校子域名（`*.yuketang.cn` / `*.ykt.io`）**；显式拒绝非标准端口、userinfo `@`、`\` 与伪造后缀（如 `www.yuketang.cn.evil.com`）。
3. **同源 Origin/Referer 与拒绝行为**：`QR_URL_POST`/`QR_URL_GET` 放行时自动将 `Origin` 与 `Referer` 均对齐到目标二维码 URL 自身源，避免跨站 `Referer` 触发 Django CSRF 403；任何不匹配白名单的外部 URL 直接拦截并记录安全拒绝轨迹，**绝不发送 `Authorization` / `Cookie` / `X-CSRFToken`，绝不吸收对方响应头**；同时移动端默认关闭「扫到即自动签到」（`autoSignOnScan = false`），需用户确认后执行。

### 4.4 状态机、幂等与重试语义

- **网络异常优先**：网络层失败（`httpStatus == -1`）绝不误判为 `AUTH_REQUIRED`，走重试后收敛为 **`ERROR`**。
- **HTTP 鉴权与 403 精细区分**：HTTP `401` 立即判定 **`AUTH_REQUIRED`** 并中止策略链；HTTP `403` 先检查是否为非鉴权业务 JSON 拒绝体（如动态码拒签），仅在无业务拒绝体或命中鉴权/CSRF 关键字时判 **`AUTH_REQUIRED`**，防止误杀后续兜底策略。
- **已签到优先于成功码**：命中 `alreadyKeywords`（`["已签到", "已经签到", "重复签到", "已参与"]`，已移除易误判的 `"签到成功"`，即便同时 `code == 0`）→ **`ALREADY`**（计入成功态，严格区分首次 `SUCCESS`）。
- **正常成功**：2xx 且 `code`/`errcode`/`error_code`/`status_code` 匹配 `profile.result.okCodes`（默认 `[0]`），或无非零业务码且 `{"success": true}` → **`SUCCESS`**。
- **业务鉴权失败**：非 HTML 响应命中 `authKeywords`（`["登录", "登陆", "未授权", "身份", "token", "会话", "unauthorized", "unauthenticated"]`，大小写不敏感；跳过 HTML `<script>` 避免误命中）→ **`AUTH_REQUIRED`**（iOS 侧对应 `AUTH_EXPIRED`），立即中止重试与策略链。
- **二维码过期与 404 防误判**：非 404 路由缺失响应命中 `expiredKeywords`（含 `"失效"`、`"过期"`、`"不存在"`、`"二维码已"`、`"dynamic qr check in refused"`、`"qr code expired"`、`"expired"`）→ **`TICKET_EXPIRED`**；若 HTTP `404` 返回「接口不存在」/「未知路径」/ HTML 404 / 空体，则按普通失败放行后续策略，**绝不误判为二维码过期**。
- **高价值失败原因保真**：策略链全部失败时保留最有信息量的业务错误（如 `50070`、`51203`、`DYNAMIC QR CHECK IN REFUSED`），不被尾部 404/HTML/本地安全拦截覆盖。
- **重试与退避**：仅对 `408 / 425 / 429 / 5xx` 及网络异常执行指数退避重试，**默认每策略最多尝试 3 次，基础退避 800ms**（`800ms -> 1600ms -> ...`，带上限防溢出；iOS 针对动态二维码收紧退避预算避免耗尽 5–8s 有效期）；重试耗尽收敛为 **`ERROR`**。
- **演练模式（`DRY_RUN`）**：`dryRun = true` 时**严格不发出任何网络请求**（跳过 `appScan`、`discover()` 与所有 HTTP 提交），仅生成可审查的请求轨迹并返回 `DRY_RUN`。
- **并发策略**：账号间并发（1–32 可调，默认 4，默认错开 60ms 起步），同一账号内策略严格串行。

---

## 5. 定位签到（`⚠️ 未验证`，仅静态接口记录，客户端未接入）

IPA 1.3.6 静态逆向提取到以下定位签到接口族：

```http
# 课堂定位签到（注意：session / overview / extend / end 属教师端控制接口）
/api/v3/lesson/location-checkin/{eligibility,preview,session,submit,overview,extend,end}

# 移动端定位配置与会话更新（IPA 实证路径为 /api/v3/location-checkin/update-session，非 mobile-setup/update-session）
/api/v3/location-checkin/mobile-setup/{detail,submit,verify}
/api/v3/location-checkin/update-session

# 腾讯位置服务代理
/api/v3/tencent-lbs/proxy
```

- `locationEligibility` 校验当前用户的定位签到资格，配置中需携带鉴权（`auth: true`）。
- **当前实现状态**：**Android / iOS / CLI 均尚未实现定位签到业务通道**（全仓零调用），`protocol/profile.json` 仅保留静态路径参考模板，待获授权实测真实请求/响应字段后再行评估是否接入。

---

## 6. 合规与安全边界

签到记录属于教学过程数据，代签行为会破坏课堂出勤统计的真实性。本工具仅面向自有账号、自有设备与离线本地演练环境（`tools/mock_server.py`）开展协议研究与工程验证：

- 仅内置官方公开站点域与本地 mock 环境，**不内置任何高校私有化子域名或第三方教务地址**；
- 仓库不包含任何真实账号、Cookie、Token 或签名证书；
- 不做验证码识别、不做风控对抗、不做批量注册；
- 真实环境使用前请确认所在学校与课程的相关规定。
