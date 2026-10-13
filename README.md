# PadLink：把 Android 平板变成 Mac 的可触控副屏

*Use an Android tablet as a low-latency, touch-enabled extended display for macOS, over Wi-Fi or USB-C.*

Mac 端 `PadLink.app`（菜单栏程序）新建一块与平板分辨率一致的虚拟显示器，用硬件 HEVC 编码实时推给平板；平板端「Mac 副屏」App 硬件解码显示，并把手指、手写笔、鼠标和键盘操作回传给 Mac。支持 Wi-Fi 和 USB-C 有线两种连接。

## 组成

| 目录 | 内容 |
|---|---|
| `mac/` | Mac 端菜单栏程序（Swift）：虚拟显示器、ScreenCaptureKit 采集、VideoToolbox 编码、输入注入、Wi-Fi / USB 连接 |
| `android/` | 平板端 App（Java）：MediaCodec 低延迟解码、触控 / 手写笔 / 键盘回传、后台待命服务、USB 配件模式 |
| `tools/latency-probe/` | 端到端延时测量：同一张平板截图里同时读出 Mac 时钟和平板时钟 |

## 运行环境

- Mac：Apple 芯片，macOS 14 及以上（开发与实测：macOS 27 / Apple M5）。
- 平板：Android 12 及以上，支持 HEVC 或 H.264 硬件解码（开发与实测：小米平板 8 Pro / 澎湃 OS 3 / Android 16）。
- 解码器会优先选厂商的低延迟组件（高通 `*.low_latency`、联发科 `*.lowlatency`）。

## 性能

端到端延时 = Mac 上画出一帧 → 平板屏幕合成出这一帧，用 `tools/latency-probe` 测得（3200×2136；除标注有线外均为 Wi-Fi；PadLink 每组 30 个样本，AirPlay 14 个）：

| 方案 | 中位数 | p90 |
|---|---|---|
| 系统自带 AirPlay 无线副屏（小米互联） | 113 ms | 130 ms |
| PadLink 60 Hz | 39 ms | 64 ms |
| PadLink 120 Hz（平板作副屏，内容 60 fps） | 30 ms | 39 ms |
| PadLink 120 fps 模式（平板作主显示器，内容约 105 fps） | 30 ms | 37 ms |
| PadLink 120 fps 模式 + USB-C 有线 | 24 ms | 33 ms |

PadLink 各行的测试条件：没有同时连着 AirPlay 副屏；Wi-Fi 各行 Mac 已关闭 AWDL（原因见「故障排查」）。USB-C 有线时传输耗时中位数 0.4 ms、p95 1.4 ms，不受无线干扰。

## 从源码构建

**Mac 端**

```bash
brew install libusb          # 静态链接进 App
bash mac/build.sh            # 首次会运行 make-signing-identity.sh 生成本机自签名证书
cp -R mac/build/PadLink.app /Applications/
```

PadLink 用一个只存放本机自签名证书的独立钥匙串（`~/Library/Keychains/padlink-signing.keychain-db`）签名。这样每次重新编译后签名要求不变，「屏幕录制」「辅助功能」授权不会失效。钥匙串口令可用 `PADLINK_KEYCHAIN_PASSWORD` 指定。

**平板端**

需要 Android SDK 的 build-tools、`platforms/android-35` 和 JDK 17，不需要 Gradle：

```bash
ANDROID_SDK=~/android-sdk bash android/build.sh     # 输出 android/build/PadLink.apk
adb install -r android/build/PadLink.apk
```

## 首次设置

**Mac**
1. 打开 `/Applications/PadLink.app`，菜单栏出现平板图标。
2. 系统设置 → 隐私与安全性：在「屏幕与系统录音」「辅助功能」中打开 PadLink。
3. 菜单栏 PadLink →「登录时启动 PadLink」（可选）。
4. 使用鼠标穿越时，另需在「输入监控」中打开 PadLink。

**平板**（设置 → 应用管理 → Mac 副屏 → 权限，各品牌名称略有不同）
1. 允许「显示在其他应用上层 / 悬浮窗」；国产系统另需允许「后台弹出界面」。允许后，Mac 端选中平板时副屏会自动弹出。
2. 允许「自启动」（可选）：平板重启后自动进入待命。
3. 打开一次「Mac 副屏」App，通知栏出现「Mac 副屏 · 待命中」即可。

## 使用

**Wi-Fi**
- 在平板上打开「Mac 副屏」，Mac 自动连接；或
- 在 Mac 菜单栏 PadLink 中点选平板名称，平板自动弹出副屏。再点一次断开。

**USB-C 有线**
- 用支持数据传输的 USB-C 线连接 Mac 与平板。平板弹出「是否打开 Mac 副屏」时点确定（可勾选默认打开）。
- Mac 首次接入时如提示「允许配件连接」，选择允许。
- 有线连接优先于 Wi-Fi，不受无线干扰，同时为平板充电。

**断开**：Mac 菜单中再次点选平板；或在平板上连续两次返回手势。平板切到其他应用 60 秒后自动断开。

**鼠标穿越（不开副屏时，用 Mac 的鼠标键盘直接操作安卓）**
- 菜单栏 PadLink →「鼠标穿越到平板」→ 选择平板在 Mac 的左侧或右侧。指针推过该侧屏幕边缘即进入平板，往回推过平板边缘回到 Mac。
- 平板上出现的是安卓原生鼠标指针，所有应用都可用；Cmd+C / V / Z / A 在平板上就是复制、粘贴、撤销、全选。
- 通道：插着 USB 线时走安卓配件协议的 HID 功能；否则经 adb（平板需开启无线调试并已与这台 Mac 配对）。
- Mac 需在「隐私与安全性 → 输入监控」中允许 PadLink。穿越期间触控板的系统手势（切换桌面、调度中心）被忽略。
- 副屏连接时鼠标穿越自动停用。

**共享剪贴板**：菜单栏 PadLink →「共享剪贴板」。Mac 与平板之间双向同步文字，经 adb 通道。

**外接键盘的 Win 键**：平板「设置 → 无障碍」中打开「Mac 副屏键盘」后，Win 键及 Win 组合键在副屏中作为 Command 发往 Mac（仅在副屏全屏时生效）。非应用商店安装的 App 需先在「应用信息 → ⋮ → 允许受限制的设置」放行。

## 触控手势（iPad 方式）

| 操作 | 效果 |
|---|---|
| 单指点按 / 快速点两下 | 单击 / 双击 |
| 单指拖动 | 滚动（松手有惯性） |
| 长按后拖动 | 按住拖拽：选择文字、移动窗口、拖文件 |
| 长按后松开 | 右键菜单 |
| 双指点按 | 右键菜单 |
| 双指捏合 | 缩放（支持触控板缩放的应用） |
| 三指点按 | 显示 / 隐藏延时统计 |
| 手写笔 | 悬停移动指针，落笔为左键（带压感），按住笔侧键为右键 |
| 外接键盘 | 按键直接发往 Mac（Win 键 = Command，需开启「Mac 副屏键盘」；Alt = Option） |

## 菜单设置

- 平板打开 App 时自动连接
- 插上 USB 线时自动使用有线连接
- 刷新率：120 Hz（默认，延时更低）/ 60 Hz（更省电）
- 120 fps 模式：连接时把平板设为主显示器，断开时还原。macOS 只按主显示器的刷新率合成副屏，平板作副屏时内容最多 60 fps，作主显示器时可达 120 fps。切换时 PadLink 会把每个窗口放回原来的屏幕；菜单栏与程序坞随主显示器移到平板。需要「辅助功能」权限。
- 显示器排列、分辨率（更多空间）在 系统设置 → 显示器 中调整，与普通显示器相同

命令行与自动化：`open padlink://connect`、`open padlink://disconnect`、`open padlink://mainmode/on`（或 `off`）、`open padlink://swapwindows`（互换 Mac 屏与平板上的窗口），可绑定到快捷指令。

编码参数可用 `defaults write com.bob.padlink.host <键> <值>` 调整：`codec`（hevc / h264）、`bitrate`（Mbps，默认 40）、`fps`（120 / 60）。

## 故障排查

| 现象 | 处理 |
|---|---|
| 平板显示「未授予屏幕录制 / 辅助功能权限」 | 在 Mac 隐私与安全性中打开对应开关后，退出并重新打开 PadLink |
| Mac 菜单里看不到平板 | 两台设备需在同一局域网；在平板上打开一次「Mac 副屏」 |
| Mac 选中平板后平板没有弹出 | 平板上检查「悬浮窗」「后台弹出界面」权限；部分系统重新安装 App 后会重置这两项 |
| Wi-Fi 下偶发卡顿 | Mac 的隔空投送 / AirPlay 点对点无线（AWDL）会周期性抢占信道。改用 USB 有线连接；或在终端执行 `sudo ifconfig awdl0 down`（暂停隔空投送、AirPlay、通用控制，`sudo ifconfig awdl0 up` 或重启恢复） |
| 同时连着 AirPlay 副屏时明显卡顿 | 两者共用 Mac 的硬件编码器，使用 PadLink 时先在控制中心断开 AirPlay 副屏 |
| 画面花屏或停住 | 三指点按看统计；断开重连会重新发送关键帧 |

运行日志：Mac `~/Library/Logs/PadLink.log`。

## 已知限制

- 第三方显示器无法出现在控制中心的「屏幕镜像」列表中，入口在菜单栏。
- 平板作副屏时，macOS 按主显示器的刷新率合成它（60 Hz 的 MacBook 内屏 → 60 fps）；需要 120 fps 时打开「120 fps 模式」。
- 开启台前调度时，左侧条中的窗口缩略图由系统管理，切换主显示器后可能出现在平板一侧。
- 虚拟显示器使用 macOS 私有接口 `CGVirtualDisplay`（`mac/CGVirtualDisplay.h`），后续系统版本可能变化。

## 延时测量

```bash
# <显示器 ID> 见 ~/Library/Logs/PadLink.log 中 "virtual display N created"
bash tools/latency-probe/run.sh <adb 序列号> <显示器 ID> 30
```

## 卸载

- Mac：退出 PadLink，删除 `/Applications/PadLink.app`；在隐私与安全性中移除 PadLink；`defaults delete com.bob.padlink.host`；签名钥匙串 `~/Library/Keychains/padlink-signing.keychain-db` 可一并删除。
- 平板：卸载「Mac 副屏」。

## 许可

MIT
