"""Portfolio chat backed by the Claude Code CLI (`claude -p`), so it runs on the user's
Claude subscription. Each conversation is a resumable Claude Code session; portfolio data and
long-term memory come from our MCP server (brokerd.mcp_server)."""
from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import sys
import uuid
from pathlib import Path
from typing import AsyncIterator

from .chat_tools import context_block
from .config import APP_DIR

log = logging.getLogger("brokerd.chat")

CHAT_DIR = APP_DIR / "chat"
HELPER_DIR = Path(__file__).resolve().parent.parent

SYSTEM = """You are the assistant inside "money", the user's personal portfolio app on their Mac.
It combines their Toss Securities (토스증권) and Interactive Brokers (IBKR) accounts.

- You have live, read-only access to their holdings, history, trades, watchlist and prices through the
  `money` tools. Use them whenever a question depends on numbers instead of guessing; numbers in an
  earlier turn may be stale.
- You keep long-term memory across conversations with the memory tools. When the user tells you something
  durable about themselves (goals, timeline, risk tolerance, strategy, preferences, life context, how they
  want you to answer), save it with memory_save without asking, and mention briefly that you saved it.
  Update or delete memories that change or turn out wrong. Don't save transient numbers the tools can fetch.
- Reply in the user's language (usually Korean, sometimes English or mixed). Be direct and concrete, use the
  user's real numbers, and show the arithmetic when it matters. Keep answers compact; use short lists or
  small tables when they help. Amounts: USD unless the user asks otherwise; note KRW where relevant.
- The app is read-only: you cannot place or cancel orders. If asked, say so.
- WebSearch/WebFetch are available for news, filings and market context; cite what you used.
"""


def _claude_path() -> str | None:
    for p in (shutil.which("claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
              str(Path.home() / ".claude/local/claude"), str(Path.home() / ".local/bin/claude")):
        if p and os.access(p, os.X_OK):
            return p
    return None


def _mcp_config() -> str:
    return json.dumps({"mcpServers": {"money": {
        "type": "stdio",
        "command": sys.executable,
        "args": ["-m", "brokerd.mcp_server"],
        "cwd": str(HELPER_DIR),
        "env": {"PYTHONPATH": str(HELPER_DIR)},
    }}})


def _title(text: str) -> str:
    t = " ".join(text.split())
    return t[:40] + ("…" if len(t) > 40 else "")


TOOL_LABELS = {
    "get_portfolio": "보유 종목 확인", "get_portfolio_history": "자산 추이 확인", "get_trades": "거래 내역 확인",
    "get_price_chart": "가격 차트 확인", "get_watchlist": "관심 종목 확인", "search_symbols": "종목 검색",
    "get_connection_status": "연결 상태 확인", "memory_list": "기억 확인", "memory_save": "기억 저장",
    "memory_update": "기억 수정", "memory_delete": "기억 삭제", "WebSearch": "웹 검색", "WebFetch": "웹 페이지 읽기",
}


MODELS = {"haiku", "sonnet", "opus"}  # Claude Code aliases → latest of each family


def tool_label(name: str) -> str:
    return TOOL_LABELS.get(name.removeprefix("mcp__money__"), name)


class Chat:
    def __init__(self, engine):
        self.engine = engine
        self.store = engine.store
        self._busy: set[str] = set()

    def available(self) -> dict:
        return {"claude": _claude_path() is not None}

    async def send(self, conv_id: str | None, text: str, goal: dict | None, model: str | None = None) -> AsyncIterator[dict]:
        claude = _claude_path()
        if not claude:
            yield {"type": "error", "message": "Claude Code CLI(claude)를 찾을 수 없어요 — 설치 후 로그인해주세요"}
            return
        conv = self.store.conversation(conv_id) if conv_id else None
        new = conv is None
        cid = conv["id"] if conv else (conv_id or str(uuid.uuid4()))
        if cid in self._busy:
            yield {"type": "error", "message": "이 대화는 아직 답변 중이에요"}
            return
        self._busy.add(cid)
        try:
            prompt = text
            if new:
                ctx = context_block(self.engine.portfolio(), self.store.memories(), goal)
                prompt = f"{ctx}\n\n{text}"
            session = conv["sessionId"] if conv else str(uuid.uuid4())
            self.store.conversation_upsert(cid, session, _title(text))
            self.store.message_add(cid, "user", text)
            yield {"type": "start", "conversationId": cid, "title": _title(text) if new else conv["title"]}
            async for ev in self._run(claude, session, new, prompt, cid, model if model in MODELS else "sonnet"):
                yield ev
        finally:
            self._busy.discard(cid)

    async def _run(self, claude, session, new, prompt, cid, model) -> AsyncIterator[dict]:
        CHAT_DIR.mkdir(parents=True, exist_ok=True)
        args = [
            claude, "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--restricted", "--tools", "WebSearch,WebFetch",
            "--strict-mcp-config", "--mcp-config", _mcp_config(),
            "--allowedTools", "mcp__money", "WebSearch", "WebFetch",
            "--permission-mode", "dontAsk", "--model", model,
            "--append-system-prompt", SYSTEM,
        ]
        args += ["--session-id", session] if new else ["--resume", session]
        env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
        env["PATH"] = env.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin"
        proc = await asyncio.create_subprocess_exec(
            *args, cwd=CHAT_DIR, env=env,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=16 * 1024 * 1024,
        )
        proc.stdin.write(prompt.encode())
        await proc.stdin.drain()
        proc.stdin.close()

        parts: list[str] = []  # text blocks of the reply
        tools: list[str] = []
        block_is_text: dict[int, bool] = {}
        result_err = None
        try:
            async for raw in proc.stdout:
                try:
                    e = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                t = e.get("type")
                if t == "stream_event":
                    ev = e.get("event") or {}
                    et = ev.get("type")
                    if et == "content_block_start":
                        cb = ev.get("content_block") or {}
                        block_is_text[ev.get("index", 0)] = cb.get("type") == "text"
                        if cb.get("type") == "text":
                            if parts and parts[-1].strip():
                                parts.append("\n\n")
                                yield {"type": "text", "delta": "\n\n"}
                        elif cb.get("type") in ("tool_use", "server_tool_use"):
                            name = cb.get("name", "")
                            tools.append(name)
                            yield {"type": "tool", "name": name, "label": tool_label(name)}
                    elif et == "content_block_delta":
                        d = ev.get("delta") or {}
                        if d.get("type") == "text_delta" and d.get("text"):
                            parts.append(d["text"])
                            yield {"type": "text", "delta": d["text"]}
                elif t == "result":
                    if e.get("is_error"):
                        result_err = e.get("result") or e.get("subtype") or "오류"
        except asyncio.CancelledError:
            proc.kill()
            raise
        finally:
            if proc.returncode is None:
                try:
                    await asyncio.wait_for(proc.wait(), timeout=5)
                except asyncio.TimeoutError:
                    proc.kill()
            reply = "".join(parts).strip()
            if reply:
                self.store.message_add(cid, "assistant", reply, [tool_label(n) for n in tools])
                self.store.conversation_upsert(cid, session, "")
        err = (await proc.stderr.read()).decode(errors="replace").strip()
        if result_err or (proc.returncode and not reply):
            msg = result_err or (err.splitlines()[-1] if err else f"claude 종료 코드 {proc.returncode}")
            log.warning("chat failed: %s | %s", msg, err[-500:])
            yield {"type": "error", "message": str(msg)[:300]}
            return
        yield {"type": "done"}
