# 雨课堂签到协议事实集（IPA 1.3.6 静态逆向 + 外部脚本推断边界）

本文件是 RainCheck 多端（`core` / CLI / Android / iOS）共用的协议基线与证据溯源说明。
本仓库**严格区分两类来源**，不做混淆：

1. **IPA 1.3.6 静态逆向实证**：提取自本地 `雨课堂_1.3.6.ipa`（`work/rainclassroom-ipa/`，基于 `App.framework/App`、资源目录与静态路由/字符串分析，全程离线、未做实网抓包）。
2. **Web 端浏览器接口适配**：面向雨课堂网页端上下文的 `X-Client: web`、`xtbz: ykt`/`xt`、同源 `Origin`/`Referer` 以及 Web PC 手机号短信登录路由（`/pc/login/send_sms_login_code/`、`/pc/login/verify_pwd_login/`）；该组 Web 路径在 IPA 1.3.6 全包 721 文件中 **0 命中**（IPA 移动端对应 `/api/v3/user/code/send` 与 `/api/v3/user/login/app`）。
3. **`⚠️ 未实网验证（外部桌面脚本推断）`**：参考公开桌面端实现（`ZhengXieGang/YuKeTang-CheckIn-Helper`）交叉推断的扫码登录 4 端点轮询链与动态码载荷；该部分在 IPA 1.3.6 全包 721 文件中 **0 命中**，尚未经真实课堂动态抓包验证。

> **关于配置生效方式**：协议端点、请求体模板与策略顺序集中维护在 [`protocol/profile.json`](../protocol/profile.json)。**仅 CLI 支持运行时通过 `--profile <path>` 切换外部协议文件**；Android 与 iOS 客户端不提供外部 profile 热更新，变更协议时需同步更新 `protocol/profile.json` 及两端资源副本后重新构建（CI 强制校验字节级 SHA-256 一致）。

---

## 0. 核心结论与静态逆向未决风险

- 从离线静态证据与公开桌面脚本综合判断，签到核心链路可抽象为三组 HTTPS 接口：
  1. 账号会话获取（iOS 端 Web 手机号短信验证码登录、CLI/Android 扫码登录或导入已有会话凭据）；
  2. 课堂上下文查询（获取进行中课堂 `lessonId` / `classroomId`）；
  3. `POST /api/v3/lesson/checkin` 提交签到。
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

### 2.1 请求头（Web 端上下文适配）

RainCheck 统一采用雨课堂官方 Web 端请求头集合（配置于 `protocol/profile.json`，由 `core/Api.kt` 与 `iosApp/.../RainCheckClient.swift` 动态补齐同源 `Origin`/`Referer` 并按主机自动切换 `xtbz`），以确保 Web 登录或手动导入的 `sessionid` Cookie 稳定通过服务端鉴权：

```http
xtbz: ykt                              # 雨课堂各站点默认 ykt；学堂在线（xuetangx.com 及子域）自动切换为 xt；IPA 移动端为查询参数 ?xtbz=ykt-app&app_version=
X-Client: web                          # Web 端标识（IPA 移动端实存小写 x-client）
Origin: https://<host>                 # 与当前请求目标严格同源
Referer: https://<host>/v2/web/index   # 默认同源 Web 入口（/pc/login/* 请求为 https://<host>/web；签到上下文请求可覆盖为 /v2/web/studentLog/<classroomId>）
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36
Accept: application/json, text/plain, */*
Authorization: Bearer <token>          # IPA 实证：Bearer 鉴权载体
Cookie: sessionid=<sid>; csrftoken=<csrf>   # IPA 实证：Cookie 鉴权载体
X-CSRFToken: <csrf>                    # IPA 实证：存在 csrftoken 时附带
```

> **IPA 实存但 Web 端未使用的请求头**：`App.framework` 中还实存 `X-UID` 与 `classroom-id`（移动端上下文标识），若后续真机抓包确认需要，可通过 `profile.json` 增补。

- **双载体鉴权（IPA 实证）**：同时支持 `Authorization: Bearer` 与 `Cookie: sessionid` + `X-CSRFToken`，任一有效即可发起业务请求。
- **会话刷新回填（IPA 实证）**：响应头出现 `Set-Auth` / `Authorization` 或 `Set-Cookie` 时自动回填并更新当前会话（`set-auth` 优先级高于 `authorization`；忽略空值或 `Max-Age=0` 的清 Cookie 响应头；失败响应不刷 `lastOkAt`）。
- **响应信封兼容**：主协议为 `{"code": 0, "msg": "...", "data": {...}}`，同时兼容旧版/微信接口的 `errcode` / `errmsg`（`profile.json` 中 `altCodeKeys` / `altMessageKeys`）。

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

### 4.2 提交策略链（`⚠️ 动态码载荷与 source=14/5/1 未实网验证（外部桌面脚本推断）`）

按 `protocol/profile.json` 中 `strategies` 顺序逐个尝试，命中即停：

| # | 策略 ID | 请求 | 证据状态 |
|---|---|---|---|
| 1 | `DYN_TICKET_14` | `POST /api/v3/lesson/checkin` `{"lessonId":"<id>","source":14,"ticket":"<c>","t":"<t>","s":"<s>"}` | 路径获 IPA 实证；`source=14` 与 `ticket/t/s` 载荷 **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 2 | `DYN_TICKET_5` | 同上，`source=5`（推断小程序来源） | 路径获 IPA 实证；`source=5` **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 3 | `LESSON_DESKTOP` | `POST /api/v3/lesson/checkin` `{"lessonId":"<id>","source":1}` | 路径获 IPA 实证；`source=1` **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 4 | `LESSON_WEB` | `POST /api/lesson/web_check_in` `{"lessonId":"<id>","source":1}` | 路径获 IPA 实证（另 IPA 实存 `/wxapi/lesson_check_in`）；请求体 **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 5 | `QR_URL_POST` | 直接向二维码 URL 发起 POST，体 `{"c","t","s","v"}` | **`⚠️ 未实网验证（外部桌面脚本推断）`** |
| 6 | `QR_URL_GET` | 直接向二维码 URL 发起 GET | **`⚠️ 未实网验证（外部桌面脚本推断）`** |

#### 安全约束：`QR_URL_POST` / `QR_URL_GET` 域名与 Scheme 白名单

为彻底杜绝恶意二维码诱导客户端外泄全池凭据（SSRF / Token 窃取 + 响应头会话投毒），引擎（Kotlin `core` 与 Swift `iosApp`）在执行 `QR_URL_POST` / `QR_URL_GET` 前强制执行以下校验：

1. **Scheme 白名单**：仅允许 `https`；仅当目标 host 与当前 `account.host`（显式配置为 `http`）或 `profile.editions` 中声明为 `http` 的站点（如本地 `mock`）精确匹配时，才允许 `http`。
2. **Host 白名单**：二维码 URL 的 `host[:port]`（大小写不敏感）必须严格匹配当前 `account.host`、`profile.editions` 或 `profile.qr.allowedUrlHosts`（内置 6 个合法站点域）白名单列表。
3. **拒绝行为**：任何不匹配白名单的外部 URL 直接拦截并记录安全拒绝轨迹，**绝不发送 `Authorization` / `Cookie` / `X-CSRFToken`，绝不吸收对方响应头**；同时移动端默认关闭「扫到即自动签到」（`autoSignOnScan = false`），需用户确认后执行。

### 4.3 状态机、幂等与重试语义

- **网络异常优先**：网络层失败（`httpStatus == -1`）绝不误判为 `AUTH_REQUIRED`，走重试后收敛为 **`ERROR`**。
- **HTTP 鉴权拦截**：HTTP `401`/`403` 立即判定 **`AUTH_REQUIRED`**，终止策略链且不重试。
- **已签到优先于成功码**：命中 `alreadyKeywords`（`["已签到", "已经签到", "重复签到", "已参与"]`，已移除易误判的 `"签到成功"`，即便同时 `code == 0`）→ **`ALREADY`**（计入成功态，严格区分首次 `SUCCESS`）。
- **正常成功**：2xx 且 `code`/`errcode` 匹配 `profile.result.okCodes`（默认 `[0]`）→ **`SUCCESS`**。
- **业务鉴权失败**：非成功响应（含 HTTP 200）命中 `authKeywords`（`["登录", "登陆", "未授权", "身份", "token", "会话", "unauthorized", "unauthenticated"]`，大小写不敏感）→ **`AUTH_REQUIRED`**（iOS 侧对应 `AUTH_EXPIRED`），立即中止重试与策略链。
- **二维码过期立即中止**：命中 `expiredKeywords`（即使伴随 5xx）→ **`TICKET_EXPIRED`**，立即停止重试并中止后续策略（当 `stopOnExpired = true` 时）。
- **重试与退避**：仅对 `408 / 425 / 429 / 5xx` 及网络异常执行指数退避重试，**默认每策略最多尝试 3 次，基础退避 800ms**（`800ms -> 1600ms -> ...`，带上限防溢出）；重试耗尽收敛为 **`ERROR`**。
- **演练模式（`DRY_RUN`）**：`dryRun = true` 时**严格不发出任何网络请求**（跳过 `discover()` 课堂发现与所有 HTTP 提交），仅生成可审查的请求轨迹并返回 `DRY_RUN`。
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
