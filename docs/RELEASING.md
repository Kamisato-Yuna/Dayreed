# 发布 Dayreed

当前工程版本目标为 **1.0.0 (1)**，尚未发布。基础外壳不能作为功能完整的 1.0 发布。

## 身份与来源

- App：Dayreed，Bundle ID：`YunaBuild.Dayreed`，最低 macOS 26。
- 唯一正式源码与 Release 仓库：`Kamisato-Yuna/Dayreed`。
- 版本来源：`Sources/DayreedCore/ProductInfo.swift`。打包脚本从同一 CLI 输出生成 Info.plist。
- 不复用旧应用的数据、Keychain、URL scheme、更新 feed 或版本序列。

## 本机签名与公证

维护者已允许正式发布时使用其现有开发者凭据。凭据留在本机；不把证书、私钥或密码上传到仓库或 GitHub Actions。配置本地忽略文件：

```sh
cp script/release.env.example script/release.env
# 填写已有 Developer ID Application 身份和 notarytool Keychain profile 名称。
./script/notarize.sh
```

脚本构建 Release App，先签名内置 CLI，再签名 App，提交 Apple 公证并核对 Accepted，随后 staple、验证并重新打包 ZIP。没有 App Store 权限需求时，不新增 provisioning profile 或 entitlement。后续引入框架/helper 时同步检查嵌套签名，不使用签名降级绕过问题。

该脚本只生成本地产物，不创建 Git tag 或 GitHub Release。每次发布检查实际源码、版本、签名身份、目标文件、签名与公证结果；不要把一次公证成功当作其他产物的证明。

## GitHub Release

1. 完成功能与本轮验收；核对工作区和目标提交。更新版本并形成中文发布说明。
2. 从该提交制作签名 tag，例如首版 `v1.0.0`。不要强制移动已发布 tag 或覆盖同版本制品。
3. 先在本仓库创建 draft Release，上传公证后的 ZIP，核对下载、解压、签名、安装和启动结果后再公开发布。
4. 自动更新功能接入后，以本仓库的实际 Release 下载地址生成签名更新元数据，并验证发现、下载、安装、重启及无更新场景。当前尚未实现自动更新，不能仅凭 Release 页面宣称已有此能力。

CI 负责无凭据构建与测试。生产签名、公证记录保存在本地忽略目录，公开发布说明只包含适合分发的信息。
