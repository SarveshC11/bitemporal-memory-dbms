from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Any

import psycopg
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from phase2.extraction import ExtractionPipeline
from phase2.store import postgres_entity_resolver, remember_facts
from phase2.query import QueryRoutingError, execute_query, route_query

from .llm import OpenAICompatibleClient, demo_extract

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "host=localhost port=5433 dbname=memory user=memory password=memory",
)
PREDICATES = {"works_at", "lives_in", "has_role", "favourite_food", "likes", "speaks", "skilled_in"}

app = FastAPI(title="Bitemporal Memory Store")


class TurnRequest(BaseModel):
    subject: str = Field(min_length=1, max_length=200)
    conversation_id: str = Field(default="web", min_length=1, max_length=200)
    turn_no: int = Field(default=1, ge=1)
    text: str = Field(min_length=1, max_length=20_000)
    occurred_at: datetime | None = None


class QueryRequest(BaseModel):
    subject: str = Field(min_length=1, max_length=200)
    predicate: str = Field(min_length=1, max_length=100)


class NaturalQueryRequest(BaseModel):
    question: str = Field(min_length=1, max_length=5_000)
    subject: str | None = Field(default=None, max_length=200)
    predicate: str | None = Field(default=None, max_length=100)


class CorrectionRequest(BaseModel):
    fact_id: int = Field(ge=1)
    action: str = Field(pattern="^(replace|reject|restore)$")
    new_object: str | None = Field(default=None, max_length=500)
    actor: str = Field(default="dashboard-user", min_length=1, max_length=200)
    reason: str = Field(min_length=1, max_length=2_000)


def _connection() -> psycopg.Connection[Any]:
    return psycopg.connect(DATABASE_URL)


def _json_rows(cursor: Any) -> list[dict[str, Any]]:
    columns = [column.name for column in cursor.description]
    return [
        {
            column: _json_value(value)
            for column, value in zip(columns, row)
        }
        for row in cursor.fetchall()
    ]


IST = timezone(timedelta(hours=5, minutes=30))


def _json_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.astimezone(IST).strftime("%d %b %Y, %I:%M:%S %p IST")
    if isinstance(value, (list, dict)):
        return value
    if value is not None and not isinstance(value, (str, int, float, bool)):
        return str(value).replace("+05:30", " IST").replace("+00:00", " UTC")
    return value


def _pipeline(connection: psycopg.Connection[Any], subject: str, occurred_at: datetime) -> ExtractionPipeline:
    client = OpenAICompatibleClient()
    if client.enabled:
        extractor = lambda text: client.extract(text, sorted(PREDICATES), subject)
        ambiguity = client.resolve_ambiguity
    else:
        extractor = lambda text: demo_extract(text, subject, occurred_at)
        ambiguity = None
    return ExtractionPipeline(
        PREDICATES,
        extractor,
        entity_resolver=postgres_entity_resolver(connection),
        ambiguity_resolver=ambiguity,
    )


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return HTML


@app.post("/api/turn")
def add_turn(payload: TurnRequest) -> dict[str, Any]:
    occurred_at = payload.occurred_at or datetime.now(timezone.utc)
    try:
        with _connection() as connection:
            facts = _pipeline(connection, payload.subject, occurred_at).extract(payload.text, occurred_at)
            remember_facts(
                connection, facts, payload.conversation_id, payload.turn_no, payload.text, occurred_at,
                commit=False,
            )
            connection.commit()
            return {
                "mode": "llm" if OpenAICompatibleClient().enabled else "demo",
                "facts": [fact.__dict__ for fact in facts],
                "stored": len(facts),
            }
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/state")
def state() -> dict[str, Any]:
    try:
        with _connection() as connection, connection.cursor() as cursor:
            cursor.execute("SELECT * FROM current_facts ORDER BY subject, predicate, fact_id")
            current = _json_rows(cursor)
            cursor.execute(
                """
                SELECT f.fact_id, s.canonical_name AS subject, p.name AS predicate,
                       COALESCE(o.canonical_name, f.object_text) AS object,
                       f.valid_period, f.sys_period, upper_inf(f.sys_period) AS active,
                       f.confidence, f.source_id
                FROM facts f
                JOIN entities s ON s.entity_id = f.subject_id
                JOIN predicates p ON p.predicate_id = f.predicate_id
                LEFT JOIN entities o ON o.entity_id = f.object_entity_id
                ORDER BY f.fact_id
                """
            )
            facts = _json_rows(cursor)
            cursor.execute(
                """
                SELECT correction_id, fact_id, action, old_object, new_object,
                       actor, reason, corrected_at
                FROM fact_corrections
                ORDER BY correction_id DESC
                LIMIT 100
                """
            )
            corrections = _json_rows(cursor)
            cursor.execute("SELECT * FROM sources ORDER BY source_id DESC LIMIT 100")
            sources = _json_rows(cursor)
            return {"current": current, "facts": facts, "corrections": corrections, "sources": sources}
    except Exception as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/api/query")
def query(payload: QueryRequest) -> dict[str, Any]:
    with _connection() as connection, connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT * FROM current_facts
            WHERE lower(subject) = lower(%s) AND predicate = lower(%s)
            ORDER BY fact_id
            """,
            (payload.subject, payload.predicate),
        )
        return {"rows": _json_rows(cursor)}


@app.post("/api/natural-query")
def natural_query(payload: NaturalQueryRequest) -> dict[str, Any]:
    try:
        route = route_query(payload.question)
        subject = payload.subject or route.subject or ""
        predicate = payload.predicate or route.predicate or ""
        if route.kind in {"current", "as_of"} and (not subject or not predicate):
            raise QueryRoutingError("the question must identify a subject and predicate")
        with _connection() as connection:
            rows = execute_query(connection, subject, predicate, route)
        return {"route": route.__dict__, "rows": rows}
    except (QueryRoutingError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/conversations")
def conversations() -> dict[str, Any]:
    with _connection() as connection, connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT conversation_id,
                   count(*) AS turn_count,
                   min(turn_no) AS first_turn,
                   max(turn_no) AS last_turn,
                   min(occurred_at) AS started_at,
                   max(occurred_at) AS last_activity
            FROM sources
            GROUP BY conversation_id
            ORDER BY max(occurred_at) DESC
            """
        )
        return {"conversations": _json_rows(cursor)}


@app.get("/api/conversations/{conversation_id}")
def conversation_detail(conversation_id: str) -> dict[str, Any]:
    with _connection() as connection, connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT s.source_id, s.conversation_id, s.turn_no, s.speaker, s.content,
                   s.occurred_at,
                   COALESCE(jsonb_agg(jsonb_build_object(
                       'fact_id', f.fact_id,
                       'subject', se.canonical_name,
                       'predicate', p.name,
                       'object', COALESCE(oe.canonical_name, f.object_text),
                       'valid_period', f.valid_period::text,
                       'sys_period', f.sys_period::text
                   ) ORDER BY f.fact_id) FILTER (WHERE f.fact_id IS NOT NULL), '[]'::jsonb) AS facts
            FROM sources s
            LEFT JOIN facts f ON f.source_id = s.source_id
            LEFT JOIN entities se ON se.entity_id = f.subject_id
            LEFT JOIN predicates p ON p.predicate_id = f.predicate_id
            LEFT JOIN entities oe ON oe.entity_id = f.object_entity_id
            WHERE s.conversation_id = %s
            GROUP BY s.source_id
            ORDER BY s.turn_no
            """,
            (conversation_id,),
        )
        return {"turns": _json_rows(cursor)}


@app.post("/api/conversations/{conversation_id}/replay")
def replay_conversation(conversation_id: str) -> dict[str, Any]:
    with _connection() as connection, connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT source_id, turn_no, content, occurred_at, speaker
            FROM sources
            WHERE conversation_id = %s
            ORDER BY turn_no
            """,
            (conversation_id,),
        )
        turns = _json_rows(cursor)
    replayed: list[dict[str, Any]] = []
    with _connection() as connection:
        for turn in turns:
            subject_cursor = connection.cursor()
            subject_cursor.execute(
                "SELECT COALESCE(MIN(s.canonical_name), 'Unknown') "
                "FROM facts f JOIN entities s ON s.entity_id = f.subject_id "
                "WHERE f.source_id = %s",
                (turn["source_id"],),
            )
            subject = subject_cursor.fetchone()[0]
            subject_cursor.close()
            occurred = turn["occurred_at"]
            if isinstance(occurred, str):
                try:
                    occurred = datetime.fromisoformat(occurred)
                except ValueError:
                    occurred = datetime.strptime(
                        occurred,
                        "%d %b %Y, %I:%M:%S %p IST",
                    ).replace(tzinfo=IST)
            facts = _pipeline(connection, subject, occurred).extract(turn["content"], occurred)
            replayed.append({
                "turn_no": turn["turn_no"],
                "content": turn["content"],
                "facts": [fact.__dict__ for fact in facts],
            })
    return {"conversation_id": conversation_id, "turns": replayed}


@app.get("/api/timeline")
def timeline(
    subject: str,
    predicate: str,
    valid_at: str | None = None,
    believed_at: str | None = None,
) -> dict[str, Any]:
    with _connection() as connection, connection.cursor() as cursor:
        if valid_at:
            valid_time = datetime.fromisoformat(valid_at)
            believed_time = datetime.fromisoformat(believed_at) if believed_at else valid_time
            cursor.execute(
                """
                SELECT fact_id, subject, predicate, object, valid_period,
                       sys_period, confidence, source_id
                FROM facts_as_of(%s, %s)
                WHERE lower(subject) = lower(%s) AND predicate = lower(%s)
                """,
                (valid_time, believed_time, subject, predicate),
            )
        else:
            cursor.execute(
                "SELECT * FROM fact_history(%s, %s)",
                (subject, predicate),
            )
        return {"rows": _json_rows(cursor)}


@app.post("/api/corrections")
def correct_fact(payload: CorrectionRequest) -> dict[str, Any]:
    if payload.action == "replace" and not payload.new_object:
        raise HTTPException(status_code=400, detail="new_object is required to replace a fact")
    try:
        with _connection() as connection, connection.cursor() as cursor:
            cursor.execute(
                "SELECT upper_inf(sys_period) FROM facts WHERE fact_id = %s",
                (payload.fact_id,),
            )
            fact_status = cursor.fetchone()
            if fact_status is None:
                raise HTTPException(status_code=404, detail=f"fact {payload.fact_id} does not exist")
            active = fact_status[0]
            if payload.action in {"replace", "reject"} and not active:
                raise HTTPException(
                    status_code=409,
                    detail=f"fact {payload.fact_id} is already closed; use Restore on a historical row",
                )
            if payload.action == "restore" and active:
                raise HTTPException(
                    status_code=409,
                    detail=f"fact {payload.fact_id} is already active; Restore is only for closed historical facts",
                )
            if payload.action == "reject":
                cursor.execute(
                    "SELECT reject_fact(%s, %s, %s)",
                    (payload.fact_id, payload.actor, payload.reason),
                )
            elif payload.action == "restore":
                cursor.execute(
                    "SELECT restore_fact(%s, %s, %s)",
                    (payload.fact_id, payload.actor, payload.reason),
                )
            else:
                cursor.execute(
                    "SELECT replace_fact(%s, %s, %s, %s)",
                    (payload.fact_id, payload.new_object, payload.actor, payload.reason),
                )
            result_id = cursor.fetchone()[0]
            connection.commit()
            return {"result_id": result_id, "action": payload.action}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Bitemporal Memory Lab</title>
<style>
:root{--bg:#f4f6f9;--surface:#fff;--surface2:#f8fafc;--ink:#14202b;--muted:#5f6f7f;--line:#e2e8ee;--accent:#2f5fd0;--accent-soft:#e8eefc;--ok:#18794e;--ok-soft:#e3f5ec;--old:#8a94a0;--old-soft:#eef1f4;--warn:#b54708;--warn-soft:#fdf0e3;--on-accent:#fff;--shadow:0 1px 2px rgba(20,32,43,.05),0 8px 24px rgba(20,32,43,.06)}
@media (prefers-color-scheme:dark){:root{--bg:#0f141a;--surface:#161d25;--surface2:#1b232d;--ink:#e6edf3;--muted:#9aa8b6;--line:#26313d;--accent:#7aa2ff;--accent-soft:#1d2a45;--ok:#4cc38a;--ok-soft:#14301f;--old:#7d8792;--old-soft:#202831;--warn:#f0a35e;--warn-soft:#33240f;--on-accent:#0f141a;--shadow:none}}
*{box-sizing:border-box}html,body{margin:0}body{font-family:Inter,"Segoe UI",system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--ink);font-size:14px;line-height:1.45}
.shell{max-width:1240px;margin:0 auto;padding:28px 16px 56px}
header{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;flex-wrap:wrap;margin-bottom:18px}
header h1{margin:0;font-size:26px;letter-spacing:-.02em}header p{margin:4px 0 0;color:var(--muted)}
.dot{display:inline-flex;align-items:center;gap:6px;color:var(--muted);font-size:13px}.dot:before{content:"";width:8px;height:8px;border-radius:50%;background:var(--old)}.dot.up:before{background:var(--ok)}.dot.down:before{background:#d14343}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:14px}
.stat{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:12px 14px;box-shadow:var(--shadow)}.stat b{display:block;font-size:22px;font-variant-numeric:tabular-nums}.stat span{color:var(--muted);font-size:12px}
.people{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:4px 0 6px}.people .label{color:var(--muted);font-size:13px;margin-right:4px}
.chip{border:1px solid var(--line);background:var(--surface);color:var(--ink);border-radius:999px;padding:6px 12px;font-weight:600;cursor:pointer}.chip:hover{border-color:var(--accent)}.chip.on{background:var(--accent);border-color:var(--accent);color:var(--on-accent)}.chip.on .muted{color:inherit;opacity:.75}
.card{background:var(--surface);border:1px solid var(--line);border-radius:14px;margin:14px 0;box-shadow:var(--shadow);overflow:hidden}
.card>summary{list-style:none;cursor:pointer;padding:16px 20px;font-weight:700;display:flex;justify-content:space-between;align-items:center;gap:10px}
.card>summary small{color:var(--muted);font-weight:500;margin-left:auto}.card>summary::-webkit-details-marker{display:none}.card>summary:after{content:"+";color:var(--accent);font-size:20px;line-height:1}.card[open]>summary:after{content:"−"}.card[open]>summary{border-bottom:1px solid var(--line)}
.content{padding:16px 20px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px}.field{display:flex;flex-direction:column;gap:6px;font-size:12px;color:var(--muted);font-weight:600}
input,textarea,select,button{font:inherit;border:1px solid var(--line);border-radius:8px;padding:9px 11px;background:var(--surface);color:var(--ink)}input:focus,textarea:focus,select:focus{outline:2px solid var(--accent-soft);border-color:var(--accent)}
textarea{width:100%;min-height:88px;resize:vertical}
button{background:var(--accent);color:var(--on-accent);border-color:var(--accent);font-weight:600;cursor:pointer}button:hover{filter:brightness(.95)}button:disabled{background:var(--old-soft);border-color:var(--line);color:var(--old);cursor:not-allowed}
button.ghost{background:transparent;color:var(--accent)}button.small{padding:5px 9px;font-size:12px}
.actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.row-gap{margin-top:12px}
.status{margin-top:12px;border-radius:8px;background:var(--surface2);border:1px solid var(--line);padding:12px;min-height:44px}.muted{color:var(--muted)}.error{color:#d14343}
.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:10px}table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}tr:last-child td{border-bottom:0}th{color:var(--muted);background:var(--surface2);font-size:11px;text-transform:uppercase;letter-spacing:.05em;white-space:nowrap;position:sticky;top:0}
tr.closed td{color:var(--old)}td.range{white-space:nowrap;font-variant-numeric:tabular-nums}
pre{white-space:pre-wrap;word-break:break-word;background:var(--surface2);border:1px solid var(--line);border-radius:8px;padding:12px;margin:8px 0;font-size:12px}
.badge{display:inline-block;border-radius:999px;padding:2px 8px;background:var(--accent-soft);color:var(--accent);font-size:11px;font-weight:700;white-space:nowrap}
.badge.ok{background:var(--ok-soft);color:var(--ok)}.badge.old{background:var(--old-soft);color:var(--old)}.badge.warn{background:var(--warn-soft);color:var(--warn)}
.turn{border:1px solid var(--line);border-radius:10px;padding:14px;margin:10px 0}.turn h3{margin:0 0 6px;font-size:14px;display:flex;gap:8px;align-items:center}.turn p{margin:0 0 10px}
.route{display:flex;gap:6px;flex-wrap:wrap;margin:10px 0}
.lanes{margin:14px 0 6px}.lane{display:grid;grid-template-columns:minmax(120px,190px) 1fr;gap:10px;align-items:center;margin:6px 0}.lane .name{font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.track{position:relative;height:22px;background:var(--surface2);border:1px solid var(--line);border-radius:6px}.bar{position:absolute;top:3px;bottom:3px;border-radius:4px;background:var(--ok);min-width:3px}.bar.old{background:repeating-linear-gradient(45deg,var(--old),var(--old) 4px,transparent 4px,transparent 7px);border:1px solid var(--old)}
.axis{display:grid;grid-template-columns:minmax(120px,190px) 1fr;gap:10px;font-size:11px;color:var(--muted)}.axis div:last-child{display:flex;justify-content:space-between}
.legend{display:flex;gap:14px;font-size:12px;color:var(--muted);margin-top:6px}.legend i{display:inline-block;width:18px;height:10px;border-radius:3px;margin-right:5px;vertical-align:middle}
@media(max-width:640px){header h1{font-size:22px}.content{padding:14px}.card>summary{padding:14px}.lane,.axis{grid-template-columns:90px 1fr}}
</style></head><body><div class="shell">
<header><div><h1>Bitemporal Memory Lab</h1><p>What was true, and what the system believed it was, at any moment. All times in IST.</p></div><span id="dbStatus" class="dot">Connecting…</span></header>
<section class="stats" id="stats"></section>
<div class="people"><span class="label">People in memory:</span><span id="people" class="actions"><span class="muted">Loading…</span></span></div>

<details class="card" open><summary>Ask a temporal question <small>natural language → SQL route</small></summary><div class="content">
<div class="actions"><select id="queryPreset" onchange="usePreset()"></select></div>
<div class="actions row-gap"><input id="question" style="flex:1;min-width:220px" value="Where did Ilina work about 2026-05-28, as believed on 2026-06-10?"><button onclick="naturalQuery()">Ask</button></div>
<div id="queryResult" class="status muted">Pick an example or type a question.</div></div></details>

<details class="card" open><summary>Timeline explorer <small>valid time vs belief time</small></summary><div class="content">
<div class="grid"><div class="field">Person<input id="timelineSubject" value="Ilina"></div><div class="field">Predicate<select id="timelinePredicate"><option>works_at</option><option>lives_in</option><option selected>has_role</option><option>favourite_food</option><option>likes</option><option>speaks</option><option>skilled_in</option></select></div><div class="field">Valid at (optional)<input id="validAt" type="date"></div><div class="field">Believed at (optional)<input id="believedAt" type="date"></div></div>
<div class="actions row-gap"><button onclick="loadTimeline()">View timeline</button><span class="muted">Leave both dates empty to see every row ever stored.</span></div><div id="timeline"></div></div></details>

<details class="card" open><summary>Store a new message <small>extract → normalise → remember()</small></summary><div class="content">
<div class="grid"><div class="field">Person<input id="subject" value="Ilina"></div><div class="field">Conversation ID<input id="conversation" value="web"></div></div>
<div class="field row-gap">Message<textarea id="text" placeholder="Example: I joined the Coral Reef Institute last week as a field fellow."></textarea></div>
<div class="actions row-gap"><button onclick="storePrompt()">Extract and store</button></div><pre id="result" class="status">No message submitted yet.</pre></div></details>

<details class="card" open><summary>Conversation history <small>provenance of every fact</small></summary><div class="content">
<div class="field">Conversation<select id="conversationSelect"><option value="">Loading conversations…</option></select></div>
<div id="conversationTurns" class="muted row-gap">Select a conversation to view its turns.</div></div></details>

<details class="card" open><summary>Currently true <small>current_facts view</small></summary><div class="content"><div id="current"></div></div></details>

<details class="card"><summary>All stored rows <small>append-only history with corrections</small></summary><div class="content">
<div class="actions"><input id="factFilter" placeholder="Filter by person, predicate or value" style="flex:1;min-width:200px" oninput="renderFacts()"><label class="muted"><input type="checkbox" id="onlyActive" onchange="renderFacts()"> only currently believed</label></div>
<div id="facts" class="row-gap"></div></div></details>

<details class="card"><summary>Correction audit <small>fact_corrections</small></summary><div class="content"><div id="corrections"></div></div></details>
<details class="card"><summary>Original sources <small>sources</small></summary><div class="content"><div id="sources"></div></div></details>
<script>
const $=s=>document.querySelector(s);
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let STATE={facts:[],current:[],corrections:[],sources:[]},PERSON='Ilina';
const MONTHS=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

// ---- range parsing: accepts '[a, None)', '["a","b")', '["a",)' ----
function parseStamp(t){
 t=String(t||'').replace(/"/g,'').trim();
 if(!t||t==='None'||t==='infinity')return null;
 t=t.replace(' IST','+05:30').replace(' UTC','+00:00').replace(' ','T');
 const d=new Date(t);return isNaN(d)?null:d;
}
function parseRange(v){
 const s=String(v??'').trim();if(!/^[\[(]/.test(s))return null;
 const inner=s.slice(1,-1);const i=inner.indexOf(',');if(i<0)return null;
 return {from:parseStamp(inner.slice(0,i)),to:parseStamp(inner.slice(i+1)),open:!parseStamp(inner.slice(i+1))};
}
function fmtDate(d){
 if(!d)return 'open';
 const ist=new Date(d.getTime()+(330+d.getTimezoneOffset())*60000);
 let out=ist.getDate()+' '+MONTHS[ist.getMonth()]+' '+ist.getFullYear();
 if(ist.getHours()||ist.getMinutes())out+=', '+String(ist.getHours()).padStart(2,'0')+':'+String(ist.getMinutes()).padStart(2,'0');
 return out;
}
function formatRange(v){const r=parseRange(v);if(!r)return esc(v);return esc(fmtDate(r.from))+' → '+(r.open?'<span class="badge ok">now</span>':esc(fmtDate(r.to)))}

function displayValue(value,key){
 if(key==='active')return value?'<span class="badge ok">believed</span>':'<span class="badge old">superseded</span>';
 if(key==='action')return '<span class="badge '+(value==='reject'?'warn':value==='restore'?'ok':'')+'">'+esc(value)+'</span>';
 if(key==='confidence'&&typeof value==='number')return Math.round(value*100)+'%';
 if(value===null||value===undefined||value==='')return '<span class="muted">—</span>';
 if(typeof value==='object')return esc(JSON.stringify(value));
 if(/_period$/.test(key||''))return formatRange(value);
 return esc(value);
}
function isClosed(r){if('active' in r)return r.active===false;const sp=parseRange(r.sys_period);return sp?!sp.open:false}
function table(rows,extra){
 if(!rows||!rows.length)return '<p class="muted">No rows.</p>';
 const keys=Object.keys(rows[0]);
 return '<div class="table-wrap"><table><thead><tr>'+keys.map(k=>'<th>'+esc(k.replaceAll('_',' '))+'</th>').join('')+(extra?'<th>Actions</th>':'')+'</tr></thead><tbody>'+
 rows.map(r=>'<tr class="'+(isClosed(r)?'closed':'')+'">'+keys.map(k=>'<td class="'+(/_period$/.test(k)?'range':'')+'">'+displayValue(r[k],k)+'</td>').join('')+(extra?'<td>'+extra(r)+'</td>':'')+'</tr>').join('')+'</tbody></table></div>';
}

// ---- people, stats, presets ----
function presetsFor(p){
 const q=[['What does '+p+' like?'],['Where does '+p+' live?'],["What is "+p+"'s role?"],["What is "+p+"'s favourite food?"],["When did "+p+"'s role change?"],["When did "+p+"'s employer change?"],['Where did '+p+' work in 2025?']];
 if(p==='Ilina')q.unshift(['Where did Ilina work about 2026-05-28, as believed on 2026-06-10?','before the correction'],['Where did Ilina work about 2026-05-28, as believed on 2026-06-25?','after the correction'],['Where did Ilina live in June 2026?']);
 return q;
}
function renderPresets(){
 $('#queryPreset').innerHTML='<option value="">Example questions for '+esc(PERSON)+'…</option>'+presetsFor(PERSON).map(([q,n])=>'<option value="'+esc(q)+'">'+esc(q)+(n?' ('+esc(n)+')':'')+'</option>').join('');
}
function selectPerson(p){
 PERSON=p;['#subject','#timelineSubject'].forEach(s=>$(s).value=p);
 document.querySelectorAll('.chip').forEach(c=>c.classList.toggle('on',c.dataset.person===p));
 renderPresets();$('#factFilter').value=p;renderFacts();loadTimeline();
}
function renderPeople(){
 const counts={};STATE.current.forEach(r=>counts[r.subject]=(counts[r.subject]||0)+1);
 STATE.facts.forEach(r=>{if(!(r.subject in counts))counts[r.subject]=0});
 const names=Object.keys(counts).sort((a,b)=>(a==='Ilina'?-1:b==='Ilina'?1:a.localeCompare(b)));
 $('#people').innerHTML=names.map(n=>'<button class="chip'+(n===PERSON?' on':'')+'" data-person="'+esc(n)+'">'+esc(n)+' <span class="muted" style="font-weight:500">'+counts[n]+'</span></button>').join('')||'<span class="muted">Nobody yet.</span>';
}
function renderStats(convCount){
 const f=STATE.facts,people=new Set(f.map(r=>r.subject)).size,active=f.filter(r=>r.active).length;
 const items=[[people,'people'],[f.length,'stored rows'],[STATE.current.length,'true right now'],[active,'currently believed'],[f.length-active,'superseded rows'],[convCount,'conversations'],[STATE.corrections.length,'manual corrections']];
 $('#stats').innerHTML=items.map(([n,l])=>'<div class="stat"><b>'+esc(n)+'</b><span>'+esc(l)+'</span></div>').join('');
}
function usePreset(){const v=$('#queryPreset').value;if(v){$('#question').value=v;naturalQuery()}}

// ---- actions ----
async function storePrompt(){
 const result=$('#result');result.textContent='Saving…';
 try{
  const r=await fetch('/api/turn',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({subject:$('#subject').value,conversation_id:$('#conversation').value,text:$('#text').value})});
  const d=await r.json();result.textContent=JSON.stringify(d,null,2);if(r.ok)await refresh();
 }catch(exc){result.textContent='Request failed: '+exc}
}
async function naturalQuery(){
 const out=$('#queryResult');out.className='status';out.textContent='Thinking…';
 try{
  const r=await fetch('/api/natural-query',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({question:$('#question').value})});
  const d=await r.json();
  if(!r.ok){out.innerHTML='<span class="error">'+esc(d.detail||'Query failed')+'</span>';return}
  const rt=d.route||{};let h='<div class="route"><span class="badge">route: '+esc(rt.kind)+'</span>';
  if(rt.subject)h+='<span class="badge old">subject: '+esc(rt.subject)+'</span>';
  if(rt.predicate)h+='<span class="badge old">predicate: '+esc(rt.predicate)+'</span>';
  if(rt.valid_at)h+='<span class="badge ok">valid at '+esc(rt.valid_at.slice(0,10))+'</span>';
  if(rt.believed_at)h+='<span class="badge warn">believed at '+esc(rt.believed_at.slice(0,10))+'</span>';
  h+='</div>'+(d.rows&&d.rows.length?table(d.rows):'<p class="muted">No rows: at that belief time the system did not know any answer.</p>');
  h+='<details><summary class="muted" style="cursor:pointer">Raw JSON</summary><pre>'+esc(JSON.stringify(d,null,2))+'</pre></details>';
  out.innerHTML=h;
 }catch(exc){out.textContent='Request failed: '+exc}
}
async function loadConversations(){
 const r=await fetch('/api/conversations');const d=await r.json();const rows=d.conversations||[];const select=$('#conversationSelect');
 if(!rows.length){select.innerHTML='<option value="">No conversations</option>';return 0}
 const previous=select.value;select.innerHTML='<option value="">Choose a conversation</option>'+rows.map(x=>'<option value="'+esc(x.conversation_id)+'">'+esc(x.conversation_id)+' · '+esc(x.turn_count)+' turn'+(x.turn_count===1?'':'s')+' · last '+esc(String(x.last_activity||'').split(',')[0])+'</option>').join('');
 if(previous&&rows.some(x=>x.conversation_id===previous))select.value=previous;
 return rows.length;
}
async function loadConversation(id){
 const panel=$('#conversationTurns');
 if(!id){panel.innerHTML='<p class="muted">Select a conversation to view its turns.</p>';return}
 panel.textContent='Loading conversation…';
 try{
  const r=await fetch('/api/conversations/'+encodeURIComponent(id));if(!r.ok)throw new Error('Could not load conversation');
  const d=await r.json();let h='<div class="actions"><span class="badge">'+esc(d.turns?.length||0)+' turns</span><button id="replaySelected" class="ghost small" type="button">Replay extraction (read-only)</button></div>';
  for(const turn of d.turns||[]){
   h+='<div class="turn"><h3>Turn '+esc(turn.turn_no)+' <span class="badge old">'+esc(turn.speaker||'user')+'</span><span class="muted" style="font-weight:500">'+esc(turn.occurred_at)+'</span></h3><p>“'+esc(turn.content)+'”</p>'+table(Array.isArray(turn.facts)?turn.facts:[])+'</div>';
  }
  panel.innerHTML=h;$('#replaySelected').onclick=()=>replayConversation(id);
 }catch(exc){panel.innerHTML='<p class="error">'+esc(exc.message)+'</p>'}
}
async function replayConversation(id){
 const panel=$('#conversationTurns');
 panel.insertAdjacentHTML('beforeend','<div class="turn" id="replayBox"><h3>Replay preview</h3><p class="muted">Re-extracting original turns without writing facts…</p></div>');
 const r=await fetch('/api/conversations/'+encodeURIComponent(id)+'/replay',{method:'POST'});const d=await r.json();
 $('#replayBox').innerHTML='<h3>Replay preview</h3>'+(d.turns||[]).map(t=>'<b>Turn '+esc(t.turn_no)+'</b><pre>'+esc(JSON.stringify(t.facts,null,2))+'</pre>').join('');
}
function lanes(rows){
 const parsed=rows.map(r=>({r,v:parseRange(r.valid_period)})).filter(x=>x.v&&x.v.from);
 if(!parsed.length)return '';
 const now=Date.now();let min=Math.min(...parsed.map(x=>x.v.from.getTime())),max=Math.max(now,...parsed.map(x=>x.v.to?x.v.to.getTime():now));
 if(max<=min)max=min+86400000;const pct=t=>((t-min)/(max-min)*100).toFixed(2);
 let h='<div class="lanes">'+parsed.map(({r,v})=>{const closed=isClosed(r),end=v.to?v.to.getTime():now;
  const tip=r.object+' | valid '+fmtDate(v.from)+' → '+(v.open?'now':fmtDate(v.to))+(r.sys_period?' | believed '+String(formatRange(r.sys_period)).replace(/<[^>]+>/g,''):'');
  return '<div class="lane"><div class="name" title="'+esc(r.object)+'">'+esc(r.object)+'</div><div class="track"><div class="bar'+(closed?' old':'')+'" title="'+esc(tip)+'" style="left:'+pct(v.from.getTime())+'%;width:'+(pct(end)-pct(v.from.getTime())).toFixed(2)+'%"></div></div></div>'}).join('');
 h+='<div class="axis"><div></div><div><span>'+esc(fmtDate(new Date(min)))+'</span><span>'+esc(fmtDate(new Date(max)))+'</span></div></div>';
 return h+'<div class="legend"><span><i style="background:var(--ok)"></i>valid period, still believed</span><span><i style="background:repeating-linear-gradient(45deg,var(--old),var(--old) 3px,transparent 3px,transparent 6px)"></i>no longer believed (superseded or corrected)</span></div></div>';
}
async function loadTimeline(){
 const params=new URLSearchParams({subject:$('#timelineSubject').value,predicate:$('#timelinePredicate').value});
 if($('#validAt').value)params.set('valid_at',$('#validAt').value);
 if($('#believedAt').value)params.set('believed_at',$('#believedAt').value);
 const box=$('#timeline');box.innerHTML='<p class="muted">Loading…</p>';
 try{const r=await fetch('/api/timeline?'+params);const d=await r.json();const rows=d.rows||[];box.innerHTML=lanes(rows)+table(rows)}
 catch(exc){box.innerHTML='<p class="error">'+esc(exc)+'</p>'}
}
async function correctFact(factId,action){
 const newObject=action==='replace'?prompt('Replacement value:'):null;if(action==='replace'&&!newObject)return;
 const reason=prompt('Reason for '+action+':');if(!reason)return;const actor=prompt('Corrected by:','dashboard-user')||'dashboard-user';
 const r=await fetch('/api/corrections',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({fact_id:factId,action,new_object:newObject,actor,reason})});const d=await r.json();
 alert(r.ok?'Correction saved: '+d.action:'Correction failed: '+(d.detail||'unknown error'));await refresh();
}
function factButtons(r){
 const id=Number(r.fact_id),active=r.active===true;
 return '<div class="actions"><button class="small" '+(active?'':'disabled')+' data-fact-action="replace" data-fact-id="'+id+'">Replace</button><button class="small" '+(active?'':'disabled')+' data-fact-action="reject" data-fact-id="'+id+'">Reject</button><button class="small ghost" '+(!active?'':'disabled')+' data-fact-action="restore" data-fact-id="'+id+'">Restore</button></div>';
}
function renderFacts(){
 const q=$('#factFilter').value.trim().toLowerCase(),only=$('#onlyActive').checked;
 const rows=STATE.facts.filter(r=>(!only||r.active)&&(!q||[r.subject,r.predicate,r.object].join(' ').toLowerCase().includes(q)));
 $('#facts').innerHTML='<p class="muted">'+rows.length+' of '+STATE.facts.length+' rows</p>'+table(rows,factButtons);
}
async function refresh(){
 try{
  const r=await fetch('/api/state');const d=await r.json();if(!r.ok)throw new Error(d.detail||'database unavailable');
  STATE=d;$('#dbStatus').className='dot up';$('#dbStatus').textContent='Database connected';
  $('#current').innerHTML=table(d.current);renderFacts();$('#corrections').innerHTML=table(d.corrections||[]);$('#sources').innerHTML=table(d.sources);
  renderPeople();renderStats(await loadConversations());
 }catch(exc){$('#dbStatus').className='dot down';$('#dbStatus').textContent='Database unavailable: '+exc.message}
}
$('#conversationSelect').addEventListener('change',e=>loadConversation(e.target.value));
$('#people').addEventListener('click',e=>{const c=e.target.closest('[data-person]');if(c)selectPerson(c.dataset.person)});
$('#facts').addEventListener('click',e=>{const b=e.target.closest('[data-fact-action]');if(b&&!b.disabled)correctFact(Number(b.dataset.factId),b.dataset.factAction)});
renderPresets();refresh().then(()=>{loadTimeline();naturalQuery()});
</script></div></body></html>"""
