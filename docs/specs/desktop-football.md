# Desktop Football — 产品需求文档 (PRD)

> GoalHUD 生态中的桌面足球挂件：一个在 macOS 桌面上自由滚动、响应鼠标交互、具有物理真实感的足球。

---

## Problem Statement

GoalHUD 当前的 HUDPanel 展示了一个技术上成熟的桌面物理交互系统——CVDisplayLink 驱动的物理循环、边界碰撞、鼠标力场。这个系统已经实现了"躲避鼠标"的核心体验，但其潜力远未被释放。

用户在长时间专注工作时，缺少一个轻量的、无侵入的"桌面玩具"来提供微休息（micro-break）和潜意识的愉悦感。桌面足球是一个天然的延伸：它复用现有的物理引擎，增加重力和踢球交互，同时为 GoalHUD 生态增加一个有生命力的视觉元素。

**核心洞察：** 物理引擎已经是半个游戏引擎。加上重力、鼠标踢球、和一个旋转的足球纹理，就是一个完整的桌面足球。

---

## Goals

| # | 目标 | 可衡量指标 |
|---|------|-----------|
| G1 | 复用现有物理引擎，实现桌面足球的完整运动 | 球可以在桌面上滚动、弹跳、被鼠标踢飞，物理行为符合直觉 |
| G2 | 足球的视觉表现具有运动真实感 | 旋转方向与运动方向一致，阴影随速度/高度变化，弹跳有 squash & stretch |
| G3 | 鼠标交互自然流畅 | 鼠标接近有"气流"感应，快速划过有踢球脉冲，长按可抓取，松开可抛出 |
| G4 | 与 GoalHUD 生态共存 | 足球窗口与 HUDPanel 独立但不冲突，可在同一空间运行 |
| G5 | 性能无感知开销 | 60fps 稳定，CPU 占用 < 3%，内存 < 50MB |

---

## Non-Goals

| # | 不做的事 | 理由 |
|---|---------|------|
| NG1 | 多人联网对战 | 这是桌面玩具，不是游戏，保持单机轻量 |
| NG2 | 完整的足球比赛规则（球门、得分、越位） | 过度设计，违背"轻量桌面存在感"原则 |
| NG3 | 替代 GoalHUD 的 HUD 功能 | 足球是独立挂件，不改变 HUD 的核心目标追踪功能 |
| NG4 | 支持 iOS/iPadOS | 当前聚焦 macOS 桌面体验，跨平台是独立项目 |
| NG5 | 高保真的 3D 渲染 | 桌面挂件需要轻量，2.5D 透视效果足够 |

---

## User Stories

### 作为桌面用户

**US-1：基础运动**
> As a desktop user, I want a football that rolls and bounces on my screen so that I have a playful, physics-driven companion while working.

验收标准：
- [ ] 球在桌面上受重力影响，自然下落并着地
- [ ] 着地时有弹跳效果，弹跳高度逐渐衰减
- [ ] 球可以撞到屏幕边缘并反弹
- [ ] 最终球会因摩擦力停下来（静止在桌面上）

**US-2：鼠标踢球**
> As a desktop user, I want to kick the football with my mouse cursor so that I can interact with it playfully.

验收标准：
- [ ] 鼠标快速划过球体时，球被"踢飞"，速度与鼠标速度成正比
- [ ] 鼠标接近球体时，球感受到"气流"并轻微滚动
- [ ] 点击球体时，球弹跳一下（像拍球）
- [ ] 长按拖拽可以抓住球，松开后球沿抛物线飞出

**US-3：视觉真实感**
> As a desktop user, I want the football to look and move realistically so that the experience feels polished and delightful.

验收标准：
- [ ] 球的纹理旋转方向与运动方向一致（向右滚 → 顺时针转）
- [ ] 阴影随球的高度变化（飞起时阴影远离，着地时紧贴）
- [ ] 弹跳瞬间球体有 squash & stretch 效果
- [ ] 高速运动时有视觉模糊或拖尾效果（可选）

**US-4：透视效果**
> As a desktop user, I want subtle perspective effects so that the ball feels like it exists in 3D space on my desktop.

验收标准：
- [ ] 球在屏幕上方时微微变大（模拟远处），底部时正常大小
- [ ] 阴影的 offset 和 blur radius 随球的高度动态变化
- [ ] 可选：球被踢到高处时，窗口微微放大（模拟飞向用户）

**US-5：Mission Control 兼容**
> As a desktop user, I want the football to behave sensibly when I use Mission Control (four-finger swipe up).

验收标准：
- [ ] Mission Control 触发时，球的窗口被系统缩放（接受系统行为）
- [ ] 或者：检测 Mission Control 并临时隐藏球窗口（避免变形）
- [ ] Mission Control 退出后，球恢复原位和运动状态

---

## Requirements

### P0 — Must-Have (最小可玩版本)

| ID | 需求 | 验收标准 | 技术约束 |
|----|------|---------|---------|
| R1 | 物理引擎：重力 + 碰撞 | 球受重力下落，着地弹跳，撞墙反弹 | 复用 HUDPanel 的积分器，添加 `gravity` 向量 |
| R2 | 足球渲染：圆形 + 旋转纹理 | 球体显示为足球纹理，旋转方向与运动一致 | 使用 `CALayer` + `CGAffineTransform`，或 `SKSpriteNode` |
| R3 | 鼠标踢球交互 | 鼠标快速划过时施加脉冲力 | 复用 `repulseForce` 的 `dynamicK` 逻辑，改为吸引+脉冲 |
| R4 | 边界碰撞 | 球撞到屏幕边缘反弹 | 复用 HUDPanel 的 wall bounce 逻辑 |
| R5 | 摩擦力停止 | 球最终因摩擦力停下来 | 添加 `groundFriction` 和 `airDamping` |
| R6 | 独立窗口管理 | 足球窗口与 HUDPanel 独立，不冲突 | 新建 `FootballPanel: NSPanel`，相同 `collectionBehavior` |

### P1 — Nice-to-Have (体验升级)

| ID | 需求 | 验收标准 | 技术约束 |
|----|------|---------|---------|
| R7 | 阴影透视 | 阴影随球的高度和速度动态变化 | `CALayer.shadowOffset` + `shadowRadius` 动画 |
| R8 | Squash & Stretch | 弹跳瞬间球体压扁和拉伸 | `SKAction.scaleX/Y` 或 `CGAffineTransform` |
| R9 | 粒子效果 | 踢球时有尘土/草屑粒子 | `SKEmitterNode` 或 `CAEmitterLayer` |
| R10 | 声音反馈 | 踢球声、弹跳声、滚动声 | `AVAudioEngine` 或 `NSSound`，音调随力度变化 |
| R11 | 长按拖拽 | 长按可抓住球，松开抛出 | `mouseDown` + `mouseDragged` + `mouseUp` 事件链 |
| R12 | 静止呼吸动画 | 球停止时有轻微 scale 脉冲 | `CABasicAnimation` 循环，scale 1.0 ↔ 1.02 |

### P2 — Future Considerations (未来扩展)

| ID | 需求 | 验收标准 | 技术约束 |
|----|------|---------|---------|
| R13 | 多球类型 | 可切换足球、篮球、乒乓球等 | 纹理图集 + 物理参数预设（弹性、摩擦、重力倍数） |
| R14 | 屏幕震动 | 踢球瞬间屏幕微震 | 窗口 position 动画，1-2 帧抖动 |
| R15 | 与 HUDPanel 互动 | 球可以撞到 HUDPanel 并推开它 | 需要窗口间碰撞检测，复杂度较高 |
| R16 | 自定义纹理 | 用户可拖入自定义图片作为球体 | 文件拖拽 + 纹理加载 |
| R17 | 节日主题 | 特定节日切换球的外观（圣诞球、南瓜等） | 定时器 + 纹理切换逻辑 |
| R18 | CLI / 异步任务联动 | 外部命令或构建、vibe coding 消息可触发球的动作和状态变化 | 提供轻量 CLI 或本地 IPC，事件映射到踢球、跳动、变形、提示特效等动作 |
| R19 | 运动跟随相机视差 | 球高速运动、碰撞或击球时，相机有轻微跟随/倾斜变化，增强 3D 感但不干扰桌面使用 | 相机变化幅度小、可平滑恢复；需兼容当前单层鱼缸和未来俯瞰绿茵场视角 |
| R20 | 透视方案切换 | 可在当前单层鱼缸视角和俯瞰足球绿茵场视角之间切换；俯瞰模式下击球像开大脚 | 渲染相机、辅助线、击球参数需按视角模式分离，避免当前模式的假深度假设固化进物理层 |

---

## Animation 方案分析

### 方案对比

| 方案 | 渲染质量 | 旋转/形变支持 | 性能开销 | 实现复杂度 | 推荐度 |
|------|---------|-------------|---------|-----------|--------|
| **视频 (AVPlayer)** | 极高 | ❌ 固定素材 | 高 (解码) | 低 | ⭐⭐ |
| **APNG** | 高 | ❌ 固定序列 | 中 | 低 | ⭐⭐ |
| **Spine/龙骨** | 极高 | ✅ 骨骼驱动 | 中 | 高 (引入运行时) | ⭐⭐⭐ |
| **SpriteKit** | 极高 | ✅ 物理+粒子 | 低 | 中 | ⭐⭐⭐⭐⭐ |
| **Core Animation 组合** | 高 | ✅ 程序化 | 极低 | 中 | ⭐⭐⭐⭐ |
| **Metal shader 程序化** | 极高 | ✅ 完全自由 | 极低 | 高 | ⭐⭐⭐⭐ |

### 推荐：SpriteKit 首选，Core Animation 轻量备选

**理由：**

1. **视频/APNG 的致命问题：** 无法根据物理状态实时改变旋转角度。球滚向左边时应该是逆时针转，被踢飞时应该加速旋转——这些用预渲染素材做不到。

2. **Spine 的问题：** 引入一个完整的骨骼运行时对一个足球来说 overkill。适合角色动画，不适合简单几何体。

3. **SpriteKit 的优势：**
   - 自带物理引擎（`SKPhysicsBody`）、粒子系统、sprite atlas 支持
   - `SKScene` 可以嵌入 `NSView`（通过 `SKView`），而 `NSView` 可以放入 `NSPanel.contentView`
   - 一个透明 `SKScene` + 圆形 `SKPhysicsBody`，重力、碰撞、旋转全部原生支持
   - macOS 上经过验证（很多屏保和桌面宠物都这么做）

4. **Core Animation 备选：**
   - 最轻量的路径，但物理碰撞需要自己写
   - 适合 Phase 1 快速验证手感

### 渲染架构（SpriteKit 方案）

```
┌─ NSPanel (透明无边框, CVDisplayLink 驱动)
│  └─ SKView (透明背景, ignoresSiblingOrder = true)
│     └─ SKScene
│        ├─ SKSpriteNode("football")  ← 纹理图集
│        ├─ SKPhysicsBody(circleOfRadius:)  ← 碰撞体
│        ├─ SKEmitterNode (草屑/尘土粒子)  ← 踢球时触发
│        └─ SKLightNode (可选，增加立体感)
```

### 渲染架构（Core Animation 备选）

```
┌─ NSPanel (透明无边框, CVDisplayLink 驱动)
│  └─ NSView
│     └─ CALayer (root)
│        ├─ CALayer ("football")  ← 纹理图
│        │  ├─ transform: rotation (根据 velocity 计算)
│        │  └─ shadowOffset/shadowRadius (根据高度变化)
│        └─ CAEmitterLayer (粒子，可选)
```

---

## Physics 系统设计

### 核心方程

当前 `HUDPanel.step(dt:)` 的积分器：

```swift
vel.x = vel.x * decay + force.x * dt
vel.y = vel.y * decay + force.y * dt
o.x += vel.x * dt
o.y += vel.y * dt
```

扩展为重力系统：

```swift
let gravity = CGPoint(x: 0, y: -980)  // 980 pt/s²，接近真实重力
vel.x = vel.x * decay + (force.x + gravity.x) * dt
vel.y = vel.y * decay + (force.y + gravity.y) * dt
```

### 地面碰撞

```swift
if o.y <= vis.minY + mg {
    o.y = vis.minY + mg
    vel.y = abs(vel.y) * restitution  // 弹跳衰减
    vel.x *= groundFriction            // 地面摩擦，比如 0.92
}
```

### 物理参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `gravity` | -980 pt/s² | 接近真实重力 |
| `restitution` | 0.6 → 0.2 | 弹跳衰减，每次着地递减 |
| `groundFriction` | 0.92 | 地面滚动摩擦 |
| `airDamping` | 0.999 | 空气阻力，高速运动自然减速 |
| `rollingResistance` | 0.98 | 滚动阻力，让球最终停下来 |
| `kickImpulse` | 500-2000 pt/s | 踢球脉冲，随鼠标速度变化 |
| `hoverForce` | 50 pt/s² | 鼠标接近时的"气流"力 |

### 滚动条件（纯滚动）

球在地面上滚动时，角速度应与线速度匹配：

```swift
let ballRadius: CGFloat = 20  // 球的半径
let angularVelocity = linearVelocity.x / ballRadius  // ω = v / r
```

### SpriteKit 物理参数映射

如果使用 SpriteKit，这些参数直接映射：

```swift
let ballBody = SKPhysicsBody(circleOfRadius: ballRadius)
ballBody.mass = 0.45  // 足球质量 (kg)
ballBody.restitution = 0.6
ballBody.friction = 0.3
ballBody.linearDamping = 0.1  // 空气阻力
ballBody.angularDamping = 0.1  // 旋转阻力
ballBody.affectedByGravity = true

// 场景重力
scene.physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)  // SpriteKit 使用 m/s²
```

---

## Window Scaling & Mission Control

### 问题分析

macOS 的 Mission Control（四指上滑）会对**所有窗口**应用 scale-down transform。这是系统级的 WindowServer 行为，**无法阻止**。

### 策略对比

| 策略 | 做法 | 效果 | 推荐度 |
|------|------|------|--------|
| **接受** | 什么都不做 | Mission Control 时球也缩小，其实很自然 | ⭐⭐⭐⭐ |
| **检测隐藏** | 监听 `NSWorkspace.activeSpaceDidChange`，进入 MC 时隐藏窗口 | 球消失，避免变形 | ⭐⭐⭐ |
| **主动缩放** | 平时就用 `NSAffineTransform` 做透视缩放 | 球本身有"近大远小"的 3D 感 | ⭐⭐⭐⭐ |

### 推荐：接受 + 主动缩放

**理由：**
1. Mission Control 只持续 1-2 秒，球缩小一下反而有"被吸进去"的趣味感
2. 平时通过阴影和缩放暗示 3D 感，比隐藏更有趣
3. 检测隐藏需要监听系统通知，增加复杂度，且可能导致状态恢复问题

### 透视效果实现

**真正的透视效果不是靠窗口缩放实现的，而是靠足球自身的渲染：**

1. **阴影透视**：球的阴影 offset 和 blur radius 随速度变化——球速越快，阴影拉得越长，产生"飞离桌面"的错觉

```swift
// 阴影随高度变化
let heightFactor = max(0, ballVelocity.y) / 1000  // 飞起时增大
shadowLayer.shadowOffset = CGSize(width: 0, height: -10 * heightFactor)
shadowLayer.shadowRadius = 5 + 15 * heightFactor
shadowLayer.shadowOpacity = Float(0.3 - 0.2 * heightFactor)  // 飞起时阴影变淡
```

2. **缩放暗示**：球被踢到屏幕上方时微微变大（模拟远处），底部时正常大小

```swift
// 根据 Y 位置缩放（上方 = 远处 = 稍大）
let screenHeight = screen.visibleFrame.height
let normalizedY = ballPosition.y / screenHeight
let scale = 1.0 + 0.1 * (1.0 - normalizedY)  // 上方 1.1x，下方 1.0x
ballNode.setScale(scale)
```

3. **Z 轴旋转**：足球的黑白纹理旋转是视觉上最强烈的运动暗示

```swift
// 旋转速度 = 线速度 / 球半径
let angularVelocity = ballVelocity.x / ballRadius
ballNode.zRotation += angularVelocity * dt
```

---

## 极致体验优化清单

### 运动状态的视觉表达

| 状态 | 视觉表现 |
|------|---------|
| **静止** | 阴影紧贴球底，轻微呼吸动画（scale 1.0 ↔ 1.02） |
| **滚动** | 纹理旋转 = 线速度 × 时钟方向，阴影随滚动方向偏移 |
| **弹跳** | 着地瞬间阴影压扁（scaleY 0.6），球体压扁（squash & stretch） |
| **飞行** | 阴影远离球体（offset 增大 + blur 增大），球体微微缩小 |
| **被踢** | 瞬间速度脉冲 + 粒子爆发（草屑/尘土）+ 屏幕微震（可选） |
| **停止** | 最后几帧减速 → 球体微微晃动（overshoot damping）→ 静止 |

### 鼠标交互的体验设计

| 交互 | 行为 | 物理实现 |
|------|------|---------|
| **鼠标接近** | 球感受到"气流"，轻微滚动 | 吸引力场，距离越近力越大，类似 HUDPanel 的 `staticK` |
| **快速划过** | 球被"踢飞" | 脉冲力 = `dynamicK × approachSpeed × t`（复用 HUDPanel 逻辑） |
| **点击** | 球弹跳一下 | 瞬间施加向上脉冲（`vel.y += 300`） |
| **长按拖拽** | 抓住球，跟随鼠标 | 进入"抓取模式"，球的位置锁定到鼠标，关闭重力 |
| **松开** | 球沿抛物线飞出 | 恢复重力，施加鼠标速度向量作为初始速度 |

### 声音系统（可选但加分巨大）

| 声音 | 触发条件 | 实现 |
|------|---------|------|
| **踢球声** | 鼠标快速划过 | `AVAudioEngine`，音调随撞击力度变化 |
| **弹跳声** | 球着地 | 音量随 `|vel.y|` 变化，音调随机微调 |
| **滚动声** | 球在地面滚动 | 持续音效，音量随 `|vel.x|` 变化，球停止时淡出 |
| **抓取声** | 长按抓住球 | 短促的"嗒"声 |
| **抛出声** | 松开球 | 风声，音调随抛出速度变化 |

---

## Implementation Phases

### Phase 1：最小可玩（1-2 天）

**目标：** 验证手感，快速迭代

**任务：**
- [ ] 创建 `FootballPanel: NSPanel`，复用 HUDPanel 的窗口配置
- [ ] 用 `CALayer` 渲染一个圆形 + 旋转纹理（先用纯色圆形验证）
- [ ] 实现重力 + 地面碰撞 + 鼠标踢球（复用 `repulseForce` 逻辑）
- [ ] 添加边界碰撞（复用 wall bounce）
- [ ] 添加摩擦力让球最终停下来

**验收标准：**
- 球可以在桌面上滚动、弹跳、被鼠标踢飞
- 物理行为符合直觉（没有穿墙、没有卡住）
- 60fps 稳定

**技术决策：**
- Phase 1 不引入 SpriteKit，纯 Core Animation 验证手感
- 物理引擎直接扩展 HUDPanel 的 `step(dt:)` 函数

### Phase 2：视觉升级（2-3 天）

**目标：** 从"能玩"到"好看"

**任务：**
- [ ] 引入 SpriteKit（`SKView` 嵌入 `NSPanel`）
- [ ] 足球 sprite atlas + 物理材质
- [ ] 实现阴影透视（shadow offset/radius 随高度变化）
- [ ] 实现 squash & stretch（弹跳瞬间球体压扁）
- [ ] 实现滚动旋转（纹理旋转 = 线速度 / 半径）
- [ ] 实现静止呼吸动画（停止时轻微 scale 脉冲）

**验收标准：**
- 视觉真实感达到"桌面宠物"级别
- 所有运动状态都有对应的视觉反馈
- 性能无回退（仍然 60fps）

### Phase 3：体验打磨（2-3 天）

**目标：** 从"好看"到"有灵魂"

**任务：**
- [ ] 实现粒子效果（踢球时尘土/草屑）
- [ ] 实现声音系统（踢球声、弹跳声、滚动声）
- [ ] 实现长按拖拽（抓住球，松开抛出）
- [ ] 实现 Mission Control 兼容（接受系统缩放 + 可选隐藏）
- [ ] 实现透视缩放暗示（上方球体微微变大）
- [ ] 性能优化和边界情况处理

**验收标准：**
- 体验达到"让人忍不住玩几分钟"的水平
- 所有交互都有声音反馈（可选开关）
- 边界情况处理完善（快速连续踢球、球飞出屏幕等）

### Phase 4：扩展功能（持续迭代）

**目标：** 增加可玩性和个性化

**任务：**
- [ ] 多球类型切换（足球、篮球、乒乓球）
- [ ] 屏幕震动效果
- [ ] 与 HUDPanel 互动（球撞到 HUD）
- [ ] 自定义纹理（用户拖入图片）
- [ ] 节日主题

---

## Technical Architecture

### 文件结构

```
apps/macos/Sources/
├── GoalHUD/                    # 现有 HUD 应用
│   ├── Views/
│   │   ├── HUDPanel.swift      # 现有物理引擎（参考）
│   │   ├── HUDWindowController.swift
│   │   └── ...
│   └── ...
├── Football/                   # 新增：桌面足球模块
│   ├── FootballApp.swift       # 独立应用入口（或集成到 GoalHUD）
│   ├── FootballPanel.swift     # 足球窗口（NSPanel 子类）
│   ├── FootballScene.swift     # SpriteKit 场景（如果使用 SpriteKit）
│   ├── FootballNode.swift      # 足球节点（物理 + 渲染）
│   ├── FootballPhysics.swift   # 物理参数和扩展
│   ├── FootballInteraction.swift  # 鼠标交互逻辑
│   └── Resources/
│       ├── Football.atlas/     # 足球纹理图集
│       └── Sounds/             # 音效文件
└── GoalHUDCore/                # 共享库（可选扩展）
```

### 依赖关系

```
Football
├── GoalHUDCore (可选，复用 AttractionMotion)
├── SpriteKit (系统框架)
├── AVFoundation (声音，可选)
└── AppKit (窗口管理)
```

### 关键类设计

**FootballPanel.swift**
```swift
final class FootballPanel: NSPanel {
    // 窗口配置（复用 HUDPanel）
    // - level = .floating
    // - backgroundColor = .clear
    // - isOpaque = false
    // - hasShadow = false
    // - collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    
    // SpriteKit 视图
    private var skView: SKView?
    private var scene: FootballScene?
}
```

**FootballScene.swift**
```swift
class FootballScene: SKScene {
    // 足球节点
    private var ball: FootballNode?
    
    // 物理世界配置
    override func didMove(to view: SKView) {
        physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)
        physicsWorld.contactDelegate = self
    }
    
    // 鼠标事件处理
    override func mouseDown(with event: NSEvent) { ... }
    override func mouseDragged(with event: NSEvent) { ... }
    override func mouseUp(with event: NSEvent) { ... }
}
```

**FootballNode.swift**
```swift
class FootballNode: SKSpriteNode {
    // 物理体
    private var physicsBody: SKPhysicsBody?
    
    // 状态
    private var isGrabbed = false
    private var lastVelocity: CGVector = .zero
    
    // 更新旋转
    override func update(_ currentTime: TimeInterval) {
        // 根据线速度更新旋转
        let angularVelocity = physicsBody!.velocity.dx / size.width
        zRotation += angularVelocity * dt
    }
}
```

---

## Success Metrics

### Leading Indicators（上线后 1-2 周）

| 指标 | 目标 | 测量方式 |
|------|------|---------|
| **首次交互率** | 80% 用户在首次看到球时尝试点击/移动鼠标 | 匿名事件追踪（如果实现） |
| **单次使用时长** | 平均每次"玩"球 > 30 秒 | 匿名事件追踪 |
| **每日使用率** | 50% 用户每天至少玩一次球 | 匿名事件追踪 |
| **性能达标率** | 99% 时间 > 55fps | 性能监控 |

### Lagging Indicators（上线后 1-2 月）

| 指标 | 目标 | 测量方式 |
|------|------|---------|
| **用户满意度** | NPS > 40 | 用户调研 |
| **留存率** | 7 天留存 > 60% | 匿名事件追踪 |
| **口碑传播** | 20% 用户分享给朋友 | 用户调研 |
| **GoalHUD 整体留存** | 不降低 GoalHUD 核心功能留存 | 对比实验 |

### 定性指标

- 用户反馈中出现"好玩"、"有趣"、"忍不住玩"等关键词
- 社交媒体上出现用户自发分享的截图/视频
- GitHub issues 中出现功能建议（说明用户深度使用）

---

## Open Questions

| # | 问题 | 负责人 | 阻塞性 |
|---|------|--------|--------|
| Q1 | 足球是作为 GoalHUD 的子功能，还是独立应用？ | 产品 | 是 |
| Q2 | 是否需要匿名使用数据追踪？如何平衡隐私？ | 产品/工程 | 否 |
| Q3 | 声音系统是否需要支持用户自定义音效？ | 产品 | 否 |
| Q4 | 多球类型是否需要支持用户上传自定义纹理？ | 产品 | 否 |
| Q5 | 是否需要支持多显示器？球如何在屏幕间移动？ | 工程 | 否 |
| Q6 | SpriteKit 在 NSPanel 中的性能是否达标？需要 benchmark。 | 工程 | 是 |
| Q7 | CVDisplayLink 与 SpriteKit 物理循环是否冲突？需要验证。 | 工程 | 是 |
| Q8 | Mission Control 缩放后，球的位置如何恢复？ | 工程 | 否 |
| Q9 | 高分辨率 Retina 屏幕上纹理是否需要 @2x 版本？ | 设计 | 否 |
| Q10 | 是否需要支持暗色模式？足球纹理是否需要适配？ | 设计 | 否 |

---

## Technical Risks

| 风险 | 级别 | 缓解措施 |
|------|------|---------|
| SpriteKit 在 NSPanel 中的性能 | 中 | `SKView.ignoresSiblingOrder = true` + `shouldCullNonVisibleNodes` + benchmark |
| CVDisplayLink 与 SpriteKit 物理循环冲突 | 低 | SpriteKit 自带物理循环，可以关掉 CVDisplayLink，让 SpriteKit 全权负责 |
| 球飞出屏幕外 | 低 | 已有 wall bounce 逻辑，添加边界检测 |
| 与 GoalHUD 的 HUDPanel 共存 | 中 | 独立窗口实例，相同 `collectionBehavior`，测试多窗口场景 |
| 高分辨率 Retina 屏幕 | 低 | `SKView` 原生支持 Retina，纹理提供 @2x 版本 |
| 声音系统延迟 | 低 | 使用 `AVAudioEngine` 而非 `NSSound`，预加载音效文件 |
| 用户快速连续踢球导致物理不稳定 | 中 | 添加速度上限（`maxVelocity`），防止球飞出屏幕 |

---

## Appendix

### A. 物理参数参考

**真实足球参数：**
- 质量：0.43 - 0.45 kg
- 直径：22 cm
- 弹性系数：0.5 - 0.6
- 空气阻力系数：0.25

**桌面足球参数（适配屏幕尺寸）：**
- 质量：0.45 kg（SpriteKit 单位）
- 半径：20 pt（屏幕像素）
- 重力：-9.8 m/s²（SpriteKit 单位）或 -980 pt/s²（自定义单位）
- 弹性系数：0.6（初次弹跳）→ 0.2（衰减后）
- 地面摩擦：0.92
- 空气阻力：0.1（linearDamping）

### B. 关键代码片段

**重力系统扩展（复用 HUDPanel）：**
```swift
// 在 step(dt:) 中添加
let gravity = CGPoint(x: 0, y: -980)
vel.x = vel.x * decay + (force.x + gravity.x) * dt
vel.y = vel.y * decay + (force.y + gravity.y) * dt
```

**鼠标踢球（复用 repulseForce）：**
```swift
// 修改 repulseForce 为踢球逻辑
private func kickForce(mouse: NSPoint, mVel: CGPoint) -> CGPoint {
    let edgeDist = hypot(mouse.x - frame.midX, mouse.y - frame.midY)
    guard edgeDist < kickRadius else { return .zero }
    
    let approachSpeed = max(0, mVel.x * ndx + mVel.y * ndy)
    let kickMag = kickK * approachSpeed * (1.0 - edgeDist / kickRadius)
    
    return CGPoint(x: ndx * kickMag, y: ndy * kickMag)
}
```

**阴影透视：**
```swift
let heightFactor = max(0, ballVelocity.y) / 1000
shadowLayer.shadowOffset = CGSize(width: 0, height: -10 * heightFactor)
shadowLayer.shadowRadius = 5 + 15 * heightFactor
shadowLayer.shadowOpacity = Float(0.3 - 0.2 * heightFactor)
```

### C. 参考项目

- **Desktop Goose (macOS)**：桌面宠物，使用 SpriteKit + NSPanel
- **Screensaver: Fluid**：流体屏保，使用 SpriteKit 物理
- **iOS 游戏：Doodle Jump**：简单的重力 + 弹跳物理
- **macOS 桌面宠物：Rocket**：使用 Core Animation 的桌面宠物

---

## Version History

| 版本 | 日期 | 作者 | 变更 |
|------|------|------|------|
| v0.1 | 2026-05-28 | GoalHUD Team | 初始 PRD |

---

## Next Steps

1. **Review PRD**：团队评审，确认优先级和范围
2. **Prototype**：Phase 1 快速原型（1-2 天）
3. **Benchmark**：验证 SpriteKit 在 NSPanel 中的性能
4. **Design**：足球纹理和 UI 设计
5. **Implementation**：按 Phase 分阶段实现
