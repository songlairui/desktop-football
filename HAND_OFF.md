# HAND_OFF

> 生成时间：2026-05-29 17:05

## 目标
完成 desktop-football macOS 桌面足球挂件的 P0+P1 核心实现，已发布 v0.1.0 release。

## 当前状态
P0+P1 核心已交付（含声音），v0.1.0 DMG 已在 GitHub Releases。无未提交变更，下一阶段是 P2 扩展（粒子效果、多球类型等）。

## 已完成
- PRD 甄别：SpriteKit 方案与"桌面漫游"需求范式不兼容，改为"窗口即球"+Core Animation（见 `docs/adr/0001`）
- `FootballPhysics` 纯 Swift 物理库（无 AppKit 依赖）：重力、碰撞、摩擦、踢球力场、旋转、squash/stretch、抓取跟随
- `DesktopFootball` AppKit 应用：CVDisplayLink 驱动、CALayer 三层渲染、程序化足球纹理与阴影、AVAudioEngine 程序化音效、菜单栏控制
- 21 个单元测试全部通过，debug/release 编译通过，.app 打包成功（arm64）
- 6 维对抗式代码审查，5 个确认 bug 已全部修复（CVDisplayLink 线程竞争、音频路由重启、弹跳去抖、音量 setter 竞争、ignoresMouseEvents 迟滞）
- v0.1.0 Release 已发布：`https://github.com/songlairui/desktop-football/releases/tag/v0.1.0`
- `build.sh --release` 可一键构建+ad-hoc签名+DMG

## 待完成（PRD P2，无阻塞依赖）
- 粒子效果（R9）：踢球时草屑/尘土，用 `CAEmitterLayer`
- 多球类型（R13）：纹理图集 + 物理参数预设切换
- 自定义纹理（R16）：用户拖入图片作为球体
- 节日主题（R17）：定时器 + 纹理切换
- 屏幕震动（R14）：踢球瞬间窗口抖动 1-2 帧
- HUDPanel 互动（R15）：窗口间碰撞检测（复杂度高）

## 关键决策
- **窗口即球架构**：小透明 NSPanel 由物理引擎每帧移动 origin，而非让球在固定窗口内运动——这是唯一能实现"整个桌面漫游"的方式，且复用了 GoalHUD 的 CVDisplayLink 模式
- **物理抽离为纯库**：比 GoalHUD 把物理塞进 HUDPanel 更可测试，21 个测试锁定行为契约
- **程序化渲染+音效**：无二进制资源文件，单文件分发，.app 仅 172KB
- **ad-hoc 签名**：未上 App Store，首次打开需用户右键确认 Gatekeeper

## 踩坑记录
- SpriteKit 范式不兼容：球在 SKScene 内部坐标运动，窗口不动→球被困在固定窗口；若铺满全屏则点击穿透与踢球交互互斥
- CVDisplayLink 回调在专用实时线程，非主线程——stepPending 的 test-and-set 是非原子操作，必须把所有逻辑 dispatch 到 main
- AVAudioEngine 音频路由变更后静默停止，ready 标志不重置→声音永久丢失，必须监听 `AVAudioEngineConfigurationChange`
- PRD 给出的"上方变大"透视公式 `scale = 1.0 + 0.1 * (1 - normalizedY)` 实际是底部更大，语义与公式矛盾

## 下一步
1. `cd apps/macos && ./build.sh --open` 启动测试手感，调整 `PhysicsConfig` 参数
2. 实现粒子效果（R9）：`FootballLayerView` 加 `CAEmitterLayer`，在 `tick` 的 `events.landed/hitWall` 处触发
3. 多球类型（R13）：`PhysicsConfig` 预设 + `BallTexture` 纹理切换
4. 考虑 Sparkle 框架实现 app 内自动更新

## 关键文件
- `apps/macos/Sources/FootballPhysics/BallState.swift` — 积分器核心，所有物理行为的入口
- `apps/macos/Sources/DesktopFootball/FootballPanel.swift` — CVDisplayLink 循环 + 鼠标交互 + 窗口移动，集成所有模块
- `apps/macos/Sources/DesktopFootball/FootballLayerView.swift` — CALayer 渲染层，shadow/ballContainer/texture 三层结构
- `docs/adr/0001-rendering-and-physics-architecture.md` — 架构决策记录，理解为何不用 SpriteKit
- `apps/macos/Tests/FootballPhysicsTests/BallStateTests.swift` — 核心测试，修改物理逻辑前必须通过
