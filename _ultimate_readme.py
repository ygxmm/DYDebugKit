import io

p = 'DKDebugExport.m'
s = io.open(p, encoding='utf-8').read()

# 寻找函数起点和下一个函数的起点
start_str = 'static NSString *DKReadme('
start_idx = s.find(start_str)
end_str = 'static void DKWriteString('
end_idx = s.find(end_str, start_idx)

if start_idx == -1 or end_idx == -1:
    print("ERROR: 找不到函数边界，请检查代码是否被破坏了")
    raise SystemExit(1)

# 你要的极简 + 带 App 名字的版本
new_readme = '''static NSString *DKReadme(DKDebugExportContext *context, DKDebugExportMode mode) {
    NSDictionary *meta = context.metadata;
    NSMutableString *text = [NSMutableString string];
    
    [text appendFormat:@"DYKiller Runtime Snapshot\\n"];
    [text appendFormat:@"App: %@ %@ (%@) | System: %@ %@ | Time: %@\\n\\n",
        meta[@"bundleName"] ?: @"UnknownApp", meta[@"appVersion"], meta[@"buildVersion"], meta[@"deviceModel"], meta[@"systemVersion"], meta[@"generatedAt"]];

    [text appendString:@"============================================================\\n"];
    [text appendString:@"文件说明 (Data Dictionary)\\n"];
    [text appendString:@"============================================================\\n\\n"];

    [text appendString:@"[manifest.json]\\n"];
    [text appendString:@"- 采集元数据。包含 App 版本、系统版本、屏幕尺寸、目标窗口信息。\\n\\n"];

    [text appendString:@"[page/] UI 主线程快照与本页类\\n"];
    [text appendString:@"- view-tree.txt       视图树文本，带层级缩进，含 Class、frame、hidden、alpha。\\n"];
    [text appendString:@"- view-tree.json      同上，但为 JSON 格式，适合程序解析。\\n"];
    [text appendString:@"- view-controllers.txt VC 树（含 nav.top / tab.selected）。\\n"];
    [text appendString:@"- interactives.txt    可点击元素（UIControl / 手势），含 Target-Action。\\n"];
    [text appendString:@"- texts.txt           页面上的所有文字（UILabel/YYLabel/Button title 等）。\\n"];
    [text appendString:@"- images.txt          所有 UIImageView，含尺寸、帧数、scale。\\n"];
    [text appendString:@"- responders.txt      可交互元素的响应链（view -> VC -> window）。\\n"];
    [text appendString:@"- classes/*.h         运行时 dump 的 Objective-C 头文件。\\n"];
    [text appendString:@"  * 注：仅 dump 了当前页面链路出现过的类。\\n"];
    [text appendString:@"  * 注：方法参数类型多为 id（Runtime 限制），属性名和类名可信。\\n\\n"];

    [text appendString:@"[probe/] 专项探针数据\\n"];
    [text appendString:@"- tabbar.txt          底栏（TabBar）现场。\\n"];
    [text appendString:@"  * === Summary === 段：包含可见/隐藏数量、坐标是否重叠 (visible_overlaps)、总宽。\\n"];
    [text appendString:@"  * === TabBar === 段：具体视图层级、按钮名称 (label)、frame。\\n\\n"];

    [text appendString:@"[ui/] 视觉辅助\\n"];
    [text appendString:@"- screenshot.png      目标窗口的截图（按 windowLevel 从低到高合成）。\\n\\n"];

    [text appendString:@"[常见排查场景]\\n"];
    [text appendString:@"- 按钮不见了：看 view-tree.txt 或 tabbar.txt 里的 hidden 字段。\\n"];
    [text appendString:@"- 按钮点不动：看 interactives.txt 里的 targets 列。\\n"];
    [text appendString:@"- 布局错乱：看 tabbar.txt 的 Summary，检查 visible_overlaps 和 frame 值。\\n"];

    return text;
}

'''

s = s[:start_idx] + new_readme + s[end_idx:]
io.open(p, 'w', encoding='utf-8').write(s)
print('SUCCESS: README 函数已彻底重写，并包含 App 名字')
