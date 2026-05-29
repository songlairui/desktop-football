# desktop-football

macOS 桌面物理足球挂件：一个在桌面上自由滚动、弹跳、被鼠标踢飞的足球。
复用 GoalHUD 的 CVDisplayLink + 窗口位移物理模型，加上重力、踢球力场、旋转纹理、
阴影透视与 squash & stretch。

## 快速开始

```bash
cd apps/macos
./build.sh --open        # 构建并启动（菜单栏出现 ⚽ 图标）
# 或仅构建：
./build.sh
# 开发期跑测试：
swift test
```

启动后球出现在屏幕底部中央。菜单栏 ⚽ 提供：显示/隐藏、重置到中央、声音开关、退出。

## 玩法

| 交互 | 效果 |
|------|------|
| 鼠标快速划过球 | 把球踢飞（力度随光标速度） |
| 光标靠近球 | "气流"轻推，球微微滚动 |
| 单击球 | 向上拍一下（dribble） |
| 按住拖拽 | 抓住球跟随光标，松手沿抛物线抛出 |

球受重力下落、着地弹跳（高度逐次衰减）、撞屏幕边缘反弹，最终因摩擦力静止并进入呼吸动画。
光标不在球上时窗口点击穿透，不影响使用桌面其它应用。

## 架构

```
apps/macos/
├── Package.swift
├── build.sh
├── Resources/Info.plist
├── Sources/
│   ├── FootballPhysics/          # 纯 Swift 物理库（仅 CoreGraphics，可单测）
│   │   ├── PhysicsConfig.swift   # 所有可调物理参数（不可变）
│   │   ├── Bounds.swift          # 屏幕边界与中心点钳制
│   │   ├── MotionState.swift     # 运动状态 + 离散事件（着地/撞墙）
│   │   ├── KickField.swift       # 鼠标踢球/气流力场（HUDPanel repulseForce 的反用）
│   │   └── BallState.swift       # 积分器：重力/碰撞/摩擦/旋转/形变
│   └── DesktopFootball/          # AppKit 应用
│       ├── BallTexture.swift     # 程序化生成足球与阴影 CGImage（无二进制资源）
│       ├── FootballLayerView.swift  # CALayer 三层渲染（阴影/形变/旋转）
│       ├── SoundEngine.swift     # AVAudioEngine 程序化合成（踢球/弹跳/滚动声）
│       ├── FootballPanel.swift   # 窗口即球：CVDisplayLink 循环 + 鼠标 + 集成
│       ├── AppDelegate.swift     # 菜单栏控制
│       └── main.swift
└── Tests/FootballPhysicsTests/   # 21 个物理单元测试
```

**核心设计：窗口即球（window-is-the-ball）。** 一个透明无边框 `NSPanel` 由物理引擎每帧
`setFrameOrigin` 在桌面上移动；窗口内用 CALayer 渲染旋转/形变/阴影。物理逻辑全部抽离为
可测试的纯库。详见 [docs/adr/0001](docs/adr/0001-rendering-and-physics-architecture.md)
——其中说明了为何**不**采用 PRD 首选的 SpriteKit（它与"整个桌面漫游"的需求范式不兼容）。

## 状态

- ✅ P0 (R1–R6)：重力+碰撞、足球渲染+旋转、踢球交互、边界反弹、摩擦停止、独立窗口
- ✅ P1 大部分 (R7/R8/R11/R12)：阴影透视、squash & stretch、长按拖拽抛出、静止呼吸
- ✅ 声音 (R10)：程序化合成踢球/弹跳/滚动声，可开关
- ⏳ 后续：粒子 R9（`CAEmitterLayer`）、多球类型 R13、自定义纹理 R16、节日主题 R17

需求文档见 `docs/specs/desktop-football.md`，缘起见 `docs/kickoff/START.md`。
