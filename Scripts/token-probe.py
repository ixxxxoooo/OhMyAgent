#!/usr/bin/env python3
# @author ixxxxoooo
# token 消耗探针(问题:每次发消息是不是在重复发送上下文?):
# 启动本地假 Anthropic 网关(Scripts/mock-anthropic.py --log),让真实的 claude-agent-acp 适配器 + 本机 claude
# 连到它,连续发 N 条很短的消息,统计「每条消息到底触发了几次上游请求、请求体多大、有没有 cache_control 缓存断点」。
# 不消耗任何真实 token。用法:
#   Scripts/token-probe.py [--turns 8] [--claude ~/.local/bin/claude]
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_probe():
    spec = importlib.util.spec_from_file_location("probe", os.path.join(ROOT, "Scripts/real-agent-probe.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_log(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--turns", type=int, default=8)
    parser.add_argument("--port", type=int, default=3987)
    parser.add_argument("--claude", default=shutil.which("claude") or os.path.expanduser("~/.local/bin/claude"))
    options = parser.parse_args()

    adapter = os.path.join(ROOT, "build/acp-stage/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")
    if not os.path.exists(adapter):
        adapter = os.path.join(ROOT, "Vendor/acp/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")
    work = tempfile.mkdtemp(prefix="oma-token-")
    log = os.path.join(work, "upstream.jsonl")
    mock = subprocess.Popen([sys.executable, os.path.join(ROOT, "Scripts/mock-anthropic.py"), "--port", str(options.port), "--log", log],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.8)
    probe = load_probe()
    env = dict(os.environ)
    env.update({"ANTHROPIC_BASE_URL": f"http://127.0.0.1:{options.port}", "ANTHROPIC_API_KEY": "mock-key",
                "CLAUDE_CODE_EXECUTABLE": options.claude})
    rows = []
    agent = None
    try:
        agent = probe.Agent(shutil.which("node") or "node", [adapter], work, env=env)
        agent.call("initialize", {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": False}}}, timeout=30)
        created = agent.call("session/new", {"cwd": work, "mcpServers": []}, timeout=60)
        session_id = created.get("result", {}).get("sessionId")
        if not session_id:
            raise RuntimeError(f"session/new 失败:{created}")
        for turn in range(1, options.turns + 1):
            before = len(read_log(log))
            started = time.time()
            agent.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": f"第{turn}个问题:请用一句话回答 {turn}+{turn}"}]}, timeout=120)
            time.sleep(0.6)
            new = read_log(log)[before:]
            rows.append({"turn": turn, "seconds": round(time.time() - started, 1), "requests": [
                {"model": r["model"], "stream": r["stream"], "bodyKB": round(r["bodyBytes"] / 1024, 1), "messages": r["messages"],
                 "systemKB": round(r["systemBytes"] / 1024, 1), "tools": r["tools"], "toolsKB": round(r["toolsBytes"] / 1024, 1),
                 "cacheControlMarks": r["cacheControlMarks"], "maxTokens": r["maxTokens"], "lastUser": r["lastUser"]} for r in new]})
    finally:
        if agent:
            agent.stop()
        mock.kill()
        shutil.rmtree(work, ignore_errors=True)
    print(json.dumps({"adapter": adapter, "turns": rows}, ensure_ascii=False, indent=2))
    # 汇总表
    print("\n轮次 | 上游请求数 | 主请求体(KB) | 消息条数 | system(KB) | tools(个/KB) | 缓存断点")
    for row in rows:
        main_request = max(row["requests"], key=lambda r: r["bodyKB"], default=None)
        if main_request:
            print(f'{row["turn"]:>4} | {len(row["requests"]):>10} | {main_request["bodyKB"]:>12} | {main_request["messages"]:>8} | '
                  f'{main_request["systemKB"]:>10} | {main_request["tools"]}/{main_request["toolsKB"]} | {main_request["cacheControlMarks"]}')
        else:
            print(f'{row["turn"]:>4} | 0')


if __name__ == "__main__":
    main()
