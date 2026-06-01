# desktop-football

macOS 桌面 3D 足球挂件 —— Metal 渲染 + 纯 Swift 物理引擎。

一个跑在桌面上的透明窗口，里面有一颗用 Metal 实时渲染的 3D 足球：受重力下落、着地弹跳变形、
撞屏幕边缘反弹、被鼠标踢飞或拖拽抛出。支持多种球体模型（含 FIFA 2026 世界杯 Trionda）、
多种重力模式、空闲动画和 Game Mode 玩法。

## 快速开始

```bash
cd apps/macos
./build.sh --open        # 构建并启动（菜单栏出现 ⚽ 图标）
./build.sh --release     # 构建 + ad-hoc 签名 + 打包 DMG
swift test               # 43 个单元测试
```

> **要求：** macOS 13+，Xcode 15+（Swift 6.0 toolchain）

## 功能特性

### 🏟️ Metal 3D 渲染

- 完整的 Metal 渲染管线：顶点/片段着色器、PBR 光照（key / fill / rim 三光源）
- USDZ 模型加载（ModelIO），支持外部 PBR 贴图（baseColor / normal / metallic / roughness）
- "水族箱"透视相机：屏幕作为前玻璃面，物理 2D 坐标映射到 3D 世界空间
- 地面平面 + 投影阴影圆盘 + squash & stretch 弹性形变
- 辅助线（Guide Lines）和 FPS 叠加层

### ⚽ 球体模型

| 模型 | 格式 | 说明 |
|------|------|------|
| FIFA 2026 Trionda | USDZ + 4×JPG PBR | 世界杯官方用球，PBR 渲染 |
| Classic Soccer | 程序化生成 | 经典黑白足球（无外部资源） |
| Basketball | USDZ | 篮球 |
| Football | USDZ | 美式橄榄球 |

### 🌍 重力模式

| 模式 | 效果 |
|------|------|
| Normal | 真实重力，球落下并 settle 在地面 |
| Zero-G | 失重漂浮，踢球后缓慢减速 |
| Balloon | 反重力"气球"，球向上漂浮并停在天花板 |

### 🎭 空闲动画（Idle Motion）

球静止时自动播放，四种模式可切换：

- **Vertical Spin** — 原地垂直自旋
- **Globe Roll** — 地球仪式缓慢滚动
- **Hanging Charm** — 悬挂挂饰：球作为阻尼摆锤从屏幕上方悬垂摆动
- **Finger Spin** — 指尖转球：充电-滑行循环

### 🎮 交互

| 操作 | 效果 |
|------|------|
| 鼠标快速划过 | 踢飞（力度随光标速度），Game Mode 下半径扩大 + 光标环 |
| 光标靠近球 | "气流"轻推，球微微滚动 |
| 单击球 | 向上拍一下（dribble） |
| 按住拖拽 | 抓住球跟随光标，松手沿抛物线抛出 |
| Right Command 长按 | Game Mode 蓄力，松开释放强力击球 |
| Right Option 长按 | Snap：将球吸附到光标位置 |

### 🚢 Cruise Mode

开关后定时产生随机"风"，让静止的球保持缓慢运动——适合当桌面摆件。

### 🏆 Game Mode

启用后踢球半径扩大到 160pt、光标显示踢击范围环（CursorRingPanel），
支持 Combo Strikes（连击倍率 2×/3×/5×）和蓄力击球。

### 🔊 声音

程序化合成踢球/弹跳/滚动音效（AVAudioEngine，零外部音频文件），菜单栏可开关。

## 菜单栏

点击状态栏 ⚽ 图标：

- Show / Hide Football
- Reset to Centre (`⌘R`)
- **Gravity Mode** → Normal / Zero-G / Balloon
- **Ball Model** → FIFA 2026 / Classic / Basketball / Football
- **Game Mode** (`⌘G`) — 踢球半径扩大 + 光标环
- **Combo Strikes** → 1× / 2× / 3× / 5×
- **Cruise Mode** — 定时风
- **Idle Motion** → Vertical Spin / Globe Roll / Hanging Charm / Finger Spin
- Guide Lines — 显示辅助线
- Show FPS — 帧率叠加
- Sound On / Off
- Quit (`⌘Q`)

## 架构

```
apps/macos/
├── Package.swift              # SPM: macOS 13+, MetalKit + ModelIO
├── build.sh                   # 构建 / --open 运行 / --release 签名打包
├── Resources/Info.plist
├── Sources/
│   ├── FootballPhysics/           # 纯 Swift 物理库（仅 CoreGraphics，可单测）
│   │   ├── PhysicsConfig.swift    # 所有可调物理参数
│   │   ├── BallState.swift        # 半隐式 Euler 积分器：重力/碰撞/摩擦/旋转/形变
│   │   ├── Bounds.swift           # 屏幕边界与中心点钳制
│   │   ├── MotionState.swift      # 运动状态 + 离散事件
│   │   ├── KickField.swift        # 鼠标踢球/气流力场
│   │   ├── GlassContact.swift     # 前玻璃面击球交互模型
│   │   ├── GravityMode.swift      # Normal / Zero / Balloon
│   │   └── PendulumState.swift    # 阻尼摆锤（Hanging Charm 空闲动画）
│   └── DesktopFootball/           # AppKit + Metal 应用
│       ├── MetalScene.swift       # 3D 渲染管线：管线状态、网格、纹理、着色器 uniform
│       ├── MetalCamera.swift      # 水族箱透视相机
│       ├── FootballMetalView.swift # MTKView 容器
│       ├── BallModel.swift        # USDZ 加载 + 归一化（ModelIO）
│       ├── BallTexture.swift      # 程序化 CGImage 纹理（fallback）
│       ├── FootballPanel.swift    # 透明窗口 + CVDisplayLink + 鼠标 + 物理集成
│       ├── FootballLayerView.swift # CALayer 2D 渲染（legacy fallback）
│       ├── CursorRingPanel.swift  # Game Mode 踢击范围光标环
│       ├── EffectsOverlayPanel.swift # 辅助线 / FPS 叠加
│       ├── SoundEngine.swift      # AVAudioEngine 程序化音效
│       ├── AppDelegate.swift      # 菜单栏控制
│       └── main.swift
└── Tests/FootballPhysicsTests/    # 43 个单元测试
```

**核心设计：窗口即球（window-is-the-ball）。** 一个透明无边框 `NSPanel` 由物理引擎每帧
`setFrameOrigin` 在桌面上移动；窗口内嵌 MTKView 用 Metal 渲染 3D 球体。
物理逻辑全部抽离为可测试的纯 Swift 库。详见
[docs/adr/0001](docs/adr/0001-rendering-and-physics-architecture.md)。

## 发布

```bash
# 本地构建 DMG
cd apps/macos && ./build.sh --release
# dist/DesktopFootball.dmg (ad-hoc signed)

# GitHub Release
gh release create v0.x.0 dist/DesktopFootball.dmg --title "..." --notes "..."
```

最新版本下载：[GitHub Releases](https://github.com/songlairui/desktop-football/releases)

## 状态

- ✅ v0.1.0：2D CALayer 渲染 + 基础物理 + 声音
- ✅ v0.2.0：Metal 3D 渲染 + USDZ 球体 + PBR 贴图 + 多球模型 + 重力切换 + 空闲动画 + Game Mode
- ⏳ 后续：粒子特效、自定义纹理、节日主题、多显示器优化

需求文档见 `docs/specs/desktop-football.md`，缘起见 `docs/kickoff/START.md`。
