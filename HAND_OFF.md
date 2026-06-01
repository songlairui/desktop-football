# HAND_OFF

> 更新时间：2026-06-01

## 目标
把桌面 football 从"球的 3D 感全靠 shader 假装"推进到"真的有 3D 运动"——
本轮三件事：①修 Trionda 球的"2D 贴图感"②重做 idle 模式（让默认稳态好看）③加 Hanging Charm 挂件模式（让球真的在 3D 空间里动）。

## 当前状态
完成。本轮 3 项改动全部 build + 43 tests 通过，已 commit 在 `d705c99`。
下一个可执行动作：实机跑 Hanging Charm，看 Z 摆动产生的"近大远小"是否到位、绳索是否太亮/太暗。

## 已完成
- **Shader 修 2D 贴图感** (`MetalScene.swift:1302-1330`)：normalMap 拉进漫反射项，加 `bumpWeight` 边缘渐变（silhouette 处归零），`clearCoat`/`broadHotspot` 收回，`rim`/`fresnel`/`hemi` 改回 macroN
- **Idle 模式重命名 + 行为重做** (`FootballPanel.swift:5-17, 622-780`)：
  - `exhibitionSpin` (Exhibition) → `verticalSpin` (Vertical Spin)，0.6 rad/s 稳态 Y 转盘
  - `physicalRoll` (Field Breeze) → `globeRoll` (Globe Roll)，纯物理驱动 launch
  - 默认改为 `verticalSpin`
- **Hanging Charm 模式**（新）：
  - 新建 `FootballPhysics/PendulumState.swift`（3D 弹簧+阻尼+绳约束+持续微风）
  - `BallRenderEffects` 加 `overrideWorldPosition` + `ropeAnchor` 字段
  - `MetalScene.draw` 接受 override 位置并画细绳（halo + core 双线）
  - `FootballPanel` 加 `pendulum` 状态机 + nudge + 物理旁路 + 重力 fallback
  - `mouseDown` 点中球时给 impulse（鼠标→球反方向 + 随机 Z）
  - 重力切到 zero/balloon 时自动回退到 verticalSpin

## 待完成
- 实机验证 Hanging Charm：3D 摆动幅度、Z 摆动产生的"近大远小"、绳索亮度
- 实机验证默认 verticalSpin 转速是否合适（0.6 rad/s 约 10.5s/圈，museum 节奏）
- （可选）shader 加 envMap IBL 反射，让金属感更接近 three.js 加载 glb 的效果

## 关键决策
- **bump 强度 0.55 而非 1.0**：保留手算 key/fill/rim 的"艺术化柔光"语义，避免过脏；如实机太弱可推到 0.7
- **bumpWeight 用 macroFacing 而非 shadeN 驱动渐变**：silhouette 处 fadeOut 必须用光滑球面判断，否则自己掐自己
- **globeRoll 不施加持续力，只在球停稳时给初速度**：纯物理驱动，更像地球仪；方向翻转 50/50 在 launch 之间切换
- **PendulumState 独立于 BallState**：3D 摆动用独立的 `displacement` 状态，绕开 `BallState` 的 2D 物理；mode 切换时创建/丢弃
- **Hanging Charm 物理旁路**：在 mode == .hangingCharm 时跳过 `ball.step()` / kick field / grab / snap，球的运动完全由 `pendulum.step(dt)` 驱动
- **Nudge 用"鼠标远离球"反方向**：模拟"被弹了一下"的手感，不强制是鼠标移动方向

## 踩坑记录
- **`exhibitionSpinSpeed = 8.0` 注释写"°/s"但当 rad/s 用** → 1.27 圈/秒远快于"gentle turntable"，看起来"乱转"。`0.6` rad/s 才是 museum 节奏
- **`0.15 * sin(0.35 * phase)` 每帧累加 X** → 9 rad/s 峰值 X 摆动，明显的"乱转"感。新实现完全去掉
- **`physicalRoll` 用 `blend(velocity, target)` 持续拉** → 撞墙反弹被立刻拉回，方向从不真变。改成"球停稳时给初速度"才符合 globe roll 语义
- **`shadeN = macroN` 导致 normalMap 仅影响高光** → 球身 95% 光照无 3D 感。把 normalMap 拉进 diffuse 后立刻立体
- **bumpN 在 silhouette 处有 halo** → 因为 `dot(macroN, V) ≈ 0`，bump 把法线推到指向观察者，`fresnel`/`rim` 爆掉。加 `bumpWeight` 边缘 fadeOut
- **`shadeN` 算 `hemi` 导致整体变暗** → bump 扰动后 `shadeN.y` 偏小，环境光下移。`hemi` 改回 `macroN.y` 即可
- **`NSPanel` 没有 `window` 属性**（NSWindow.window 是 self，NSView.window 是父窗口）→ NSPanel 自己就是 window，直接用 `frame`
- **`MetalScene.tankPointsToWorld` 是 private** → 在 FootballPanel 端做反向投影时手写公式（hardcode tankHeight=620，跟 MetalScene 内部保持一致）
- **`Bounds` 是屏幕坐标，anchor 要用世界坐标** → 修 `bounds.upperY` 不存在时改用 `620 + 90`（Y=620 是 tank 顶，加 90pt 让锚点在视野外）

## 下一步
1. **实机跑 Hanging Charm**（最优先）：
   - 菜单 Idle Motion → Hanging Charm
   - 球应从顶部垂下，3D 摆动，**近大远小**应肉眼可见
   - 点击球 → 大幅摆动
   - 切 Zero Gravity → 自动回 Vertical Spin
2. **如果不满意**调参参考（参数都在文件头注释里）：
   - 摆动太死 → 调高 `PendulumState.windStrength`（默认 1.1）
   - Z 变化太弱 → 调高 `windStrength` 或减小 `dampingPerSecond`（默认 0.78）
   - 绳太亮/太暗 → 改 `MetalScene.drawRope` 里 `core`/`halo` alpha
   - 启动时球位置不对 → 改 `FootballPanel.hangingCharmRopeLength` / anchor Y
3. **可选 follow-up**：shader 加程序化 envMap (IBL) → 接近 three.js glb 效果

## 关键文件
- `apps/macos/Sources/FootballPhysics/PendulumState.swift` — 3D 阻尼摆，Hanging Charm 的物理核心
- `apps/macos/Sources/DesktopFootball/FootballPanel.swift` — idle 模式状态机 + pendulum 驱动 + mouseDown nudge + 重力 fallback
- `apps/macos/Sources/DesktopFootball/MetalScene.swift` — `ballFragment` bump 修复 + `drawRope` + override 位置支持
- `apps/macos/Sources/DesktopFootball/FootballMetalView.swift` — `BallRenderEffects` 加 `overrideWorldPosition` / `ropeAnchor` 字段

## 验证记录
```bash
cd apps/macos && swift build
# Build complete

cd apps/macos && swift test
# Executed 43 tests, with 0 failures
```

## 仍建议人工确认
- 实机看 Hanging Charm 的 Z 摆动是否够"大"（建议近大远小差异 ≥ 10%）
- verticalSpin 稳态转速是否够"稳"（无 X/Y 抖动）
- globeRoll 撞墙反弹是否符合直觉（restitution 0.74 是底层值）
- Trionda 球的 3D 凹凸是否到位（无边缘 halo，无整体变暗）
