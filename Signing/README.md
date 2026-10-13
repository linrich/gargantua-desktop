# 本地开发签名

仓库不包含作者的证书配置、私钥或开发者账号信息。

## 默认：ad hoc 签名

没有 `Signing/LocalSigning.plist` 时，`zsh Scripts/build.sh` 使用 `codesign --sign -`，不访问个人签名私钥。适合自行编译和本地开发，不代表 Developer ID 身份、公证或 Gatekeeper 放行。构建内容改变时签名身份可能变化，因此录屏授权可能需要重新处理。

## 可选：固定自己的 Apple 开发证书

若已经拥有有效的 Apple 代码签名证书和对应私钥，可自行配置：

1. 将 `LocalSigning.example.plist` 复制为 `LocalSigning.plist`。
2. 从自己的钥匙串获取代码签名身份信息，填写证书 SHA-1 指纹和 Team ID；Bundle ID 必须与 `Resources/Info.plist` 一致。
3. 再执行构建脚本。配置存在时会固定使用该证书，严格核对指纹、团队与 Bundle ID，失败即停止，不回退到 ad hoc。

`LocalSigning.plist` 已被 `.gitignore` 排除。配置本身不应保存私钥；不要把 `.p12`、账号密码或令牌放入仓库。签名脚本使用钥匙串中的私钥，不导出它、不修改系统信任、不执行 `tccutil reset`，并禁用签名时间戳网络请求。

继续使用同一有效签名身份有助于系统识别更新，但不能保证所有系统上的录屏授权永久保留。证书轮换、到期或撤销需重新检查。

`Tests/verify_signing_continuity.py` 仅供配置固定证书后比较两个不同构建；它检查签名身份，不代替实际 macOS 更新和录屏授权验证。

## 向其他人分发 App

此处仅提供开发签名和 ZIP 打包。面向普通用户的 Developer ID 签名、Hardened Runtime、可信时间戳、公证及票据附加流程尚未集成。不要把“严格签名有效”等同于“已公证”。相关步骤见 [Apple 官方分发说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
