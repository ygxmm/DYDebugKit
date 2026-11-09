import os
import io
import shutil

# 1. 自动备份整个工程（防止改坏）
if not os.path.exists('../tzyhb_backup_before_rename'):
    os.system('cp -r . ../tzyhb_backup_before_rename')
    print('✅ 已备份到 ../tzyhb_backup_before_rename')

# 2. 要替换的文本规则 (注意顺序，先长后短)
text_replacements = [
    ('DYKillerOverlayWindow', 'TZOverlayWindow'),
    ('DYKiller', 'tz'),
    ('dykiller', 'tz'),
    ('DKDebug', 'TZDebug'),
    ('DKClass', 'TZClass'),
    ('DKStatic', 'TZStatic'),
    ('DKZip', 'TZZip'),
    ('DKAudio', 'TZAudio'),
    ('DKIs', 'TZIs'),
    ('DKGet', 'TZGet'),
    ('DKRegister', 'TZRegister'),
    ('DKRun', 'TZRun'),
    ('DKCapture', 'TZCapture'),
]

# 3. 遍历并替换文件内容
for root, dirs, files in os.walk('.'):
    if '.git' in root or '.theos' in root:
        continue
    for file in files:
        if file.endswith(('.h', '.m', '.mm', '.xm', '.plist', '.md', '.txt')):
            filepath = os.path.join(root, file)
            try:
                with io.open(filepath, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                new_content = content
                for old, new in text_replacements:
                    new_content = new_content.replace(old, new)
                
                if new_content != content:
                    with io.open(filepath, 'w', encoding='utf-8') as f:
                        f.write(new_content)
                    print(f'✅ 内容替换成功: {filepath}')
            except Exception as e:
                pass

# 4. 遍历并重命名文件（把文件名里的 DK 或 DYKiller 换成 TZ 或 tz）
for root, dirs, files in os.walk('.', topdown=False):
    if '.git' in root or '.theos' in root:
        continue
    for file in files:
        if ('DK' in file or 'DYKiller' in file) and file.endswith(('.h', '.m', '.mm', '.xm', '.bak')):
            old_path = os.path.join(root, file)
            new_file = file.replace('DYKiller', 'tz').replace('DK', 'TZ')
            new_path = os.path.join(root, new_file)
            os.rename(old_path, new_path)
            print(f'✅ 文件重命名: {file} -> {new_file}')

print('\n🎉 全部替换与重命名完成！请运行 grep 检查是否还有残留。')
