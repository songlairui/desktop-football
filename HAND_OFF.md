# HAND_OFF

> 更新时间：2026-05-31

## 当前状态
Trionda 2026 FIFA 世界杯足球 USDZ 集成已修复到可构建状态。

- `cd apps/macos && swift build` 已通过
- `cd apps/macos && swift test` 已通过，38 个测试 0 失败
- SPM 资源已纳入 `DesktopFootball` executable target
- 已确认 `.process("Resources")` 会把资源打平到 bundle 根目录，因此加载逻辑不再依赖 `Resources/TriondaBall/0` 子目录

## 本轮已修复
- 修复 `BallModel.swift` 的 Swift 编译错误：
  - `MDLAsset` 改为 `asset.count` + `asset.object(at:)` 索引遍历
  - 不再把 `float4x4` 直接赋给 `MDLMesh.transform`
- USDZ 归一化改为渲染时 local transform：
  - 按 mesh bounding box 计算中心和半径
  - `MetalScene` 的 model matrix 追加 `ballLocalTransform`
  - 避免依赖 ModelIO 是否会把 `MDLObject.transform` bake 进顶点数据
- 修复 Bundle 资源路径：
  - 先从 bundle 根目录查找
  - 兼容保留 `TriondaBall` / `Resources/TriondaBall` 子目录的布局
- 拆分球体与地面/阴影 vertex descriptor：
  - 球体使用 tangent，stride 44
  - ground/shadow 继续使用原始 position/normal/uv，stride 32
  - shader 对应拆分为 `BallVertexIn` 和 `SurfaceVertexIn`
- 修复 fallback 渲染风险：
  - 程序化球也生成 tangent
  - fragment shader 始终绑定 baseColor/normal/metallic/roughness 四张纹理
  - 缺失 PBR 贴图时使用 1x1 默认 normal/metallic/roughness 贴图
- 调亮 Trionda shader：
  - 确认 metallic 平均约 5.6%，不是灰蒙蒙主因
  - roughness 贴图是 1x1 纯白，原 PBR 环境光过低会让球偏灰
  - 改成 key/fill/rim 展示光照，并限制 roughness/metallic 对颜色的压制
  - 进一步按 chroma mask 提升有色区域饱和度到最高 2.05，白色面板只做轻微饱和，避免整球过曝
  - 最终 lit color 再做轻微饱和增强，但整体亮度倍率从 `1.14` 收到 `1.12`
- 强化弹跳形变：
  - 3D shader 中 `u.squash` 视觉倍率提升到 1.35，最大 clamp 到 0.68
  - squash 改为近似以底部接触点为锚点压缩，减少落地形变时球底漂浮的感觉
- 根据实机截图继续校正：
  - 可见球半径增加到物理半径的 1.18 倍，并用该半径重新贴地
  - 阴影从原来的 `1.5x scale` 收到 `1.08x visualRadius`
  - 阴影 alpha 从 `0.30` 降到 `0.22`
  - baseColor 饱和度提升到 `1.45`，最终亮度倍率从 `1.08` 调到 `1.14`
- 根据用户反馈进一步调整：
  - `PhysicsConfig.standard.radius` 从 30pt 改到 71pt，让当前可见球约为截图版本的 2 倍，并让视觉、碰撞、边界对齐
  - `MetalCamera` 改成按 viewport 校准投影：`z=0` 前玻璃平面投影后正好覆盖 drawable viewport
  - 相机距离固定为 2200 world units，FOV 由 `frontHeight` 动态计算，保留微弱透视
  - 视觉 Z 空间不再固定 `[-360, 360]`，改为随球大小动态设置，总深度约 3 个球直径
  - `MetalScene` 的 screen -> world 映射改用 viewport 原点/宽高，visible bounds 只用于确定桌面 floor 位置
- 底边统一避开 Dock 区域：
  - `FootballPanel` 不再用 `NSScreen.visibleFrame` 决定底边
  - 活动区域改为 `NSScreen.frame` 加固定 `dockClearance = 80pt` 的 bottom inset
  - 不判断 Dock 是否存在、隐藏或位于哪个方向，各屏幕底边统一上抬同一距离
- 清理冗余资源：
  - 删除 `scene.usdz`（与主 USDZ sha256 完全相同）
  - 删除 `scene.usdc`（已包含在主 USDZ 内）
  - 保留 `fifa_trionda_ball_world_cup_2026.usdz` 和 4 张外部 PBR JPG

## 关键文件
- `apps/macos/Package.swift`
- `apps/macos/Sources/DesktopFootball/BallModel.swift`
- `apps/macos/Sources/DesktopFootball/FootballPanel.swift`
- `apps/macos/Sources/DesktopFootball/MetalCamera.swift`
- `apps/macos/Sources/DesktopFootball/MetalScene.swift`
- `apps/macos/Sources/FootballPhysics/Bounds.swift`
- `apps/macos/Sources/FootballPhysics/PhysicsConfig.swift`
- `apps/macos/Sources/DesktopFootball/Resources/TriondaBall/`

## 验证记录
```bash
cd apps/macos && swift build
# Build complete

cd apps/macos && swift test
# Executed 38 tests, with 0 failures
```

## 仍建议人工确认
- 重新运行 app，观察调亮/放大/viewport 校准后的 Trionda 外观是否过曝、过大或仍偏灰，并确认落地点离屏幕底边约 80pt。
- 如果视觉仍不理想，下一步优先微调 `FootballPanel.dockClearance`、`PhysicsConfig.standard.radius`、`MetalCamera.distance`、`MetalScene.swift` 中的 `shadowScale`、baseColor saturation 和 `color * 1.12`。
