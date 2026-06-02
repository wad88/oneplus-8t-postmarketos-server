#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# hermes-agent.py — 一加8T pmOS 双向 Telegram agent
# 手机 TG 发指令 → 设备执行(运维/shell/AI) → 回复
# 纯标准库(urllib), 无需 pip。配置 /etc/hermes-status.conf 复用 TG_TOKEN/TG_CHAT_ID
# AI 可选: 配 AI_BASE/AI_KEY/AI_MODEL 后 /ai 或非命令文本走大模型
import json, os, subprocess, time, urllib.request, urllib.parse, ssl, html

CONF = os.environ.get("HERMES_CONF", "/etc/hermes-status.conf")
cfg = {}
if os.path.exists(CONF):
    for line in open(CONF):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")

TOKEN = cfg.get("TG_TOKEN", "")
OWNER = cfg.get("TG_CHAT_ID", "")          # 只响应这个 chat(安全)
AI_BASE = cfg.get("AI_BASE", "")            # 如 https://your-newapi.example.com
AI_KEY = cfg.get("AI_KEY", "")
AI_MODEL = cfg.get("AI_MODEL", "gpt-4o-mini")
API = f"https://api.telegram.org/bot{TOKEN}"
SSLCTX = ssl.create_default_context()
SSLCTX.check_hostname = False
SSLCTX.verify_mode = ssl.CERT_NONE

def http(url, data=None, timeout=60):
    if data is not None and not isinstance(data, bytes):
        data = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=data)
    with urllib.request.urlopen(req, timeout=timeout, context=SSLCTX) as r:
        return json.loads(r.read().decode())

def send(text, chat=None):
    chat = chat or OWNER
    # TG 单条 4096 上限, 截断
    if len(text) > 3900:
        text = text[:3900] + "\n...(截断)"
    try:
        http(f"{API}/sendMessage", {"chat_id": chat, "text": text})
    except Exception as e:
        print("send err:", e)

def sh(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        return out.strip() or "(无输出)"
    except subprocess.TimeoutExpired:
        return "(超时)"
    except Exception as e:
        return f"(错误: {e})"

def ai(prompt):
    if not AI_BASE or not AI_KEY:
        return "AI 未配置(在 /etc/hermes-status.conf 加 AI_BASE/AI_KEY/AI_MODEL)"
    try:
        body = json.dumps({
            "model": AI_MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
        }).encode()
        req = urllib.request.Request(
            AI_BASE.rstrip("/") + "/v1/chat/completions",
            data=body,
            headers={"Authorization": f"Bearer {AI_KEY}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=90, context=SSLCTX) as r:
            d = json.loads(r.read().decode())
        return d["choices"][0]["message"]["content"]
    except Exception as e:
        return f"AI 调用失败: {e}"

HELP = """Hermes agent 指令:
/status 系统状态卡片
/df 磁盘
/mem 内存
/docker 容器列表
/logs <容器> 最近日志
/restart <容器> 重启容器
/sh <命令> 执行 shell
/ai <问题> 问大模型
/reboot 重启设备
/help 帮助
直接发文本 = /ai 问大模型"""

def handle(text, chat):
    text = text.strip()
    low = text.lower()
    if low in ("/start", "/help", "help"):
        return HELP
    if low == "/status":
        return sh("/usr/local/bin/hermes-status.sh --dry 2>/dev/null | sed 's/<[^>]*>//g'")
    if low == "/df":
        return sh("df -h | grep -vE 'tmpfs|shm'")
    if low == "/mem":
        return sh("free -m")
    if low == "/docker":
        return sh("docker ps -a --format '{{.Names}}: {{.Status}}'")
    if low.startswith("/logs"):
        c = text[5:].strip() or ""
        return sh(f"docker logs --tail 30 {c} 2>&1") if c else "用法: /logs <容器名>"
    if low.startswith("/restart"):
        c = text[8:].strip()
        return sh(f"docker restart {c} 2>&1") if c else "用法: /restart <容器名>"
    if low.startswith("/sh"):
        c = text[3:].strip()
        return sh(c) if c else "用法: /sh <命令>"
    if low.startswith("/ai"):
        q = text[3:].strip()
        return ai(q) if q else "用法: /ai <问题>"
    if low == "/reboot":
        send("设备重启中... ~60s后回来", chat)
        sh("(sleep 2; reboot) &")
        return None
    # 非命令 → AI
    return ai(text)

def main():
    if not TOKEN or not OWNER:
        print("缺 TG_TOKEN/TG_CHAT_ID"); return
    send("🤖 Hermes agent 上线。发 /help 看指令。")
    offset = 0
    while True:
        try:
            d = http(f"{API}/getUpdates?offset={offset}&timeout=50", timeout=60)
            if not d.get("ok"):
                time.sleep(5); continue
            for u in d["result"]:
                offset = u["update_id"] + 1
                m = u.get("message") or {}
                chat = str(m.get("chat", {}).get("id", ""))
                text = m.get("text", "")
                if not text:
                    continue
                if OWNER and chat != OWNER:        # 只响应主人
                    send("未授权", chat); continue
                try:
                    reply = handle(text, chat)
                    if reply:
                        send(reply, chat)
                except Exception as e:
                    send(f"执行出错: {e}", chat)
        except Exception as e:
            print("loop err:", e); time.sleep(5)

if __name__ == "__main__":
    main()
