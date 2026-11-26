# YYMC iOS 版

在 App 内起一个只绑 `127.0.0.1:8720` 的回环服务，WKWebView 直接加载它，于是页面是同源 http：`fetch` / Worker / WebAudio 全部正常，**不需要 JIT、不需要越狱、不碰任何私有 API**。

登录、云存档、联机信令全部在设备内中转（App 里自己补 `Origin`），不依赖任何云端 Worker。

## 下载（Release 直链）

| 版本 | 文件 | 大小 | 直链 |
|---|---|---|---|
| v1.1.0 | `YYMC.ipa` | 104.0 MB | https://github.com/mdy114514mdy/yymc-ios/releases/download/v1.1.0/YYMC.ipa |
| v1.1.0 | 整页 | — | https://github.com/mdy114514mdy/yymc-ios/releases/tag/v1.1.0 |

> ipa 是 **unsigned** 的，安装时必须本机签名（Sideloadly / AltStore / 自己的证书）。

---

## 一、安装（Windows + Sideloadly，无需 Mac）

1. 下载 `YYMC.ipa`
2. Sideloadly 里选中 iOS 设备，把 ipa 拖进 IPA 框，Apple ID 已登录 → **Start**
3. 手机上「设置 → 通用 → VPN与设备管理」信任开发者证书
4. 桌面出现 **YYMC**，点开即玩（横屏全屏）

免费 Apple ID 签名 **7 天**到期，重跑一次 Sideloadly 即可（存档会随重装清空）；要更久就用付费开发者账号（1 年）或 TestFlight（90 天/版）。

## 二、构建（Windows 上无法编 iOS，交给 CI）

```bash
# 本地无需 Mac：push 到仓库，GitHub Actions 的 macOS runner 出包
git clone https://github.com/mdy114514mdy/yymc-ios.git
cd yymc-ios
git clone --depth 1 https://github.com/mdy114514mdy/yymc-desktop.git _s
cp -R _s/site ./site        # 资源不放在本仓库，CI 里自动拉
bash build.sh               # macOS 上执行：产出 YYMC.ipa
```

CI：`.github/workflows/ios.yml`，两个 job——`syntax`（ubuntu 上 `swiftc -parse` 快速语法检查）与 `build`（`macos-15`，实测只有这个标签能分到机器；`macos-14` 会被拒、`macos-13` 纯排队、`-large/-xlarge` 无权限）。

## 三、这一版实现了什么

| 路径 | 实现 |
|---|---|
| 静态资源 | bundle 里的 `site/`，支持 Range（206），MIME 按扩展名 |
| `/rooms/api/*` | `URLSession` 反代到 `https://xz.honghemc.cn:8443`，补 `Origin` / `Referer` |
| `/rooms/p2p` | WebSocket 隧道：解析浏览器 `Sec-WebSocket-Key` → CryptoKit 算 `base64(SHA1(key+GUID))` 应答 101 → 以 TLS（ALPN `http/1.1`）连上游握手并补 Origin → 双向原样搬字节 |

`Origin` 是浏览器的 forbidden header，页面 JS 与 WebSocket 握手都改不了，只能在浏览器之外补——这就是这层回环服务的唯一理由。

## 四、目录

```
Sources/App.swift              AppDelegate + WKWebView + 回环服务（静态/HTTP 反代/WS 隧道）
Info.plist                     横屏全屏、ATS 只放开本地网络
build.sh                       swiftc 编译 → 组 .app → 打 ipa（根必须是 Payload/）
.github/workflows/ios.yml      CI：语法检查 + macos-15 出包 + 上传 artifact
```

## 五、已知坑

1. `@main` 的文件不能叫 `main.swift`（会被当成顶层代码入口），本仓库用 `App.swift` + `-parse-as-library`。
2. `Data.subdata(in:)` 要 `Range`，不是 `ClosedRange`（写 `start..<(end+1)`）。
3. ipa 根目录必须是 `Payload/`，否则 Sideloadly 报「找不到 app」——`zip` 要在仓库根执行。
4. 免费签名 7 天，`Apple Mobile Device Service` 没启动时 Sideloadly 会看不到设备（`net start "Apple Mobile Device Service"`）。
5. 输 Apple ID 密码前先切英文键盘（中文输入法会把密码打成中文，报 `-22406`）。

---

# YYMC — iOS build (English)

A WKWebView app that runs a loopback server bound to `127.0.0.1:8720` and loads the game from it. Because the page is served over plain `http://127.0.0.1`, it keeps a real same-origin http context: `fetch`, Workers and WebAudio all work. **No JIT, no jailbreak, no private APIs.**

Sign-in, cloud saves and multiplayer signalling are relayed **on the device** (the app adds the `Origin` header itself) — no cloud worker required.

## Download (release direct link)

| Version | File | Size | Direct link |
|---|---|---|---|
| v1.1.0 | `YYMC.ipa` | 104.0 MB | https://github.com/mdy114514mdy/yymc-ios/releases/download/v1.1.0/YYMC.ipa |
| v1.1.0 | release page | — | https://github.com/mdy114514mdy/yymc-ios/releases/tag/v1.1.0 |

The ipa is **unsigned** — you must sign it locally (Sideloadly / AltStore / your own certificate).

## Install (Windows + Sideloadly, no Mac needed)

Drag `YYMC.ipa` into Sideloadly with the device connected and your Apple ID signed in, hit **Start**, then trust the developer certificate under Settings → General → VPN & Device Management. A free Apple ID signature lasts **7 days**; re-sign to keep playing (reinstalling wipes the app sandbox). Use a paid developer account (1 year) or TestFlight (90 days per build) for longer.

## Build

iOS binaries can only be produced by Apple's toolchain, so the build runs on **GitHub Actions' macOS runner**. Locally you only need to push:

```bash
git clone https://github.com/mdy114514mdy/yymc-ios.git
cd yymc-ios
git clone --depth 1 https://github.com/mdy114514mdy/yymc-desktop.git _s
cp -R _s/site ./site      # assets live in the desktop repo; CI fetches them too
bash build.sh             # on a Mac: produces YYMC.ipa
```

`ios.yml` runs two jobs: `syntax` (`swiftc -parse` on ubuntu, fast feedback) and `build` on `macos-15` — the only label that actually gets a runner on a free plan (`macos-14` is rejected, `macos-13` queues forever, the `-large`/`-xlarge` labels are not entitled).

## What this build implements

| Path | Implementation |
|---|---|
| static assets | `site/` from the bundle, with Range support (206) |
| `/rooms/api/*` | `URLSession` proxy to `https://xz.honghemc.cn:8443`, adding `Origin` / `Referer` |
| `/rooms/p2p` | WebSocket tunnel: read the browser's `Sec-WebSocket-Key`, answer `101` with `base64(SHA1(key+GUID))` computed via CryptoKit, open a TLS (ALPN `http/1.1`) upstream connection with `Origin`, then relay frames verbatim |

`Origin` is a forbidden header — neither page JS nor a WebSocket handshake can set it — which is the only reason this loopback layer exists.

## Layout

```
Sources/App.swift   AppDelegate + WKWebView + relay (static / HTTP proxy / WS tunnel)
Info.plist          landscape-only, fullscreen, ATS local-networking only
build.sh            swiftc -> .app -> ipa (the archive root must be Payload/)
.github/workflows/ios.yml   CI: syntax check + macos-15 build + artifact upload
```

## Known pitfalls

1. A file containing `@main` must not be named `main.swift` (treated as top-level code) — this repo uses `App.swift` plus `-parse-as-library`.
2. `Data.subdata(in:)` takes a `Range`, not a `ClosedRange`.
3. The ipa root must be `Payload/`, otherwise Sideloadly reports "no app found in ipa" — zip from the repository root.
4. Sideloadly cannot see the device while `Apple Mobile Device Service` is stopped (`net start "Apple Mobile Device Service"`).
5. Switch to an English keyboard before typing the Apple ID password — an IME will turn it into Chinese characters and Apple replies `-22406`.

## Notes

Self-signed for sideloading only. No app icon yet (system default). No account/recovery tooling in this repository.
