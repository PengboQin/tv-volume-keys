# 电视音量键 · TV Volume Keys

免费、开源的 macOS 菜单栏工具，让 Mac 音量键控制外接电视。支持默认 HDMI-CEC，以及明确配置的 **ADB 兼容模式**，用于当前 CEC 链路不可用的 Android 电视。

**0.2.0-preview.1 仍是实验预览。** 官方发行使用 Developer ID 签名，实际苹果公证结果见发行附件 `release-validation.json`；自行构建默认 ad-hoc。不承诺所有 Mac、电视、转接器和固件兼容。

## 需要什么

- Apple 芯片 Mac、macOS14及以上、单个外接屏幕，默认声音输出走 HDMI。
- CEC 模式需要兼容的 Mac/转接器/电视连接；此前 M4 Mac mini 已有实际音量键依据。
- ADB 模式需要 Android 电视开启网络调试、Mac 已有[官方 Android Platform Tools](https://developer.android.com/tools/releases/platform-tools)、电视局域网 IPv4/端口，并在电视上授权这台 Mac。程序不会下载工具、扫描局域网、开启调试或修改路由。
- 本次 M1 当前链路没有可用 CEC 地址；独立 ADB 音量通道已验证，见[M1验证记录](docs/M1验证与ADB通道.md)。新版本的安装/按键结果以本版发行验证记录为准。
- 后续已完成该 M1 的新版安装和 **ADB 通道**物理键盘控制验收，见[装机与权限恢复](docs/M1安装与权限恢复.md)；此 M1 链路的 CEC 仍不可用。这是一个实际连接的结果，不代表全部 M1/电视兼容。

它调节电视的音量设置，不取代 macOS 的 HDMI 音量滑块，也不能经光纤直接调外接音响本体。应用自行选择声音输出、独占音频或外接音响链路仍可能影响实际响度。CEC 路径使用非公开 IOKit 接口，系统升级后可能需要适配。

## 下载与使用

从[本仓库 Releases](https://github.com/PengboQin/tv-volume-keys/releases)下载，核对 SHA256SUMS，将 **TV Volume Keys Preview.app** 放入“应用程序”。不要关闭 Gatekeeper；先保留原有可用版本。

1. Mac 声音输出选 HDMI 电视，打开菜单栏 **TV**。
2. CEC：保持 **HDMI-CEC（默认）**，电视打开 CEC。
3. ADB：选 **配置 ADB 连接…**，填自己的局域网地址和端口，例如 `192.168.1.50:5555`，再填官方 adb 可执行文件的绝对路径。电视弹出这台 Mac 的授权时，由用户允许。“验证并使用 ADB”会绑定电视身份。可随时在菜单切回 CEC。
4. 选 **允许键盘控制…**，在系统“隐私与安全性 → 辅助功能”开启本 App。升级改变签名身份时，可能需要用户重新授权。
5. 按音量加减或静音；顶行设为标准 F 键时同时按 Fn。

若辅助功能已经开启但键盘仍不生效，升级后的旧条目可能没有授权到当前签名的 App。先检查菜单状态；仍提示等待权限时，在辅助功能中移除旧条目，再从“应用程序”重新添加 **TV Volume Keys Preview.app** 并开启。不要重置其它 App 权限或关闭系统保护；详见[恢复步骤](docs/M1安装与权限恢复.md)。

菜单的加减/静音与键盘使用同一通道；支持暂停、退出和可选登录启动，安装不会自动开启登录项。Option/Command/Control 与媒体键组合交回系统；切到耳机或外接屏幕不明确时不接管。忙时丢弃重复，不积压到松手后；静音长按不会反复切换。

ADB 必须显式选择，CEC 失败不会自动改控猜测的电视。每次发送校验设备身份，并绑定当次活跃 transport；IP 被 DHCP 复用时拒绝控制。断线/未授权会显示错误，不自动重发音量动作。加减使用媒体音量接口，静音使用电视音量静音键；其它电视及音频流行为需按实际固件核对。

## 构建与命令行

需要已有 Xcode 命令行工具和 Python3，无第三方依赖下载：

```sh
python3 scripts/build.py --dry-run
python3 scripts/build.py --package
# 可选 --sign-identity '自己的 Developer ID Application 身份'
```

固定 `.build/` 与 `dist/`。构建包含宿主按键分流/ADB目标绑定/超时检查、签名和DMG核验；Git工程打包要求输入已提交。不会自动安装、启动、公证或上传。`.build/` 和 `dist/validation-local.json` 可能含本地诊断，不作为公开附件；正式校验和应在签名、公证和stapling后重算。

可显式用 App 可执行文件的 `--diagnose` 只读检查；`--configure-adb 局域网IP:端口 --adb-path /绝对路径/adb` 保存当前用户的连接，或 `--use-cec` 选回CEC。命令行配置后退出并重新打开GUI。`--send up|down|mute` **会真实调节电视音量**，只用于已授权验证；没有任意shell执行入口。

## 隐私与风险

不记录普通文字，不上传数据。权限/就绪状态和命令计数仅在本机；ADB地址、路径及电视身份哈希存于用户私有文件，不进入安装包或公开摘要。现有ADB密钥由官方工具管理，程序不读取或导出。

ADB本身具有比音量控制大得多的权限，应只用于可信局域网，不公开到互联网，陌生电脑应撤销授权。这不是最小权限电视协议。本工具不修改信号源、分辨率、音频路由、电源、VPN、固件或系统包。

源码MIT；[兼容性与分发](docs/兼容与分发.md)、[来源与许可证](THIRD_PARTY_NOTICES.md)。源码/构建、签名公证、安装、普通启动、键盘链路和实际听感分别验证，不以宿主测试通过代替用户验收。
