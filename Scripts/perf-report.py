#!/usr/bin/env python3
"""解析 OhMyAgent 日志,输出性能报告。

用法:
  perf-report.py report [--all]   最近一次运行的整体画像(内存、卡顿、耗时 Top、TTFT、代理流、启动阶段、容量峰值)
  perf-report.py mem [--all]      footprint / 子进程内存 / CPU 时序
  perf-report.py slow [--all]     perf 与 git 分类的 WARN/ERROR
  perf-report.py turn <标识>      按会话前缀(session=/sid=)或回合串起相关日志
默认只看最近一次启动的那个进程(按 pid 过滤,避免开发版与安装版混在一起);
--all 看全部保留的日志;--pid N 指定进程。
@author ixxxxoooo
"""
import glob
import os
import re
import statistics
import sys

DIR = os.path.expanduser("~/Library/Logs/OhMyAgent")
LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) (DEBUG|INFO |WARN |ERROR) \[(\w+)\] (.*)$")
KV = re.compile(r'(\w[\w.]*)=("(?:[^"\\]|\\.)*"|\S*)')


def parse(line):
    """解析一行日志,返回 (时间, 级别, 分类, 消息, 字段) 或 None。"""
    m = LINE.match(line.rstrip("\n"))
    if not m:
        return None
    ts, level, cat, rest = m.groups()
    first = KV.search(rest)
    message = rest[:first.start()].strip() if first else rest.strip()
    fields = {k: v[1:-1].replace('\\"', '"') if v.startswith('"') else v for k, v in KV.findall(rest)}
    return ts, level.strip(), cat, message, fields


def load(all_runs, pid=None):
    """读取主程序日志(oma-日期[.n].log),保持文件内顺序;默认只取最近一次启动的那个进程。
    多个进程(开发版、安装版)可能写同一个目录且时区不同,所以不按时间戳排序,而按 pid 过滤。"""
    files = glob.glob(os.path.join(DIR, "oma-[0-9]*.log"))
    entries = []
    for path in sorted(files, key=lambda p: os.path.getmtime(p)):
        with open(path, encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                item = parse(raw)
                if item:
                    entries.append(item)
    if all_runs:
        return entries
    if pid is None:
        starts = [e for e in entries if e[3] == "日志系统启动" and "pid" in e[4]]
        pid = starts[-1][4]["pid"] if starts else None
    if pid is None:
        return entries
    mine = [e for e in entries if e[4].get("pid") == pid]
    # 同一 pid 被复用的极端情况:只取该 pid 最后一次「日志系统启动」之后
    starts = [i for i, e in enumerate(mine) if e[3] == "日志系统启动"]
    return mine[starts[-1]:] if starts else mine


def num(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def pct(values, p):
    ordered = sorted(values)
    return ordered[min(int(len(ordered) * p), len(ordered) - 1)] if ordered else 0


def dist(label, values, unit="ms"):
    if not values:
        return f"  {label}: 无数据"
    return f"  {label}: n={len(values)}  中位 {statistics.median(values):.0f}{unit}  P95 {pct(values, 0.95):.0f}{unit}  最大 {max(values):.0f}{unit}"


def report(entries):
    if not entries:
        print("没有日志。")
        return
    print(f"区间: {entries[0][0]} → {entries[-1][0]}  ({len(entries)} 行)\n")
    samples = [e for e in entries if e[3] == "资源采样"]
    print("== 内存 / CPU ==")
    if samples:
        fp = [num(e[4].get("footprintMB")) for e in samples]
        ch = [num(e[4].get("childMB")) for e in samples]
        cpu = [num(e[4].get("cpuPct")) for e in samples if "cpuPct" in e[4]]
        print(f"  采样 {len(samples)} 次;本进程 footprint 起 {fp[0]:.0f} → 末 {fp[-1]:.0f} MB(最小 {min(fp):.0f},最大 {max(fp):.0f},峰值 {max(num(e[4].get('peakMB')) for e in samples):.0f})")
        print(f"  子进程合计 末 {ch[-1]:.0f} MB(最大 {max(ch):.0f});最后一次线程 {samples[-1][4].get('threads')} fd {samples[-1][4].get('fds')}")
        if cpu:
            print(f"  本进程 CPU 平均 {statistics.mean(cpu):.1f}%  最大 {max(cpu):.0f}%")
        if len(fp) >= 4:
            half = len(fp) // 2
            drift = statistics.mean(fp[half:]) - statistics.mean(fp[:half])
            print(f"  前后半程均值差 {drift:+.0f} MB" + ("  ← 持续增长,需关注" if drift > 50 else ""))
    else:
        print("  没有资源采样记录(采样被关闭,或应用刚启动)")

    print("\n== 告警计数 ==")
    for name in ["内存增长较快", "内存占用偏高", "CPU 持续偏高", "主线程卡顿", "编辑器装载偏慢", "git 命令较慢"]:
        hits = [e for e in entries if e[3] == name]
        extra = ""
        if name == "主线程卡顿" and hits:
            ms = [num(e[4].get("ms")) for e in hits]
            extra = f"  最长 {max(ms):.0f}ms"
        print(f"  {name}: {len(hits)}{extra}")

    print("\n== 启动阶段(sinceLaunchMs) ==")
    stages = [e for e in entries if e[3] == "启动阶段"][-8:]
    for e in stages:
        print(f"  {e[4].get('stage', '-'):<14} {e[4].get('sinceLaunchMs', '-')} ms")

    print("\n== 回合 ==")
    print(dist("首 token 耗时(ttftMs)", [num(e[4]["ttftMs"]) for e in entries if e[3] == "首个输出" and "ttftMs" in e[4]]))
    print(dist("回合总耗时", [num(e[4]["ms"]) for e in entries if e[3] == "轮次结束" and "ms" in e[4]]))

    print("\n== 模型代理流 ==")
    streams = [e for e in entries if e[3] == "代理流结束"]
    print(dist("首块耗时(firstChunkMs)", [num(e[4]["firstChunkMs"]) for e in streams if e[4].get("firstChunkMs", "-") != "-"]))
    print(dist("总耗时(totalMs)", [num(e[4]["totalMs"]) for e in streams]))
    conv = [num(e[4]["convertMs"]) for e in streams if "convertMs" in e[4]]
    if conv:
        print(dist("协议转换累计(convertMs)", conv))
    failed = [e for e in streams if e[4].get("outcome") == "error"]
    print(f"  异常结束: {len(failed)}")

    print("\n== 耗时 Top(最近一轮「性能汇总」) ==")
    summary = [e for e in entries if e[3] == "性能汇总"]
    latest = {}
    for e in summary:
        latest[e[4].get("name")] = e
    rows = sorted(latest.values(), key=lambda e: -num(e[4].get("totalMs")))[:10]
    for e in rows:
        f = e[4]
        print(f"  {f.get('name', '-'):<22} 累计 {num(f.get('totalMs')):>9.0f}ms  次数 {f.get('count'):>6}  P50 {f.get('p50Ms'):>7}  P95 {f.get('p95Ms'):>7}  最大 {f.get('maxMs'):>8}")
    if not rows:
        print("  尚无(每 5 分钟及退出时输出)")

    print("\n== 容量快照(最后一次 / 历史最大) ==")
    snaps = [e for e in entries if e[3] == "容量快照"]
    if snaps:
        keys = sorted({k for e in snaps for k in e[4]} - {"pid"})
        for key in keys:
            values = [num(e[4][key]) for e in snaps if key in e[4]]
            print(f"  {key:<34} {values[-1]:>10.0f}  /  {max(values):>10.0f}")
    else:
        print("  无")


def mem(entries):
    print(f"{'时间':<12}{'本进程MB':>10}{'子进程MB':>10}{'CPU%':>7}{'线程':>6}{'fd':>5}  明细")
    for e in entries:
        if e[3] != "资源采样":
            continue
        f = e[4]
        detail = " ".join(f"{r}={f[r + 'MB']}MB×{f.get(r + 'Count', '?')}" for r in ("agent", "terminal", "lsp") if r + "MB" in f)
        print(f"{e[0][11:19]:<12}{num(f.get('footprintMB')):>10.0f}{num(f.get('childMB')):>10.0f}{f.get('cpuPct', '-'):>7}{f.get('threads', '-'):>6}{f.get('fds', '-'):>5}  {detail}")


def slow(entries):
    for e in entries:
        if e[1] in ("WARN", "ERROR") and e[2] in ("perf", "git", "editor", "lsp"):
            print(" ".join([e[0], e[1], f"[{e[2]}]", e[3]] + [f"{k}={v}" for k, v in e[4].items()]))


def turn(entries, key):
    for e in entries:
        f = e[4]
        if key in (f.get("session"), f.get("sid"), f.get("turn")) or key in e[3] or any(key == v for v in f.values()):
            print(" ".join([e[0], e[1], f"[{e[2]}]", e[3]] + [f"{k}={v}" for k, v in f.items()]))


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    all_runs = "--all" in args
    pid = None
    if "--pid" in args:
        index = args.index("--pid")
        pid = args[index + 1] if index + 1 < len(args) else None
        args = args[:index] + args[index + 2:]
    args = [a for a in args if a != "--all"]
    entries = load(all_runs, pid)
    cmd = args[0]
    if cmd == "report":
        report(entries)
    elif cmd == "mem":
        mem(entries)
    elif cmd == "slow":
        slow(entries)
    elif cmd == "turn" and len(args) > 1:
        turn(entries, args[1])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
