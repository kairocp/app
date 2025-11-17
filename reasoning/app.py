import os, hmac, hashlib, json, asyncio, logging
from typing import List, Dict, Any, Optional
from fastapi import FastAPI, Request, Header, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
import httpx, asyncpg

INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN","changeme")
AOAI_ENDPOINT = os.getenv("AOAI_ENDPOINT","")
AOAI_KEY = os.getenv("AOAI_KEY","")
AOAI_DEPLOYMENT = os.getenv("AOAI_DEPLOYMENT","")
AOAI_EMBED = os.getenv("AOAI_EMBED", AOAI_DEPLOYMENT)
PG_CONN = os.getenv("PG_CONN","")

app = FastAPI()
pool: Optional[asyncpg.Pool] = None

def verify_sig(raw: bytes, sig: Optional[str]):
    if not sig: raise HTTPException(401, "missing signature")
    mac = hmac.new(INTERNAL_TOKEN.encode(), raw, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(mac, sig): raise HTTPException(401, "bad signature")

@app.on_event("startup")
async def startup():
    global pool
    if PG_CONN:
        try:
            pool = await asyncpg.create_pool(PG_CONN, timeout=10)
        except Exception:
            logging.exception("Failed to create Postgres pool; continuing without DB")
            pool = None

@app.get("/healthz")
async def healthz():
    return {"ok": True}

@app.get("/api/messages")
async def messages_probe():
    return {"ok": True}

@app.get("/api/calls")
async def calls_probe():
    return {"ok": True}

async def embed(text: str) -> List[float]:
    url = f"{AOAI_ENDPOINT}openai/deployments/{AOAI_EMBED}/embeddings?api-version=2024-02-15-preview"
    async with httpx.AsyncClient(timeout=30) as cx:
        r = await cx.post(url, headers={"api-key": AOAI_KEY}, json={"input": text})
        r.raise_for_status()
        return r.json()["data"][0]["embedding"]

async def retrieve(org: str, query: str, k: int = 6) -> List[Dict[str,Any]]:
    if not pool: return []
    try:
        e = await embed(query)
    except Exception:
        logging.exception("Embedding failed")
        return []
    vec = "[" + ",".join(str(x) for x in e) + "]"
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT doc_id, n, text, meta
            FROM chunks
            WHERE org = $1
            ORDER BY embedding <-> $2::vector
            LIMIT $3
        """, org, vec, k)
    return [dict(r) for r in rows]

async def llm(messages: List[Dict[str,str]]) -> str:
    url = f"{AOAI_ENDPOINT}openai/deployments/{AOAI_DEPLOYMENT}/chat/completions?api-version=2024-02-15-preview"
    payload = {"messages": messages, "temperature": 0.2, "stream": False}
    async with httpx.AsyncClient(timeout=90) as cx:
        r = await cx.post(url, headers={"api-key": AOAI_KEY}, json=payload)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]

SYSTEM = (
    "You are CISO Copilot. Keep answers concise and grounded. "
    "When channel=voice, return actions like say/play/transfer/end_call."
)

def normalize_events(events: List[Dict[str,Any]]) -> str:
    lines = []
    for ev in events:
        t = ev.get("type")
        if t in ("user_text","stt_final"):
            txt = (ev.get("text") or "").strip()
            if txt: lines.append(txt)
        elif t == "dtmf":
            digs = ev.get("digits","")
            if digs: lines.append(f"[DTMF:{digs}]")
    return "\n".join(lines)

def craft_actions(channel: str, answer: str) -> List[Dict[str,Any]]:
    if channel == "voice" and answer.strip():
        return [{"type":"say","text":answer}]
    return []

@app.post("/reason")
async def reason(req: Request, x_signature: Optional[str]=Header(default=None)):
    raw = await req.body()
    verify_sig(raw, x_signature)
    body = json.loads(raw)

    channel = body.get("channel","text")
    org = body.get("org","default")
    session_id = body.get("session_id","")
    events = body.get("events",[])
    user_msg = normalize_events(events) or body.get("text","")

    ctx_chunks = await retrieve(org, user_msg) if user_msg else []
    ctx_txt = "\n\n".join(f"[{i+1}] {c['text']}" for i,c in enumerate(ctx_chunks))
    messages = [
        {"role":"system","content": SYSTEM},
        {"role":"user","content": f"Question:\n{user_msg}\n\nContext:\n{ctx_txt}"}
    ]
    answer = await llm(messages)
    actions = craft_actions(channel, answer)
    citations = [{"title": (c.get("meta") or {}).get("title","Doc"),
                  "url": (c.get("meta") or {}).get("url","")} for c in ctx_chunks]

    return JSONResponse({
        "session_id": session_id,
        "messages":[{"role":"assistant","text":answer}],
        "actions": actions,
        "citations": citations
    })

@app.get("/reason/stream")
async def stream(id: str):
    async def gen():
        for chunk in ["Thinking ","through ","your ","request..."]:
            yield f"data: {json.dumps({'delta': chunk})}\n\n"
            await asyncio.sleep(0.05)
        yield "data: [DONE]\n\n"
    return StreamingResponse(gen(), media_type="text/event-stream")
