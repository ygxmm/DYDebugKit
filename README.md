# DYDebugKit

独立的通用 iOS 调试采集插件示例：悬浮入口、窗口/视图树/VC 树采集、截图与本地诊断目录导出。

## 构建

需要 Theos：

```sh
make clean package FINALPACKAGE=1
```

本工程没有针对任何第三方 App 的私有类名、业务 Hook 或逆向逻辑。默认 Filter 使用 SpringBoard 仅作为示例，请按你的测试目标修改 `DYDebugKit.plist`。

## 输出

导出的诊断目录包括：
- `metadata.json`
- `view-tree.txt`
- `view-controllers.txt`
- `screenshot.png`
