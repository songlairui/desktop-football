# HAND_OFF

> 生成时间：2026-05-30

## 目标

将 Desktop Football 从 2D CALayer "窗口即球" 升级到 **Metal 3D 透视渲染管线**（球体 PBR Phong 光照 + 局部阴影 + 固定 Vista Aurora 风格摄像机）。

## 当前状态

`feat/metal-3d` 分支，debug/release 均构建通过，38 个单元测试全绿。运行时已能显示 Metal 足球；全屏窗口默认点击穿透，不再吞噬整屏鼠标事件。多屏策略已从“覆盖所有屏幕 union frame”改为“只覆盖球所在屏幕”，避免副屏被透明 overlay 占用。Menubar beachball 已定位并修复：CVDisplayLink 不再无限堆积 main queue render tick，菜单 tracking 时跳过渲染。

## 已完成

- `Shaders.metal` → 源代码已嵌入 `MetalScene.shaderSource` 字符串常量，SPM 无需处理 `.metal` 文件。原始 `Shaders.metal` 文件已删除。
- `MetalScene.swift` — Metal 管线：球体/阴影 mesh（ModelIO）、程序化足球纹理、`screenToWorld()` ray-plane 坐标映射、Phong + Fresnel 光照
- `MetalCamera.swift` — 固定透视摄像机 eye(0, 550, 480)，55° FOV
- `FootballMetalView.swift` — CAMetalLayer-backed NSView，CVDisplayLink 驱动渲染；首帧主动建立 drawable/depth texture，避免依赖 `layout()`
- `FootballPanel.swift` — 窗口改为当前屏幕透明 overlay，不再 `setFrameOrigin` 跟随球；球跨屏时移动整块 overlay 到球所在屏
- 运行时修复：`ignoresMouseEvents` 默认 true；`mouseDown` 二次确认距离，避免过期 hit-test 抓走点击
- 运行时修复：暂时不渲染全屏地面 plane，避免透明窗口看起来像覆盖层；桌面本身作为视觉地面
- 运行时修复：CVDisplayLink 加 `DispatchSemaphore` 帧合并；`RunLoop.Mode.eventTracking` 下跳过渲染，避免 menubar 打开时主线程卡在 `CAMetalLayer.nextDrawable()`
- 空间表达修复：采用固定“鱼缸”摄像机，2D 物理只映射到 world X/Y，world Z 固定为 0；地面辅助网格使用固定世界坐标，不再跟随球心动态转换
- 交互修复：鼠标被定义为“前玻璃平面”输入；扫过球的屏幕投影接触盘才触发一次性冲量，拖拽只在可见命中圆内捕获；`FootballMetalView` 叠加淡色命中环/扫击环反馈
- 纹理修复：程序化足球纹理改为 TRIONDA 风格近似，白色 matte base + 红/绿/蓝波形面板 + 金色细线 + 星/枫叶/鹰抽象图形；不包含 FIFA/adidas logo
- 特效窗口修复：`EffectsOverlayPanel` 不再覆盖所有显示器 union，只在打击点附近创建 420×420 小透明窗口，避免重新引入副屏覆盖问题
- 废弃文件仍在仓库但未被引用：`FootballLayerView.swift`、`BallTexture.swift`

## 待完成

1. 将 `EffectsOverlayPanel` 效果（涟漪、刀痕）迁移到 Metal billboards，进一步减少多窗口叠加
2. 3D 物理引擎改造（`BallState` 加 Z 轴）
3. 如需真实 3D 控制，再引入显式 Z 轴输入（滚轮或 Shift+drag）；默认不要做隐式 3D ray casting
4. GLB/GLTF 皮肤加载
5. 如果仍需要更强“球场/地面”，保持低 alpha 或只画球附近局部参照，不能再铺满 screen frame 变成覆盖层

## 核心问题分析

### 已修复：全屏窗口拦截所有鼠标事件，导致"无法关闭"

**根因**：FootballPanel 从 170×170 小窗变为全屏 overlay（覆盖所有显示器）。旧架构中窗口很小，鼠标点击自然落在窗口之外的区域；新架构中窗口铺满全屏，**每一帧都在 toggle `ignoresMouseEvents`**，而 `mouseDown` 可能在任何时刻到达。

时序问题：
```
Frame N:   ignoresMouseEvents = true   (窗口透明穿透)
           ← mouseDown 到达，窗口收到事件！← updateInteractivity 刚把 flags 改成 false
           但 mouseDown 是在 ignoresMouseEvents 切换间隙到达的
```

另外 `mouseDown` 里调用了 `NSEvent.mouseLocation`（全局坐标），但 event 的 `locationInWindow` 是窗口内坐标——全屏窗口的坐标和屏幕坐标相同，所以逻辑可能没崩，但拦截问题仍在。

**已采用修复**：`ignoresMouseEvents` 在 init/orderFront 时默认设为 `true`，每帧都按鼠标与球的距离重新赋值；`mouseDown` 再做一次距离检查，防止上帧刚进入 interactive、下一帧鼠标已离开时仍抓走点击。

### 已修复：Metal 场景不显示

修复点：
1. `FootballMetalView` 在 init、`viewDidMoveToWindow()`、`layout()` 和 render 前都会同步 `CAMetalLayer.drawableSize` 并创建 depth texture；`render()` 不再强制解包 nil depth texture。
2. ModelIO mesh 显式绑定 Metal vertex descriptor，否则 shader attribute layout 与 mesh buffer layout 可能不一致。
3. `screenToWorld()` 改为用当前 overlay viewport 的 normalized device coordinate 反投影 ray，再与球所在高度平面求交，避免球落在摄像机视锥外。
4. 修正矩阵构造为 column-major；地面 shader 也改为应用 model matrix。

### 已修复：副屏被覆盖

根因是 overlay 用 `unionScreenFrames()` 覆盖所有显示器。即使窗口透明，CAMetalLayer 仍会参与副屏合成。现在 overlay 只使用球所在屏幕的 `NSScreen.frame`；球跨屏后再移动窗口到新屏幕。

### 已修复：menubar 点击后卡死 / 彩虹圈

`sample` 显示主线程在 status bar menu tracking loop 里反复执行 CVDisplayLink 派发到 main queue 的渲染任务，并长期卡在 `CAMetalLayer.nextDrawable()` 的 semaphore wait。根因是旧注释假设 GCD 会合并 main queue 帧，但 GCD 不会合并。现在使用 `framePermit` 保证最多一个待处理 frame，并在 `.eventTracking` runloop mode 下直接跳过渲染。

### 已修复：辅助坐标系像动态转换

旧辅助网格按球心生成局部范围，球移动时网格范围也跟着移动，视觉上像坐标系在重新变换。现在使用固定鱼缸世界：`BallState.center.x/y` 映射到 world X/Y，world Z 固定为 0；地面网格按固定 world X/Z 范围生成，球只是在其中移动。

### 已修复：控制触发不可预测

旧模型把鼠标附近当作持续力场，用户看不到“什么时候会踢中”。现在交互明确为 2.5D：鼠标只在屏幕/鱼缸前玻璃平面移动，只有鼠标轨迹扫过球的投影接触盘才触发一次性冲量。新增 `GlassContact` 纯逻辑模块和 5 个单测覆盖快扫、慢扫、盘外经过、冷却、已在盘内等场景。

### 已修复：打击特效重新覆盖副屏

`EffectsOverlayPanel.shared` 原本一旦创建就会覆盖所有显示器 union。新的扫击逻辑会调用打击特效，因此这个旧窗口会把“副屏被覆盖”问题带回来。现在 `EffectsOverlayPanel` 改成 420×420 小窗，显示前移动到打击点附近，窗口列表验证只剩当前屏幕主 overlay。

### 已优化：足球纹理不像足球

官方资料显示 2026 世界杯官方比赛球是 adidas TRIONDA，设计关键词是 red/green/blue、three waves、four-panel construction、gold detailing 和主办国图形。当前实现采用程序化 TRIONDA 风格近似：三色波形面板、浅色面板缝、细金色描边、星/枫叶/鹰图形；没有复刻商标或官方 logo。

## 关键决策

- **选 Metal + ModelIO 而非 SceneKit**：SceneKit 已 deprecated（macOS 15+），但它的 `SCNView` 嵌入 NSWindow 做 desktop overlay 有成熟的透明合成支持。Metal 自定义管线需要完全自己处理合成——CAMetalLayer 的透明背景 `isOpaque = false` + `clearColor(0,0,0,0)` 理论上可行，但实际与 WindowServer 合成可能有边缘情况。
- **shader 嵌入 Swift 源码**：避免 SPM 资源处理 `/ Shaders.metal` 的警告和构建复杂性，运行时 `makeLibrary(source:)` 编译。
- **当前屏幕 overlay 替代 170×170 小窗**：3D 场景需要固定摄像机，但不能覆盖所有显示器；只覆盖球所在屏幕，跨屏时移动 overlay。
- **桌面作为地面**：全屏 plane 即使 alpha 很低也会让透明窗口读成覆盖层，所以暂时不渲染全屏 ground pass。
- **固定鱼缸坐标**：屏幕视作固定摄像机前的玻璃面，现有 2D 物理映射到 world X/Y；Z 仅用于透视和地面网格，不参与物理。
- **2.5D 交互优先于隐式 3D ray casting**：鼠标天然是 2D 平面输入。默认只做屏幕投影接触盘的扫击/拖拽；如果未来要控 Z，需要显式手势。
- **TRIONDA 只做风格近似**：视觉上跟 2026 官方球靠近，但不包含 FIFA/adidas 商标，避免把程序化贴图变成未经授权的官方复制品。

## 踩坑记录

- **SPM 的 `.metal` 文件处理**：SPM 对 executableTarget 中的 `.metal` 文件不会自动编译链接，产出 `found 1 file(s) which are unhandled` 警告。运行时 `makeDefaultLibrary()` 返回 nil → crash。解决方案：shader 源码嵌入 Swift 字符串，`device.makeLibrary(source:options:)` 运行时编译。
- **MDLMesh API 在 macOS 14+ 有变化**：`newSphere(withRadii:)` → `sphere(withExtent:)`，`newPlane(withWidth:height:)` → `plane(withExtent:)`，参数名从 `radialSegments` 变为 `segments`。
- **Package.swift 参数顺序**：Swift 6 要求 `swiftSettings` 必须在 `linkerSettings` 之前，否则 manifest 解析失败。
- **多屏 overlay 不要 union**：`NSScreen.screens` 的 union 会覆盖副屏和屏幕间空洞。透明窗口也可能被用户感知为覆盖层；应只覆盖当前屏幕。
- **别忘了辅助窗口也可能 union**：不仅主 `FootballPanel`，旧 `EffectsOverlayPanel` 也会覆盖所有显示器。任何透明辅助窗口都要检查 `CGWindowList`，确认 bounds 不是所有屏幕 union。

## 下一步

1. 手感校准：实际使用时观察扫击盘半径 `glassStrikeRadius` 和最小速度 `swipeSoundThreshold`，必要时把普通模式半径从 `max(radius*2.2, radius+34)` 微调。
2. 把 charge release ring、combo slash/ripple 从 `EffectsOverlayPanel` 迁入 Metal billboard，减少多窗口叠加。
3. 再做一轮多屏人工 QA：主屏/副屏启动、拖拽跨屏、菜单 Hide/Show、Quit。
4. 若需要官方级球体模型，下一步不是继续改 2D 纹理，而是加载 GLB/GLTF：四片式面板 seam 几何、normal map、roughness map。

## 关键文件

- `apps/macos/Sources/DesktopFootball/MetalScene.swift` — Metal 管线核心，shader 编译、mesh 创建、纹理生成、渲染循环
- `apps/macos/Sources/DesktopFootball/FootballPanel.swift` — 窗口策略 + 物理 tick + 所有交互（snap/combo/charge/cruise）
- `apps/macos/Sources/DesktopFootball/FootballMetalView.swift` — CAMetalLayer NSView，render() 桥接
- `apps/macos/Sources/FootballPhysics/GlassContact.swift` — 前玻璃扫击判定，纯逻辑可测试
- `apps/macos/Sources/DesktopFootball/MetalCamera.swift` — 透视摄像机参数
- `apps/macos/Tests/FootballPhysicsTests/GlassContactTests.swift` — 2.5D 扫击触发测试
- `apps/macos/Tests/FootballPhysicsTests/BallStateTests.swift` — 物理测试，修改 BallState 前必须通过
