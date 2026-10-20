#!/usr/bin/env python3
# @author ixxxxoooo
# 真实 ACP Agent 探针:不经过 OhMyAgent 界面,直接用 stdio JSON-RPC 对本机真实 Agent 做「新建会话 → 发一条很短的消息 →
# 杀进程 → 用新进程 session/load 恢复」的完整往返,验证「恢复会话」在真实引擎上是否可用。
#
# 用法:
#   Scripts/real-agent-probe.py --command opencode2 --args acp [--prompt "只回复 OK"] [--keep-cwd]
# 输出一份 JSON 报告(每个阶段的耗时与结果);退出码 0 表示恢复成功。
# 会产生一次真实模型调用(提示词极短),在临时目录里运行,不碰你的项目。

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time


class Agent:
    """一个以 stdio 通信的 ACP Agent 子进程。"""

    def __init__(self, command, args, cwd):
        self.proc = subprocess.Popen(
            [command, *args], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1)
        self.next_id = 1
        self.pending = {}
        self.updates = []
        self.lock = threading.Lock()
        self.stderr_tail = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.stderr_tail = (self.stderr_tail + [line.rstrip()])[-20:]

    def _send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def _read_stdout(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "method" in message and "id" in message:
                self._answer_request(message)
            elif "method" in message:
                with self.lock:
                    self.updates.append(message)
            elif "id" in message:
                event = self.pending.get(message["id"])
                if event:
                    event["response"] = message
                    event["done"].set()

    def _answer_request(self, message):
        """对 Agent 发来的请求给出最保守的回答(只读文件、拒绝其它能力、权限一律拒绝)。"""
        method = message["method"]
        if method == "session/request_permission":
            options = message.get("params", {}).get("options", [])
            reject = next((o for o in options if "reject" in o.get("kind", "")), None)
            outcome = {"outcome": "selected", "optionId": reject["optionId"]} if reject else {"outcome": "cancelled"}
            self._send({"jsonrpc": "2.0", "id": message["id"], "result": {"outcome": outcome}})
        elif method == "fs/read_text_file":
            try:
                with open(message["params"]["path"], encoding="utf-8") as handle:
                    self._send({"jsonrpc": "2.0", "id": message["id"], "result": {"content": handle.read()}})
            except OSError as error:
                self._send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32000, "message": str(error)}})
        else:
            self._send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "unsupported"}})

    def call(self, method, params, timeout=120):
        request_id = self.next_id
        self.next_id += 1
        event = {"done": threading.Event(), "response": None}
        self.pending[request_id] = event
        started = time.time()
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        finished = event["done"].wait(timeout)
        elapsed = round(time.time() - started, 2)
        if not finished:
            return {"error": {"message": f"超时 {timeout}s"}, "seconds": elapsed}
        response = event["response"]
        response["seconds"] = elapsed
        return response

    def drain_updates(self):
        with self.lock:
            taken, self.updates = self.updates, []
        return taken

    def stop(self):
        try:
            self.proc.kill()
        except OSError:
            pass


def agent_text(updates):
    """从 session/update 通知里拼出助手文字。"""
    chunks = []
    for update in updates:
        body = update.get("params", {}).get("update", {})
        if body.get("sessionUpdate") == "agent_message_chunk":
            content = body.get("content", {})
            if content.get("type") == "text":
                chunks.append(content.get("text", ""))
    return "".join(chunks)


def main():
    parser = argparse.ArgumentParser(description="真实 ACP Agent 的新建/恢复往返探针")
    parser.add_argument("--command", default="opencode2", help="Agent 命令(默认 opencode2)")
    parser.add_argument("--args", nargs="*", default=["acp"], help="命令参数(默认 acp)")
    parser.add_argument("--prompt", default="只回复两个字母:OK", help="发给模型的短消息")
    parser.add_argument("--keep-cwd", action="store_true", help="保留临时工作目录(便于排查)")
    options = parser.parse_args()

    command = shutil.which(options.command) or options.command
    cwd = tempfile.mkdtemp(prefix="oma-probe-")
    report = {"command": command, "cwd": cwd, "stages": {}}
    init_params = {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": False}, "terminal": False}}
    first = second = None
    ok = False
    try:
        first = Agent(command, options.args, cwd)
        init = first.call("initialize", init_params, timeout=30)
        capabilities = init.get("result", {}).get("agentCapabilities", {})
        report["stages"]["initialize"] = {"seconds": init.get("seconds"), "loadSession": capabilities.get("loadSession"),
                                          "resume": bool(capabilities.get("sessionCapabilities", {}).get("resume")), "error": init.get("error")}
        created = first.call("session/new", {"cwd": cwd, "mcpServers": []}, timeout=60)
        session_id = created.get("result", {}).get("sessionId")
        report["stages"]["session/new"] = {"seconds": created.get("seconds"), "sessionId": session_id, "error": created.get("error")}
        if not session_id:
            raise RuntimeError("session/new 失败")
        prompted = first.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": options.prompt}]}, timeout=180)
        reply = agent_text(first.drain_updates())
        report["stages"]["session/prompt"] = {"seconds": prompted.get("seconds"), "stopReason": prompted.get("result", {}).get("stopReason"),
                                              "reply": reply[:80], "error": prompted.get("error")}
        first.stop()
        time.sleep(0.5)

        # 新进程恢复
        second = Agent(command, options.args, cwd)
        second.call("initialize", init_params, timeout=30)
        loaded = second.call("session/load", {"sessionId": session_id, "cwd": cwd, "mcpServers": []}, timeout=60)
        replay = second.drain_updates()
        replayed_user = [u for u in replay if u.get("params", {}).get("update", {}).get("sessionUpdate") == "user_message_chunk"]
        report["stages"]["session/load(新进程)"] = {
            "seconds": loaded.get("seconds"), "error": loaded.get("error"), "replayedUpdates": len(replay),
            "replayedUserMessages": len(replayed_user), "replayedAssistantText": agent_text(replay)[:80]}
        ok = "error" not in loaded and len(replay) > 0
        if not ok:
            report["stderrTail"] = second.stderr_tail
    except Exception as error:  # noqa: BLE001 — 探针需要把任何异常写进报告
        report["exception"] = str(error)
        if first:
            report["stderrTail"] = first.stderr_tail
    finally:
        for agent in (first, second):
            if agent:
                agent.stop()
        if not options.keep_cwd:
            shutil.rmtree(cwd, ignore_errors=True)
    report["restoreOK"] = ok
    print(json.dumps(report, ensure_ascii=False, indent=2))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
