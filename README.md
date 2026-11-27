# tzyhb

独立的通用 iOS 调试采集插件示例：悬浮入口、窗口/视图树/VC 树采集、截图与本地诊断目录导出。

## 构建

需要 Theos：

```sh
make clean package FINALPACKAGE=1
```

本工程没有针对任何第三方 App 的私有类名、业务 Hook 或逆向逻辑。`tzyhb.plist` 中的 `com.apple.UIKit` 是未配置目标时的占位过滤项；首次使用请在系统设置的 tzyhb 面板中选择目标 App 并保存，再按提示重启该 App。SpringBoard 会被插件主动排除，不是可用的默认目标。

## 输出

导出的诊断目录包括：
- `metadata.json`
- `view-tree.txt`
- `view-controllers.txt`
- `screenshot.png`
