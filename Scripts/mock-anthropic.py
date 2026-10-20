#!/usr/bin/env python3
# @author ixxxxoooo
# 本地假 Anthropic 兼容网关(开发/验证用,不连外网):
#   python3 Scripts/mock-anthropic.py [--port 3456] [--mode ok|404|500|slow|drop]
# 支持 GET /v1/models 与 POST /v1/messages(含 SSE 流式)。用于验证 ANTHROPIC_BASE_URL 指向自定义网关时,
# OhMyAgent → ACP 适配器 → claude → 网关 整条链路是否通畅。
import argparse, json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["mxou/gpt-5.6-sol", "mxou/gpt-5.6-terra", "mxou/gpt-5.6-luna", "mimo-v2.6-flash-free"]
ARGS = None

def log_request(path, raw, req):
    """--log 指定时,把每个上游请求的体量摘要追加为一行 JSON(用于统计「每次发消息到底发了多少上下文」)。"""
    if not ARGS or not ARGS.log:
        return
    def size(value):
        return len(json.dumps(value, ensure_ascii=False).encode()) if value is not None else 0
    messages = req.get("messages") or []
    last_user = ""
    for message in reversed(messages):
        if message.get("role") == "user":
            content = message.get("content")
            if isinstance(content, list):
                content = " ".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text")
            last_user = (content or "")[:60].replace("\n", " ")
            break
    marks = raw.count(b'"cache_control"')
    row = {
        "t": round(time.time(), 3), "path": path, "model": req.get("model"), "stream": bool(req.get("stream")),
        "bodyBytes": len(raw), "messages": len(messages), "messagesBytes": size(messages),
        "systemBytes": size(req.get("system")), "tools": len(req.get("tools") or []), "toolsBytes": size(req.get("tools")),
        "cacheControlMarks": marks, "maxTokens": req.get("max_tokens"), "lastUser": last_user,
    }
    with LOG_LOCK, open(ARGS.log, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")


LOG_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("[mock] " + (fmt % a) + "\n")

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            self._json(200, {"data": [{"id": m, "type": "model", "display_name": m, "created_at": "2026-01-01T00:00:00Z"} for m in MODELS], "has_more": False, "first_id": MODELS[0], "last_id": MODELS[-1]})
        else:
            self._json(200, {"ok": True})

    def do_HEAD(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw or b"{}")
        except Exception:
            req = {}
        if not self.path.startswith("/v1/messages"):
            return self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "unknown path"}})
        log_request(self.path, raw, req)
        if "count_tokens" in self.path:
            return self._json(200, {"input_tokens": 10})
        mode = ARGS.mode
        if mode == "404":
            return self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "model: %s" % req.get("model")}})
        if mode == "500":
            return self._json(500, {"type": "error", "error": {"type": "api_error", "message": "mock internal error"}})
        if mode == "drop":
            self.connection.close(); return
        if mode == "slow":
            time.sleep(600)
        model = req.get("model", "mock")
        text = "你好,这是本地假网关的回复(模型 %s)。" % model
        if not req.get("stream"):
            return self._json(200, {"id": "msg_mock", "type": "message", "role": "assistant", "model": model, "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 12}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        def emit(event, data):
            chunk = ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()
            self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n"); self.wfile.flush()
        emit("message_start", {"type": "message_start", "message": {"id": "msg_mock", "type": "message", "role": "assistant", "model": model, "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        emit("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        for piece in [text[i:i + 6] for i in range(0, len(text), 6)]:
            emit("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": piece}}); time.sleep(0.03)
        emit("content_block_stop", {"type": "content_block_stop", "index": 0})
        emit("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 12}})
        emit("message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=3456)
    p.add_argument("--mode", default="ok", choices=["ok", "404", "500", "slow", "drop"])
    p.add_argument("--log", default="", help="把每个 /v1/messages 请求的体量摘要追加写入该 JSONL 文件")
    ARGS = p.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    sys.stderr.write("[mock] 监听 127.0.0.1:%d 模式=%s\n" % (ARGS.port, ARGS.mode))
    server.serve_forever()
