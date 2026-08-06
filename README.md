# FunTR —— 利民 LCD 上的 AI Agent 控制塔

[中文](README.md) · [English](README.en.md)

把利民 CPU 散热器上的 1920×480 LCD 变成一块实时仪表盘,既显示 Mac 的系统状态,**又能看到你的 AI 编程助手此刻在干什么** —— 全部原生运行于 macOS,无需 Windows。

![真机实拍](img/photo.jpg)

<sub>装在利民 Trofeo Vision 9.16 散热器上的实拍效果。</sub>

![仪表盘](img/dashboard.gif)

<sub>实时演示(假数据)。**注意:这两张图拍摄于旧版本**,当时的布局是 CPU｜AGENTS｜内存,还有 Bongo Cat 和皮卡丘;两者现已移除,布局也变了 —— 见下面的说明。</sub>

> 基于 [beret21/MacTR](https://github.com/beret21/MacTR) 改造。上游是一个纯粹的
> LCD 驱动 + 系统监控;本项目把重心整体挪到了一块实时追踪
> [Claude Code](https://claude.com/claude-code) 与 [Codex](https://openai.com/codex)
> 会话的 **AI Agents 控制塔**上,并加了主题系统、干员立绘和锁屏屏保。

## 布局

三块面板,合计 1920×480:

```
┌──────────────┬──────────────────────────────────────┬──────────────┐
│   OPERATOR   │            AI AGENTS                 │    STATUS    │
│              │        (三倍宽,核心面板)              │              │
│  斯卡蒂立绘   │  左:会话列表   右:聚焦会话详情        │  时钟 / 日期  │
│  随状态动作   │                                      │  农历 / 网络  │
│              │  ────────────────────────────────    │  CPU/内存/温度 │
│              │  底部:今日 Token · Codex 额度         │              │
└──────────────┴──────────────────────────────────────┴──────────────┘
```

## 亮点

### 🤖 AI Agents 控制塔

读取**本地**的 Claude Code 和 Codex 会话记录(只读、不联网):

- **多会话并列** —— 每个近期活跃的会话一张卡片,同一项目开多个窗口也会分别显示(`项目 #2`),不会折叠成一个。
- **自动聚焦详情** —— 最需要你注意的那个会话展开在右侧,显示它完整的最后发言。消息里的 Markdown 表格会渲染成对齐表格,而不是原始 `| … |`。
- **在跑什么模型** —— 卡片标题旁显示当前模型(`Opus 5`、`GPT-5.6` 等),中途 `/model` 切换会跟着变。
- **计划步骤** —— `步骤 4/6` 徽章 + 分段进度条,来自 Codex 的 `update_plan` 和 Claude 的 `TodoWrite`;上一轮的旧计划会自动消失。当前步骤上有一个音符播放头。
- **区分「在忙」和「等你」** —— 权限确认提示和正在运行的工具在 transcript 里长得一模一样,所以额外读取 Claude Code 写的会话状态文件,能真正区分出**待授权 / 待输入 / 待确认**,并持续闪烁直到你处理。进程已死的记录会被跳过,崩掉的 CLI 不会把卡片永久钉住。
- **跨会话活动流** —— 底部滚动显示状态变化(开始 / 完成一轮 / 等你输入)。
- **今日 Token 与 Codex 额度** —— `万 / 亿` 格式,额度跨所有近期会话取最新读数。

### 🎨 主题系统

三套皮肤,菜单栏设置里切换:**经典**、**初音未来**、**罗德岛**。

主题不只是换色 —— 它还决定**画什么**。初音未来这套用的是 Vocaloid 本质就是个 DAW 的隐喻:

| 元素 | 做法 |
|---|---|
| 底纹 | 钢琴卷帘,每 4 拍加重的小节线 + 黑键分层 |
| 分隔线 | 收尾归零的声波形,取代直线 |
| 弧形仪表 | 外圈加头梁 + 耳罩,做成她的耳机 |
| 进度条 | 当前计划步骤标一个音符头 |
| 图标 | 面板标题前八分音符、面板左下角大葱、名字后 `01` 干员编号 |

图标是离线生成后 base64 内嵌的(见 [`tools/bake-glyphs/`](tools/bake-glyphs/)),没有烘焙图时自动回退到代码路径绘制,所以主题本身不依赖生成资源。

### 🐧 干员立绘

左面板是斯卡蒂的行动人偶,动作跟着实际状态走:agent 在跑时进战斗动作、有会话等你输入时向你打招呼、完成一轮时来个庆祝、都闲着就回基地踱步;系统在放音乐时她会随乐而动,脚下还有频谱。

动画是从 Spine 骨骼离线烘焙成精灵条的(见 [`tools/bake-operator/`](tools/bake-operator/)),换成别的角色只需替换素材。

### 🌙 锁屏屏保

Mac 锁屏后 LCD 切换成环境画面(宽幅壁纸 + 飘动星点),解锁即恢复。设置里可以指定某一张或自动轮换。

### 📌 Dynamic Island 推送

任何脚本或 agent 都能往 LCD 上推一条临时消息:

```bash
tools/mactr-pin '{"title":"部署完成","body":"prod 已上线","icon":"✅","secs":12}'
```

### ⚙️ 底层

- **自适应帧率** —— 只有真的有动画时(agent 工作、屏保、推送动画)才跑约 15fps,其余降到 2fps 省电。
- **USB 热插拔** —— 插拔、睡眠/唤醒后自动重连。
- **本机预览** —— 没接 LCD 时渲染到窗口,方便无硬件调试。
- **菜单栏应用** —— 后台运行,无 Dock 图标。
- 亮度用 gamma 曲线调整,亮壁纸不会过曝成白块;可 180° 旋转。

## 硬件

| | |
|---|---|
| **产品** | [利民 Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) |
| **屏幕** | 9.16" IPS,1920 × 480 |
| **接口** | USB Type-C(USB 2.0) |
| **设备** | `0416:5408`(LY Bulk 协议) |

## 环境要求

- Apple Silicon Mac(M1–M5)
- macOS 15(Sequoia)或更新

下载安装包的话到此为止 —— libusb 已经打进 App 里,不需要装 Homebrew。
只有想从源码构建时才另外需要 `libusb` 和 Swift 6.1+ 工具链。

## 安装

从 [Releases](https://github.com/mikufanliu/FunTR/releases)
下载 `.dmg`,打开后把 **FunTR** 拖进「应用程序」。

> **首次打开会被 Gatekeeper 拦下。** 这个 App 没买 Apple 开发者证书(99 美元/年),
> 只做了 ad-hoc 签名,所以 macOS 会说「无法验证开发者」。
> 在「应用程序」里 **右键点图标 → 打开**,弹窗里再点一次「打开」就行,只需一次。
>
> 命令行等价写法:
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/FunTR.app"
> ```

装好后从菜单栏图标进入设置,可以打开「开机自启」。

## 从源码构建

```bash
brew install libusb pkg-config

git clone https://github.com/mikufanliu/FunTR.git
cd FunTR
swift build -c release

.build/release/FunTR          # 菜单栏应用;驱动 LCD,或没接 LCD 时弹预览窗口
```

> 如果系统的 Command Line Tools 损坏、`swift build` 在解析包清单时报错,
> 装 Homebrew 的 Swift 工具链(`brew install swift`),改用
> `/opt/homebrew/opt/swift/bin/swift build -c release`,
> 或给下面的打包脚本传 `SWIFT=/opt/homebrew/opt/swift/bin/swift`。

### 自己打包成 .app / .dmg

```bash
./packaging/build-app.sh      # → dist/FunTR.app(自带 libusb,已 ad-hoc 签名)
./packaging/make-dmg.sh       # → dist/FunTR-<版本>-arm64.dmg
```

`build-app.sh` 会自动把二进制引用的所有非系统 dylib 复制进 `Contents/Frameworks`
并改写 install name,最后校验产物里没有残留构建机的本地路径。

版本号以 git tag 为准:推一个 `v*` tag 就会触发
[Release 流水线](.github/workflows/release.yml),由 CI 构建并把 DMG 传到 GitHub Release。

### 开机(登录)自启

推荐用 App 内设置里的开关(基于 `SMAppService`)。

如果你还想要「崩溃后自动拉起」,改用 LaunchAgent:

```bash
cp packaging/com.mikufanliu.FunTR.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.mikufanliu.FunTR.plist
```

两者只能选一个,同时开会启动两份实例互抢 USB 设备。

## 运行模式

```bash
.build/release/FunTR                 # 菜单栏应用(有 LCD 走 LCD,没有则预览窗口)
.build/release/FunTR --preview       # 强制打开本机预览窗口
.build/release/FunTR --theme miku    # 指定主题启动(会写入设置)
.build/release/FunTR --demo          # 用精美假数据驱动 LCD(方便拍照 / 展示)
.build/release/FunTR --snapshot x.png            # 渲染当前真实数据到 PNG
.build/release/FunTR --snapshot x.png --cores 10 # 模拟 N 核渲染一帧
.build/release/FunTR --gif x.gif --frames 48 --fps 12 --scale 2   # 生成演示 GIF
.build/release/FunTR --benchmark 120 # 测量 LCD 可达帧率
.build/release/FunTR --test-flash 30 # 强制所有卡片进入提醒态,预览告警视觉
.build/release/FunTR --rotate        # 画面旋转 180°
.build/release/FunTR --cli           # 在终端里打印一次指标,不碰 LCD
```

装好的 App 里同样的入口是 `/Applications/FunTR.app/Contents/MacOS/FunTR`。

同一时刻只能有一个进程占用 USB 设备 —— 用 `--demo` / `--benchmark` 前先停掉正在运行的实例。

> 改完代码记得**重启进程**:正在运行的实例持有旧二进制的 inode,`swift build` 不会影响它。

## Agent 数据怎么读取

FunTR 从不访问任何网络或 API,只读取这些 CLI 本来就写到本地磁盘的记录:

| Agent | 来源 | 解析内容 |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | 助手消息、`usage` token、`TodoWrite`、`message.model` |
| Claude Code | `~/.claude/sessions/*.json` | 会话实时状态(busy / waiting / idle)与等待原因 |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | agent 消息、`token_count`、`rate_limits`、`update_plan`、`turn_context` |

Token 总量按本地自然日统计;某个 agent 今天还没跑过时,面板会优雅地显示它上一次会话的上下文。
transcript 只从尾部按需读取,不整文件加载。

## 隐私

一切都在本地、只读。无遥测、无网络请求,没有任何数据离开你的 Mac。

唯一的例外是**你自己主动跑** `tools/bake-glyphs/bake.sh` 时会调用图像生成接口 —— 那是可选的开发工具,应用运行时完全不涉及。

## 致谢

- [beret21/MacTR](https://github.com/beret21/MacTR) —— 本项目所基于的原版 macOS 驱动
- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) —— LY Bulk 协议逆向
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) —— IOHIDEventSystemClient 温度读取
- 干员立绘出自《明日方舟》,版权归 © Hypergryph / Studio Montagne 所有
- 初音未来相关元素版权归 © Crypton Future Media 所有

> 内嵌美术素材纯属装饰,版权归各自所有者。要分发构建产物请自行确认相关条款,
> 或替换掉 `Sources/MacTR/Rendering/*Asset.swift` 里的内容。

## 许可证

本仓库尚未附带许可证文件。上游 [beret21/MacTR](https://github.com/beret21/MacTR)
同样没有 LICENSE,因此并未给出明确的再分发授权 —— 这一点在你 fork 或分发前需要自行判断。

---

用 Swift + libusb 构建。与 [Claude Code](https://claude.com/claude-code) 协作开发。
