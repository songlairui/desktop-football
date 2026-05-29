# ADR 0001 — 渲染与物理架构：窗口即球 + Core Animation，而非 SpriteKit

- 状态：已采纳
- 日期：2026-05-29
- 关联：`docs/specs/desktop-football.md`、`docs/kickoff/START.md`

## 背景

PRD 把 **SpriteKit** 列为首选渲染/物理方案（⭐⭐⭐⭐⭐），把 **Core Animation** 列为"轻量备选"，
并规划在 Phase 2 引入 SpriteKit。实现前对该方案做了甄别，发现一个被 PRD 忽略的根本矛盾。

## 甄别出的问题

### 1. SpriteKit 与"桌面自由滚动"互斥（关键）

G1 / US-1 的核心需求是"球可以在**整个桌面**上滚动、弹跳、被踢飞"。

- SpriteKit 的球在 `SKScene` 的**内部坐标系**里运动，`SKView`/`NSPanel` 窗口本身**不动**。
  → 球被困在固定窗口里，无法漫游桌面。
- 若让窗口铺满全屏（透明）来容纳漫游：透明窗口要么吞掉所有桌面点击（无法用其它 app），
  要么 `ignoresMouseEvents` 全程穿透（无法踢球）——两者互斥。
- 若让窗口动态跟随球移动：那移动窗口的物理就得在窗口层做，SpriteKit 的内部物理就白用了，
  等于退回 `HUDPanel` 模式。

PRD 的开放问题 Q6/Q7（"SpriteKit 在 NSPanel 中性能/与 CVDisplayLink 是否冲突"）其实问错了方向——
真正的阻塞点不是性能，而是**坐标系范式不兼容**。

### 2. 物理参数两套单位并存

PRD 同时给出自定义积分器（`gravity = -980 pt/s²`，手写碰撞）和 SpriteKit（`gravity = -9.8 m/s²`，
自带物理）两套参数。二者互斥，不能同时复用。

### 3. 透视缩放公式自相矛盾

PRD 文字说"球在屏幕上方时微微变大（模拟远处）"，但其给出的公式
`scale = 1.0 + 0.1 * (1 - normalizedY)` 实际是**底部更大**。语义与公式不一致。

## 决策

**采用"窗口即球"（window-is-the-ball）+ Core Animation 渲染 + 纯 Swift 自定义物理引擎。**
即把 PRD 的"轻量备选"提升为最终架构，而非临时验证手段。

- **窗口即球**：一个 170×170 的透明无边框 `NSPanel`，物理引擎每帧通过 `setFrameOrigin` 把整个窗口
  在桌面上移动。这正是 `HUDPanel` 已验证的 CVDisplayLink + 窗口位移模型，也是 START.md 作者的
  Phase 1 直觉。
- **Core Animation 渲染**：窗口内用 `CALayer` 三层（阴影 / 形变容器 / 旋转纹理）表现旋转、
  squash & stretch、阴影透视、呼吸动画。极轻量，无需 sprite atlas。
- **物理引擎抽离为纯库** `FootballPhysics`（仅依赖 CoreGraphics，无 AppKit）——可单元测试，
  比 `HUDPanel` 把物理塞进窗口子类更可测。

### 各项甄别的处置

| 甄别点 | 处置 |
|--------|------|
| SpriteKit 范式不兼容 | 不使用 SpriteKit；窗口即球 + CALayer |
| 两套物理单位 | 统一用自定义积分器（pt、pt/s，屏幕坐标 +Y 向上） |
| 重力 -980 偏"飘" | 默认 `gravityY = -2000`，可配置（`PhysicsConfig`） |
| 透视公式矛盾 | 取"飞向用户=略大"的直觉读法，幅度压到 ≤5%，避免误读为 bug |
| 鼠标穿透 vs 踢球 | 全局鼠标轮询驱动力场 + 每帧按"光标是否在球上"切换 `ignoresMouseEvents` |

## 后果

**正面**
- 真正实现了"整个桌面漫游"，与 `HUDPanel` 共享成熟窗口模型，可与 GoalHUD 共存（G4）。
- 物理逻辑 100% 可单测，21 个测试锁定行为契约。
- CALayer 渲染开销极低，利于 G5（60fps / CPU < 3%）。

**代价 / 取舍**
- 阴影是"附着在球上的伪 3D 高度暗示"（offset/blur/opacity 随高度变化），
  而非投影在真实地面的几何阴影——这与 PRD 的阴影公式一致，是有意取舍。
- 粒子效果（R9）改用 `CAEmitterLayer` 而非 `SKEmitterNode`（后续 Phase）。

## 未实现 / 后续（对应 PRD Phase 3–4）

- R9 粒子（踢球尘土/草屑）：`CAEmitterLayer`
- R13 多球类型、R16 自定义纹理、R17 节日主题
- US-5 Mission Control 主动检测隐藏（当前采用 PRD 推荐的"接受系统缩放"策略）
