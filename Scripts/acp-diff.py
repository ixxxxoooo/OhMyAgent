#!/usr/bin/env python3
# @author ixxxxoooo
# ACP 适配器差分对照:对同一场景分别驱动 Node 版 claude-agent-acp 与 Swift 原生适配器(ClaudeACPHost),
# 把两边的 ACP 输出归一化(去掉 UUID、临时目录、文字内容、耗时)后逐项比对。
# 会对真实 claude 发起少量极短请求(在临时目录里,不碰你的项目)。
#
# 用法:
#   Scripts/acp-diff.py [--steps init,new,prompt,tool,config,list,load,fork] [--keep] [--show]
# 退出码 0 表示所有被选步骤两边一致。

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE_ENTRY = os.path.join(ROOT, "Vendor/acp/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")
TOOL_ID = re.compile(r"toolu_[0-9A-Za-z]+")
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


class Agent:
    """以 stdio 通信的 ACP Agent 子进程(权限一律放行一次,征询一律接受)。"""

    def __init__(self, argv, cwd, env):
        self.proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        self.next_id = 1
        self.pending = {}
        self.updates = []
        self.requests = []
        self.stderr_tail = []
        self.lock = threading.Lock()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.stderr_tail = (self.stderr_tail + [line.rstrip()])[-30:]

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
                self._answer(message)
            elif "method" in message:
                with self.lock:
                    self.updates.append(message)
            elif "id" in message:
                event = self.pending.get(message["id"])
                if event:
                    event["response"] = message
                    event["done"].set()

    def _answer(self, message):
        method = message["method"]
        params = message.get("params", {})
        with self.lock:
            self.requests.append({"method": method, "params": params})
        if method == "session/request_permission":
            options = params.get("options", [])
            allow = next((o for o in options if o.get("kind") == "allow_once"), options[0] if options else None)
            outcome = {"outcome": "selected", "optionId": allow["optionId"]} if allow else {"outcome": "cancelled"}
            self._send({"jsonrpc": "2.0", "id": message["id"], "result": {"outcome": outcome}})
        elif method == "elicitation/create":
            props = (params.get("requestedSchema") or {}).get("properties", {})
            content = {}
            for key, spec in props.items():
                if spec.get("type") == "array":
                    options = (spec.get("items") or {}).get("enum") or [o.get("const") for o in (spec.get("items") or {}).get("anyOf", [])]
                    content[key] = options[:1]
                else:
                    options = spec.get("enum") or [o.get("const") for o in spec.get("oneOf", [])]
                    content[key] = options[0] if options else "x"
            self._send({"jsonrpc": "2.0", "id": message["id"], "result": {"action": "accept", "content": content}})
        else:
            self._send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "unsupported"}})

    def call(self, method, params, timeout=120):
        request_id = self.next_id
        self.next_id += 1
        event = {"done": threading.Event(), "response": None}
        self.pending[request_id] = event
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        if not event["done"].wait(timeout):
            return {"error": {"message": f"超时 {timeout}s"}}
        return event["response"]

    def take(self):
        with self.lock:
            updates, self.updates = self.updates, []
            requests, self.requests = self.requests, []
        return updates, requests

    def stop(self):
        try:
            self.proc.kill()
        except OSError:
            pass


# ---------- 归一化 ----------

def shape(value, cwd, depth=0):
    """保留结构与枚举型字段,抹掉自由文本、UUID、路径与数值。"""
    if isinstance(value, dict):
        return {k: shape(v, cwd, depth + 1) for k, v in sorted(value.items()) if k not in VOLATILE_KEYS}
    if isinstance(value, list):
        return [shape(v, cwd, depth + 1) for v in value]
    if isinstance(value, str):
        text = TOOL_ID.sub("<toolu>", UUID.sub("<uuid>", value.replace(cwd, "<cwd>")).replace(os.path.realpath(cwd), "<cwd>"))
        return text
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)):
        return "<num>"
    return value


# 值本身随时间/模型变化的字段:只比较「有没有」
VOLATILE_KEYS = {"title", "updatedAt", "createdAt", "timestamp", "durationMs", "duration_ms", "cost", "used", "size", "amount", "elapsedMs", "_meta_timing"}
FREE_TEXT_FIELDS = {"text", "thought"}


def update_shape(message, cwd):
    """把一条 session/update 压缩成「种类 + 关键结构」。"""
    if message.get("method") != "session/update":
        return {"kind": "通知:" + str(message.get("method")), "params": shape(message.get("params"), cwd)}
    body = message.get("params", {}).get("update", {})
    kind = body.get("sessionUpdate")
    item = {"kind": kind}
    if kind in ("agent_message_chunk", "agent_thought_chunk", "user_message_chunk"):
        content = body.get("content", {})
        item["content"] = content.get("type")
    elif kind in ("tool_call", "tool_call_update"):
        for key in ("kind", "status", "title"):
            if key in body:
                item[key] = shape(body[key], cwd)
        item["has"] = sorted(k for k in body if k not in ("sessionUpdate",))
        item["content"] = [c.get("type") for c in body.get("content", [])] if isinstance(body.get("content"), list) else None
        meta = body.get("_meta", {}).get("claudeCode", {}) if isinstance(body.get("_meta"), dict) else {}
        item["toolName"] = meta.get("toolName")
        item["rawInputKeys"] = sorted(body["rawInput"].keys()) if isinstance(body.get("rawInput"), dict) else None
    elif kind == "available_commands_update":
        item["names"] = sorted(c["name"] for c in body.get("availableCommands", []))
    elif kind == "usage_update":
        item["keys"] = sorted(body.keys())
    elif kind in ("current_mode_update", "config_option_update", "session_info_update", "plan"):
        item["body"] = shape({k: v for k, v in body.items() if k != "sessionUpdate"}, cwd)
    else:
        item["body"] = shape({k: v for k, v in body.items() if k != "sessionUpdate"}, cwd)
    return item


def collapse(items):
    """合并相邻的同类文本块与重复的 usage/commands,避免流式分块差异造成噪声。"""
    out = []
    for item in items:
        if out and out[-1] == item and item["kind"] in ("agent_message_chunk", "agent_thought_chunk", "usage_update", "available_commands_update"):
            continue
        out.append(item)
    return out


def settle(items):
    """通知到达顺序取决于异步探测的先后,不属于协议差异:按种类去重(命令列表取最后一条)并排序。"""
    last = {}
    for item in items:
        key = item["kind"] if item["kind"] in ("available_commands_update", "usage_update") else json.dumps(item, sort_keys=True, ensure_ascii=False)
        last[key] = item
    return sorted(last.values(), key=lambda i: json.dumps(i, sort_keys=True, ensure_ascii=False))


def kinds_present(items):
    """顺序无关的种类集合 + 工具调用的状态序列。"""
    # 标题生成(session_info_update)、身份推送与流式细化的次数取决于时序/模型,不属于协议差异
    noise = ("session_info_update", "通知:_auth/status_update")
    result = {"kinds": sorted({i["kind"] for i in items if i["kind"] not in noise})}
    tools = sorted({(i.get("toolName"), i.get("kind"), i.get("status")) for i in items if i["kind"] in ("tool_call", "tool_call_update")}, key=str)
    result["tools"] = tools
    return result


def permission_shape(requests, cwd):
    out = []
    for r in requests:
        if r["method"] != "session/request_permission":
            out.append({"method": r["method"], "params": shape(r["params"], cwd)})
            continue
        params = r["params"]
        tool = params.get("toolCall", {})
        out.append({
            "method": r["method"],
            "options": [(o.get("optionId"), o.get("kind"), o.get("name")) for o in params.get("options", [])],
            "toolCallKeys": sorted(tool.keys()),
            "toolKind": tool.get("kind"),
            "title": shape(tool.get("title"), cwd),
            "toolName": (tool.get("_meta") or {}).get("claudeCode", {}).get("toolName"),
            "rawInputKeys": sorted(tool["rawInput"].keys()) if isinstance(tool.get("rawInput"), dict) else None,
        })
    return out


# ---------- 场景 ----------

def run_scenario(name, argv, env, steps, keep):
    cwd = os.path.realpath(tempfile.mkdtemp(prefix="oma-diff-"))
    with open(os.path.join(cwd, "note.txt"), "w") as handle:
        handle.write("hello diff\n")
    trace = {}
    agents = []

    def new_agent():
        agent = Agent(argv, cwd, env)
        agents.append(agent)
        return agent

    init_params = {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False,
                                                                 "elicitation": {"form": {}}}}
    try:
        agent = new_agent()
        init = agent.call("initialize", init_params, timeout=30)
        result = init.get("result", {})
        if "init" in steps:
            trace["initialize"] = shape(result, cwd)
        created = agent.call("session/new", {"cwd": cwd, "mcpServers": []}, timeout=90)
        session = created.get("result", {})
        session_id = session.get("sessionId")
        if "new" in steps:
            trace["session/new"] = shape({k: v for k, v in session.items() if k != "sessionId"}, cwd) if session else created
        if not session_id:
            raise RuntimeError(f"session/new 失败: {created}")
        time.sleep(1.5)
        updates, _ = agent.take()
        if "new" in steps:
            trace["session/new 后通知"] = settle([update_shape(u, cwd) for u in updates])

        if "prompt" in steps:
            reply = agent.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": "只回复两个字母:OK"}]}, timeout=180)
            updates, requests = agent.take()
            items = collapse([update_shape(u, cwd) for u in updates])
            trace["prompt(纯文字)"] = {"result": shape(reply.get("result", reply), cwd), "updates": kinds_present(items), "requests": permission_shape(requests, cwd)}

        if "tool" in steps:
            reply = agent.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text",
                               "text": "用 Read 工具读取 note.txt,然后只回复文件内容的第一个单词。"}]}, timeout=180)
            updates, requests = agent.take()
            items = collapse([update_shape(u, cwd) for u in updates])
            trace["prompt(Read 工具)"] = {"result": shape(reply.get("result", reply), cwd), "updates": kinds_present(items),
                                          "first_tool_call": next((i for i in items if i["kind"] == "tool_call"), None),
                                          "requests": permission_shape(requests, cwd)}
            reply = agent.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text",
                               "text": "用 Bash 工具运行 `echo hello`,然后只回复它的输出。"}]}, timeout=180)
            updates, requests = agent.take()
            items = collapse([update_shape(u, cwd) for u in updates])
            trace["prompt(Bash 工具)"] = {"result": shape(reply.get("result", reply), cwd), "updates": kinds_present(items),
                                          "first_tool_call": next((i for i in items if i["kind"] == "tool_call"), None),
                                          "requests": permission_shape(requests, cwd)}

        def turn(text, label, extra=None, timeout=240):
            reply = agent.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": text}]}, timeout=timeout)
            updates, requests = agent.take()
            items = collapse([update_shape(u, cwd) for u in updates])
            entry = {"result": shape(reply.get("result", reply), cwd), "updates": kinds_present(items),
                     "first_tool_call": next((i for i in items if i["kind"] == "tool_call"), None),
                     "requests": permission_shape(requests, cwd)}
            if extra:
                entry.update(extra())
            trace[label] = entry

        if "perm" in steps:
            turn("用 Write 工具创建文件 out.txt,内容为 hi,然后只回复 done。", "权限(Write)",
                 lambda: {"文件已写入": os.path.exists(os.path.join(cwd, "out.txt"))})

        if "ask" in steps:
            turn("请使用 AskUserQuestion 工具问我一个单选题:最喜欢的颜色(红/蓝),然后复述我的选择。", "AskUserQuestion")

        if "plan" in steps:
            agent.call("session/set_mode", {"sessionId": session_id, "modeId": "plan"})
            agent.take()
            turn("计划:在 note.txt 末尾追加一行。先写出极短的计划并调用 ExitPlanMode。", "计划模式(ExitPlanMode)")
            agent.call("session/set_mode", {"sessionId": session_id, "modeId": "default"})
            agent.take()

        if "agent" in steps:
            turn("用 Agent 工具启动一个子代理(subagent_type 任意),让它只回复 hi,然后你回复 ok。", "子代理(Agent 工具)")

        if "slash" in steps:
            turn("/context", "斜杠命令 /context", timeout=90)
            turn("/cost", "斜杠命令 /cost", timeout=90)

        if "cancel" in steps:
            import threading as _t
            holder = {}
            def go():
                holder["r"] = agent.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": "从 1 数到 3000,每个数字单独一行,不要省略。"}]}, timeout=120)
            th = _t.Thread(target=go)
            th.start()
            time.sleep(4)
            agent._send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session_id}})
            th.join(60)
            updates, requests = agent.take()
            trace["取消"] = {"result": shape(holder.get("r", {}).get("result", holder.get("r")), cwd)}

        if "config" in steps:
            answers = {}
            answers["set_mode(acceptEdits)"] = shape(agent.call("session/set_mode", {"sessionId": session_id, "modeId": "acceptEdits"}).get("result"), cwd)
            answers["set_config_option(mode=default)"] = shape(agent.call("session/set_config_option", {"sessionId": session_id, "configId": "mode", "value": "default"}), cwd)
            answers["set_config_option(effort=low)"] = shape(agent.call("session/set_config_option", {"sessionId": session_id, "configId": "effort", "value": "low"}), cwd)
            answers["set_config_option(bogus)"] = shape(agent.call("session/set_config_option", {"sessionId": session_id, "configId": "nope", "value": "x"}), cwd)
            answers["set_mode(bogus)"] = shape(agent.call("session/set_mode", {"sessionId": session_id, "modeId": "nope"}), cwd)
            answers["未知方法"] = shape(agent.call("session/nope", {}), cwd)
            updates, _ = agent.take()
            answers["通知"] = collapse([update_shape(u, cwd) for u in updates])
            trace["配置"] = answers

        if "list" in steps:
            listed = agent.call("session/list", {"cwd": cwd})
            body = listed.get("result", listed)
            trace["session/list"] = shape(body, cwd)

        history_id = session_id
        if "fork" in steps:
            forked = agent.call("session/fork", {"sessionId": session_id, "cwd": cwd, "mcpServers": []}, timeout=60)
            result = forked.get("result", forked)
            new_id = result.get("sessionId") if isinstance(result, dict) else None
            trace["session/fork"] = shape({k: v for k, v in result.items() if k != "sessionId"} if isinstance(result, dict) else result, cwd)
            trace["session/fork.新ID不同"] = bool(new_id and new_id != session_id)
            if new_id:
                time.sleep(1)
                agent.take()

        agent.stop()
        time.sleep(0.5)

        if "load" in steps:
            second = new_agent()
            second.call("initialize", init_params, timeout=30)
            loaded = second.call("session/load", {"sessionId": history_id, "cwd": cwd, "mcpServers": []}, timeout=90)
            time.sleep(1.5)
            updates, _ = second.take()
            items = [update_shape(u, cwd) for u in updates]
            trace["session/load"] = {"result": shape(loaded.get("result", loaded), cwd), "replay": kinds_present(collapse(items))}
            missing = second.call("session/load", {"sessionId": "00000000-0000-4000-8000-000000000000", "cwd": cwd, "mcpServers": []})
            trace["session/load(不存在)"] = shape(missing.get("error", missing), cwd)
            resumed = second.call("session/resume", {"sessionId": history_id, "cwd": cwd, "mcpServers": []}, timeout=90)
            trace["session/resume"] = shape(resumed.get("result", resumed), cwd)
            closed = second.call("session/close", {"sessionId": history_id})
            trace["session/close"] = shape(closed.get("result", closed), cwd)
    except Exception as error:  # noqa: BLE001 — 探针需要把任何异常写进报告
        trace["异常"] = str(error)
        for agent in agents:
            trace.setdefault("stderr", agent.stderr_tail[-8:])
    finally:
        for agent in agents:
            agent.stop()
        if not keep:
            shutil.rmtree(cwd, ignore_errors=True)
    return trace


def scrub_usage(value):
    """按模型拆分的用量条目数取决于是否触发了标题生成,只保留字段结构。"""
    if isinstance(value, dict):
        if "model_usage" in value and isinstance(value["model_usage"], list):
            value["model_usage"] = [{k: v for k, v in e.items() if k != "model"} for e in value["model_usage"][:1]]
        for v in value.values():
            scrub_usage(v)
    elif isinstance(value, list):
        for v in value:
            scrub_usage(v)


def expected_differences(trace):
    """抹掉有意不同的字段:适配器名称/版本(Swift 版自成版本线),以及暂未提供的 providers API。"""
    scrub_usage(trace)
    init = trace.get("initialize")
    if isinstance(init, dict):
        init.get("agentInfo", {}).pop("name", None)
        init.get("agentInfo", {}).pop("version", None)
        init.get("agentCapabilities", {}).pop("providers", None)


def main():
    parser = argparse.ArgumentParser(description="Node 适配器 vs Swift 原生适配器差分对照")
    parser.add_argument("--steps", default="init,new,prompt,tool,config,list,fork,load")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--show", action="store_true", help="同时打印两边完整归一化输出")
    parser.add_argument("--swift-bin", default=None)
    options = parser.parse_args()
    steps = set(options.steps.split(","))

    claude = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
    env = dict(os.environ)
    env["CLAUDE_CODE_EXECUTABLE"] = claude
    node = shutil.which("node")
    if not node or not os.path.exists(NODE_ENTRY):
        sys.exit("缺少 node 或 Vendor/acp(差分对照仅在迁移期使用)")
    bin_path = options.swift_bin
    if not bin_path:
        found = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True).stdout.strip().splitlines()
        bin_path = os.path.join(found[-1], "ClaudeACPHost")
    if not os.path.exists(bin_path):
        sys.exit(f"找不到 {bin_path},请先 swift build --product ClaudeACPHost")

    traces = {}
    for label, argv in (("node", [node, NODE_ENTRY]), ("swift", [bin_path, "--claude", claude])):
        print(f"== 运行 {label} ==", file=sys.stderr)
        traces[label] = run_scenario(label, argv, env, steps, options.keep)
    for label in traces:
        expected_differences(traces[label])
    texts = {k: json.dumps(v, ensure_ascii=False, indent=1, sort_keys=True).splitlines() for k, v in traces.items()}
    if options.show:
        for label, lines in texts.items():
            print(f"----- {label} -----")
            print("\n".join(lines))
    diff = list(difflib.unified_diff(texts["node"], texts["swift"], "node", "swift", lineterm="", n=3))
    if not diff:
        print("✅ 两边归一化输出完全一致")
        return
    print("\n".join(diff))
    print(f"\n❌ 存在差异({len([d for d in diff if d.startswith(('+', '-')) and not d.startswith(('+++', '---'))])} 行)")
    sys.exit(1)


if __name__ == "__main__":
    main()
