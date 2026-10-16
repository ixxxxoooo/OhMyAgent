#!/usr/bin/env python3
"""向 en.lproj/Localizable.strings 追加缺失的键(已存在的跳过)。用法: add-strings.py "中文=English" ...
@author ixxxxoooo"""
import re, sys
p = 'Resources/en.lproj/Localizable.strings'
s = open(p, encoding='utf-8').read()
have = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', s, re.M))
add = []
for arg in sys.argv[1:]:
    k, v = arg.split('=', 1)
    if k not in have:
        add.append('"%s" = "%s";' % (k.replace('"', '\\"'), v.replace('"', '\\"')))
        have.add(k)
if add:
    if not s.endswith('\n'): s += '\n'
    s += '\n'.join(add) + '\n'
    open(p, 'w', encoding='utf-8').write(s)
print('added', len(add))
# 同步生成简体中文资源(键即值)
import os, subprocess
subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "sync-zh-strings.py")], check=True)
