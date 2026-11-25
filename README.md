# YYMC iOS 版（源码 + CI 构建）

在 App 内起一个只绑 `127.0.0.1:8720` 的静态文件服务，WKWebView 直接加载它，于是页面是同源 http：`fetch` / Worker / WebAudio 全部正常，不需要 JIT、不需要越狱、不碰任何私有 API。

构建在 **GitHub Actions 的 macOS runner** 上完成（Windows 上无法编 iOS 二进制），产出 **unsigned `.ipa`**，签名交给本机 Sideloadly / AltStore。

## 目录

```
Sources/main.swift             AppDelegate + WKWebView + 极简 HTTP 服务（Range/MIME）
Info.plist                     横屏全屏、ATS 只放开本地网络
build.sh                       swiftc 编译 → 组 .app → 打 ipa
.github/workflows/ios.yml      CI：取 site/ 资源 → build.sh → 上传 artifact
```

## 构建

CI 每次 push 自动跑，或者 Actions 页面里 `workflow_dispatch` 手动触发。资源不放在本仓库，由 CI 从 `mdy114514mdy/yymc-desktop` 的 `site/`（148 MB）拉取。

本机想复现（需要 macOS）：

```bash
git clone --depth 1 https://github.com/mdy114514mdy/yymc-desktop.git _s
cp -R _s/site ./site
bash build.sh          # 产出 YYMC.ipa
```

## 安装（Windows，无需 Mac）

1. 下载 Actions 产物 `yymc-ios-ipa` → 解压得到 `YYMC.ipa`
2. Sideloadly：设备选你的 iPhone，Apple ID 已登录，把 ipa 拖进去 → Start
3. 手机上「设置 → 通用 → VPN与设备管理」里信任该开发者证书
4. 免费 Apple ID 签名有效期 **7 天**，到期重签一次

## 已知限制

- 用免费证书时 App 里不能带「推送/后台」等特权，本 App 也不需要。
- 只做了静态资源本地化；`?rooms=` 仍指向线上 Worker（登录/联机照常可用）。
- 系统要求 iOS 15+；不使用任何随版本变化的私有接口，所以未来 iOS 大版本（含 27）只要公开 API 不变就能跑。
