# Dayreed 更新与本地发布准备

关联 [Issue #6](https://github.com/Kamisato-Yuna/Dayreed/issues/6)。脚本可构建、签名、公证并准备本地资产；不会创建 tag、上传 GitHub Release 或覆盖已有资产。功能集成完成后，由维护者串行执行真实公证、安装更新验收与发布。仅有编译/合成测试通过不代表已发布或客户端更新验收完成。

## 更新服务与 App 接线

SwiftPM 引入官方 Sparkle 2.9.6 及后续兼容版本；解析结果在 `Package.resolved`。产品名、版本、build、最低 macOS 来源仍为 `DayreedCore.ProductInfo`，App plist 由内置 CLI 的 `version --json` 生成。

`DayreedUpdate.UpdateController` 是 `@MainActor ObservableObject`。App 生命周期持有一个实例，在 App 完成启动后调用 `start()`；构造对象不会启动检查。主 UI 可使用：

```swift
import DayreedUpdate

// App 层持有一次，Settings / commands 共享同一个对象。
@StateObject private var updates = UpdateController()

// App 启动完成后：updates.start()
// 手动按钮：updates.checkForUpdates()
// 按钮禁用：!updates.canCheckForUpdates
// 设置读取：updates.automaticallyChecksForUpdates
// 用户设置写入：updates.setAutomaticallyChecksForUpdates(enabled)
```

`state` 提供 `.unavailable(String)`、`.idle`、`.checking`、`.available(version:)`、`.noUpdate`、`.downloading`、`.installing`、`.cancelled`、`.failed(code:)`。`idle` 仅表示尚未检查，`noUpdate` 表示没有可安装更新（也可能不满足系统/硬件要求），不能显示成已确认最新版本。未打成完整 App、缺失更新配置时为 unavailable；feed 尚未发布/签名不正确时为实际检查失败。没有成功下载、安装及重启回调时，不能显示安装成功。Sparkle 标准原生窗口处理下载进度、安装与重启；本模块不自行替换正在运行的 App。

默认关闭自动检查，用户在设置中主动开启后由 Sparkle 调度；每次安装仍需确认。设置由 Sparkle 保存在独立 `YunaBuild.Dayreed.Sparkle` preferences domain，不另存第二份状态。`SUEnableSystemProfiling` 和 `SUSendProfileInfo` 明确关闭；初始化与每次检查都确保不发送系统信息。无自定义请求参数、发布说明下载或 JavaScript。更新网络请求仍会像普通 HTTPS 请求一样向 GitHub 暴露 IP 和 HTTP 客户端标识。

## 来源与更新签名

公开配置在 `Resources/Updates/UpdateConfig.plist`。唯一 feed 为：

`https://github.com/Kamisato-Yuna/Dayreed/releases/latest/download/appcast.xml`

delegate 返回固定 feed，已有 `SUFeedURL` defaults 不能覆盖它。选中更新的 ZIP URL 必须属于 `https://github.com/Kamisato-Yuna/Dayreed/releases/download/v<version>/Dayreed-<version>.zip`；第三方/旧仓库、HTTP、用户信息、端口、query、fragment、编码路径和非 ZIP 来源会被拒绝。发行脚本当前只生成完整 ZIP，不生成 delta；客户端也检查 delta enclosure，非许可 ZIP 会拒绝整项更新。GitHub Release 自身的 HTTPS 重定向会经过 GitHub 的资产 CDN；最终下载字节仍必须通过 EdDSA 验证。

feed 本身要求签名，且失败不会超时降级；ZIP 在提取前验证。原因是更新链会安装可执行代码，Git/版本号/普通测试无法证明客户端收到的远端 feed 和 ZIP 是维护者签署的原始字节。不存在旧 feed、旧命名空间或旧密钥迁移。

独立 Sparkle 密钥位于 Keychain service `https://sparkle-project.org`、account **`YunaBuild.Dayreed.Sparkle`**。这里只使用 Sparkle 官方工具的 `--account`，不使用默认 `ed25519` account。公钥已提交，私钥不导出、不写日志。`generate_keys` 在指定 account 已存在时读取而不覆盖；不带 `--account` 的生成/签名命令禁止用于 Dayreed。

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account YunaBuild.Dayreed.Sparkle -p
```

上述命令只读取公开公钥。丢失密钥时不要随意重新生成后继续发布：当前 ZIP 提取前验证不接受任意换 key。需要按 Sparkle 官方 key rotation 流程单独处理。

## 构建、签名与公证

开发机需要 macOS 26+、支持 Icon Composer 的 Xcode、Swift 6.2+、Python 3.9+。默认只构建当前主机架构；本轮实测为 arm64，不能声称提供 Universal/Intel 版本。

```sh
./script/build_app.sh debug
./script/build_app.sh release
```

两者均输出本地 ad hoc App。`ditto` 完整复制 Sparkle 的版本目录/符号链接/执行权限，保留 Icon Composer 的 Assets.car、icns、元数据及 Resources 内许可证。`sign_app.sh` 依次签 Installer.xpc、Downloader.xpc（保留其 entitlements）、Autoupdate、Updater.app、framework、CLI helper、外层 App。签名不使用 `--deep`；验证使用 `--deep --strict`。正式签名添加 hardened runtime 和 timestamp；没有扩大 App entitlements。打包成功才替换上一次开发包，构建失败保留原包。

App 内附带原样 CLI 安装脚本：

```sh
bash /Applications/Dayreed.app/Contents/Resources/install_cli.sh install --app /Applications/Dayreed.app
```

这会按安装脚本既有规则验证 App/helper，并默认链接到 `~/.local/bin/dayreed`；不要求用户另取源码。

准备正式本地候选资产前，明确指定既有 notarytool profile。不要扫描通用 Keychain 猜测名称，也不要把密码、私钥或证书导出放进配置：

```sh
cp script/release.env.example script/release.env
chmod 600 script/release.env
# 编辑 SIGN_ID 与 NOTARY_PROFILE；profile 必须已经存在。
./script/notarize.sh --output build/releases/candidate
```

已授权的发布身份为 `Developer ID Application: Yuna Kamisato (852H844JG2)`。`release.env` 必须属于当前用户、仅 owner 可访问、不是符号链接，只接受唯一 `SIGN_ID` 和 `NOTARY_PROFILE` 字段；不执行 shell 展开。也可用同名环境变量显式提供这两个非秘密名称。

流程会：构建 Release；核对独立 Keychain 公钥；复制 App 到忽略的 `docs/local/releases/notary-*`；完成全部嵌套 Developer ID 签名并验证 Team/identity/runtime；提交 Apple 公证并要求 Accepted；staple/validate、strict 签名及 `spctl` 通过后，从该 App 生成最终 ZIP，再由官方 `generate_appcast` 生成并签署 appcast。最终 ZIP 是 staple **之后**的制品；feed 的版本、build、最低系统与下载路径全部从此 App 得到，并用 `sign_update --verify` 实际验证 ZIP 和 feed。

生成器缓存隔离在本次临时目录，已有输出目录直接拒绝。失败不会覆盖原发布资产，也不会上传任何 GitHub 资产；Apple 失败记录和已签名副本留在 `docs/local/` 供本地复核。签名、公证、EdDSA 是独立步骤，任何一步失败都不等价于已完成更新。

已公证并 staple 的候选 App 也可重复准备到另一个新目录：

```sh
python3 script/prepare_appcast.py /path/to/Dayreed.app build/releases/another-candidate
```

发布由维护者另行授权执行：核对工作区与目标源码提交，完成中文发布说明，从该提交制作 App 对应的签名 `v<version>` tag，将 `Dayreed-<version>.zip` 和 `appcast.xml` 放在 **同一个** Dayreed Release；不得覆盖已发布同版本资产或移动 tag。feed 指向 GitHub latest Release，因此不能把旧 feed 误留在新 latest Release。先创建 draft Release 并核对实际下载、解压、签名、安装和启动，再决定公开发布。这里不提供自动发布或强制覆盖开关。CI 继续负责无凭据构建与测试，证书、私钥和密码不上传到仓库或 GitHub Actions；每次发布单独核对目标制品的签名与公证结果，不以另一制品的成功替代。

## 验证与真实客户端验收

```sh
swift test --filter DayreedUpdateTests
./script/build_app.sh debug
python3 Tests/Scripts/test_release.py
```

测试使用临时 App/偏好域与公开 RFC 8032 测试密钥，不使用真实更新私钥或用户记录。覆盖：实际 Sparkle delegate 压过旧 feed defaults、关闭 profiling、来源拒绝、错误/无更新/取消状态、framework 与安装脚本打包结构、签名 ZIP/feed 生成验证、异钥和篡改拒绝、版本来源、配置权限与 shell 注入拒绝、构建失败和已有输出保留。Sparkle 工具需要系统文件类型识别服务；沙箱拒绝 LaunchServices 时应在允许的本地测试环境运行，不能把失败报告成通过。

发布前的客户端证据仍需维护者在隔离 macOS 用户或 VM 中取得：

1. 使用同一 Developer ID 和独立 Dayreed 更新 key 的旧/新候选包，全部采集保持关闭，App Support 与 preferences 为合成数据。
2. 从自己的 GitHub Release 下载旧包，证明 Gatekeeper、启动、内置 CLI 与安装脚本可用。
3. 开启/关闭自动检查并重启，证明设置保留；手动检查后证明发现新 build、真实下载、安装、重启到新版本。
4. 再检查，证明没有可安装更新且不重复安装；分别记录无网络、下载取消等真实状态。
5. 通过隔离测试制品验证异常来源、损坏 ZIP、异钥/损坏 feed 的拒绝。不得修改生产 App 以添加任意 feed 开关，也不得用本机 fixture 或签名工具验证代替实际客户端拒绝证据。

此时尚未完成真实公证或上述客户端路径时，应保持 Issue #6 未完成，不称为已完成验收的发布。

官方依据：[集成与签名 feed](https://sparkle-project.org/documentation/)、[程序化 API](https://sparkle-project.org/documentation/programmatic-setup/)、[设置与安全配置](https://sparkle-project.org/documentation/customization/)、[嵌套签名顺序](https://sparkle-project.org/documentation/sandboxing/)。
