# Dayreed 视觉资源

安静的个人工作记录，以三株芦苇表示持续但不同节奏的活动。界面使用系统字体、SF Symbols 与系统颜色；App 图标使用 Apple 原生玻璃、蓝色底与浅色芦苇，菜单栏使用单色光学尺寸模板。

## 正式源文件

- `Dayreed.icon`：在 Apple Icon Composer 中实际创建、导入图层并保存的可编辑工程。包含原生背景、一个玻璃分组与三个独立 SVG 图层。打开工程可调整各外观与效果。
- `Layers/`：原创芦苇 SVG，1024 × 1024 坐标，供 Icon Composer 导入；同步修改时应在 Composer 重新导入并保存。
- `MenuBar/`：18 pt PDF、18 px PNG 和 36 px PNG 模板。可维护绘制源为 `Sources/DayreedApp/Support/ReedMark.swift`，App 直接使用相同原生绘制代码并设置 `isTemplate = true`。

未使用 Dayflow 素材。早期 imagegen 图片仅用于方向参考，未进入正式工程或编译产物。App 图标以 `.icon` 工程为准，不以传统 icns 为编辑源。

## Apple 工具链编译

在仓库根目录运行：

```sh
script/export_branding.sh
```

该脚本先导出菜单栏模板，再执行：

```sh
xcrun actool Resources/Branding/Dayreed.icon \
  --compile build/branding --platform macosx \
  --minimum-deployment-target 26.0 --app-icon Dayreed \
  --output-partial-info-plist build/branding/Icon-Info.plist
```

需要提供 Icon Composer 支持的 Xcode。输出 `Assets.car`、`Dayreed.icns` 与 `Icon-Info.plist`。Apple 编译器生成兼容尺寸和外观，不需要手工缩放单张 PNG。

App 整包接线：将 `Assets.car` 和 `Dayreed.icns` 放入 `Contents/Resources/`；将编译器生成的 `Icon-Info.plist` 合并入 App `Contents/Info.plist`，当前键为 `CFBundleIconName = Dayreed`、`CFBundleIconFile = Dayreed`。应在签名整包前完成；如果已有资产目录，统一调用 actool，避免覆盖另一个 `Assets.car`。

## 外观检查

在 Icon Composer 选择 Design Generation 26，分别查看 Default、Dark 与 Mono；Mono 是透明单色预览。检查 32、128 与 1024 pt 时芦苇彼此可区分。菜单栏模板由系统适配浅色/深色菜单栏。App 主体依赖原生 NavigationSplitView、工具栏、Form 与控件，不添加自制模糊。
