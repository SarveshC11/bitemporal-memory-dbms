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


HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Bitemporal Memory Lab</title>
<style>
:root{--navy:#15324b;--blue:#2f67a1;--blue2:#eaf2f8;--ink:#17202a;--muted:#667788;--line:#dfe7ed;--surface:#fff;--bg:#f3f6f8}
*{box-sizing:border-box}body{font-family:Inter,Segoe UI,system-ui,sans-serif;margin:0;background:var(--bg);color:var(--ink)}
.shell{max-width:1240px;margin:0 auto;padding:28px 20px 48px}.brand{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px}
.brand h1{margin:0;color:var(--navy);font-size:28px}.brand small{color:var(--muted)}.card{background:var(--surface);border:1px solid var(--line);border-radius:14px;margin:14px 0;box-shadow:0 8px 24px rgba(21,50,75,.07);overflow:hidden}
.card>summary{list-style:none;cursor:pointer;padding:18px 22px;font-weight:750;color:var(--navy);background:linear-gradient(90deg,#fff,var(--blue2));border-bottom:1px solid transparent}
.card[open]>summary{border-bottom-color:var(--line)}.card>summary::-webkit-details-marker{display:none}.card>summary:after{content:"+";float:right;color:var(--blue);font-size:20px}.card[open]>summary:after{content:"−"}
.content{padding:18px 22px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}.field{display:flex;flex-direction:column;gap:6px;font-size:13px;color:var(--muted)}
input,textarea,select,button{font:inherit;border:1px solid #cbd7df;border-radius:8px;padding:10px 12px}textarea{width:100%;min-height:94px;resize:vertical}select{background:white}
button{background:var(--blue);color:white;border:0;padding:9px 14px;font-weight:650;cursor:pointer}button:hover{filter:brightness(.94)}button:disabled{background:#9ba7b2;cursor:not-allowed}
.actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.status{margin-top:12px;border-radius:8px;background:#f7fafc;padding:12px;min-height:44px}.muted{color:var(--muted)}
.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:10px 9px;border-bottom:1px solid #edf1f4;vertical-align:top}th{color:var(--navy);background:#f7fafc;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
pre{white-space:pre-wrap;background:#f7fafc;border:1px solid var(--line);border-radius:8px;padding:12px}.turn{border:1px solid var(--line);border-radius:10px;padding:14px;margin:10px 0}.turn h3{margin-top:0;color:var(--navy)}
.badge{display:inline-block;border-radius:999px;padding:3px 8px;background:#edf4fa;color:var(--blue);font-size:12px}.two-col{display:grid;grid-template-columns:minmax(220px,.35fr) 1fr;gap:14px}
@media(max-width:800px){.two-col{grid-template-columns:1fr}.brand{align-items:flex-start;flex-direction:column}}
</style></head><body><div class="shell">
<header class="brand"><h1>Bitemporal Memory Lab</h1><small>All timestamps shown in IST</small></header>
<details class="card" open><summary>Store a prompt</summary><div class="content">
<div class="grid"><div class="field">Subject<input id="subject" value="Priya"></div><div class="field">Conversation ID<input id="conversation" value="web"></div></div>
<div class="field" style="margin-top:10px">Prompt<textarea id="text" placeholder="Example: I joined Zeta Labs last week as a founding engineer."></textarea></div>
<button onclick="storePrompt()">Extract and store</button><pre id="result" class="status">No prompt submitted yet.</pre></div></details>
<details class="card" open><summary>Natural-language temporal query</summary><div class="content">
<div class="actions"><select id="queryPreset" onchange="usePreset()"><option value="">Choose an example query</option><option>What does Priya like?</option><option>Where does Priya live?</option><option>Where did Priya work in 2025?</option><option>What is Priya's favourite food?</option><option>When did Priya's employer change?</option></select><input id="question" style="flex:1" value="Where did Priya work in 2025?"><button onclick="naturalQuery()">Search</button></div>
<pre id="queryResult" class="status">No query submitted yet.</pre></div></details>
<details class="card" open><summary>Conversation history</summary><div class="content">
<div class="field">Select conversation<select id="conversationSelect"><option value="">Loading conversations...</option></select></div>
<div id="conversationTurns" class="muted">Select a conversation to view its turns.</div></div></details>
<details class="card"><summary>Temporal timeline</summary><div class="content">
<div class="grid"><div class="field">Subject<input id="timelineSubject" value="Priya"></div><div class="field">Predicate<select id="timelinePredicate"><option>works_at</option><option>lives_in</option><option>has_role</option><option>favourite_food</option><option>likes</option><option>speaks</option><option>skilled_in</option></select></div><div class="field">Valid at<input id="validAt" type="date"></div><div class="field">Believed at<input id="believedAt" type="date"></div></div>
<button onclick="loadTimeline()">View timeline</button><div id="timeline"></div></div></details>
<details class="card" open><summary>Current facts</summary><div class="content"><div id="current"></div></div></details>
<details class="card" open><summary>Stored facts and history</summary><div class="content"><div id="facts"></div></div></details>
<details class="card"><summary>Correction audit</summary><div class="content"><div id="corrections"></div></div></details>
<details class="card"><summary>Original sources</summary><div class="content"><div id="sources"></div></div></details>
<script>
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function usePreset(){if(document.querySelector('#queryPreset').value)document.querySelector('#question').value=document.querySelector('#queryPreset').value}
function formatRange(value){
 let text=String(value??'');
 text=text.replace(/^\\["/,'[').replace(/",None\\)/,", open ended)");
 text=text.replace(/\+05:30/g,' IST').replace(/\+00:00/g,' UTC');
 text=text.replace(/\b(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.[0-9]+)? IST/g,'$1, $2 IST');
 return text.replace('None','open ended');
}
function displayValue(value,key){
 if(value===null||value===undefined||value==='')return '<span class="muted">—</span>';
 if(typeof value==='object')return esc(JSON.stringify(value));
 let text=String(value);
 if(/_period/.test(key||''))return esc(formatRange(text));
 if(/^(corrected_at|started_at|last_activity|occurred_at)$/.test(key||''))return esc(text.replace('+05:30',' IST'));
 return esc(text);
}
function table(rows){
 if(!rows||!rows.length)return '<p class="muted">No rows.</p>';
 let keys=Object.keys(rows[0]);
 return '<div class="table-wrap"><table><thead><tr>'+keys.map(k=>'<th>'+esc(k.replaceAll('_',' '))+'</th>').join('')+'</tr></thead><tbody>'+
 rows.map(r=>'<tr>'+keys.map(k=>'<td>'+displayValue(r[k],k)+'</td>').join('')+'</tr>').join('')+'</tbody></table></div>';
}
async function storePrompt(){
 let result=document.querySelector('#result');result.textContent='Saving...';
 try{
  let r=await fetch('/api/turn',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({subject:document.querySelector('#subject').value,conversation_id:document.querySelector('#conversation').value,text:document.querySelector('#text').value})});
  let d=await r.json();result.textContent=JSON.stringify(d,null,2);if(r.ok)await refresh();
 }catch(exc){result.textContent='Request failed: '+exc;}
}
async function naturalQuery(){
 try{
  let r=await fetch('/api/natural-query',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({question:document.querySelector('#question').value})});
  let d=await r.json();document.querySelector('#queryResult').textContent=JSON.stringify(d,null,2);
 }catch(exc){document.querySelector('#queryResult').textContent='Request failed: '+exc;}
}
async function loadConversations(){
 let r=await fetch('/api/conversations');let d=await r.json();let rows=d.conversations||[];let select=document.querySelector('#conversationSelect');
 if(!rows.length){select.innerHTML='<option value="">No conversations</option>';return}
 let previous=select.value;select.innerHTML='<option value="">Choose a conversation</option>'+rows.map(x=>'<option value="'+esc(x.conversation_id)+'">'+esc(x.conversation_id)+' — '+esc(x.turn_count)+' turn'+(x.turn_count===1?'':'s')+'</option>').join('');
 if(previous&&rows.some(x=>x.conversation_id===previous)){select.value=previous}
}
async function loadConversation(id){
 if(!id){document.querySelector('#conversationTurns').innerHTML='<p class="muted">Select a conversation to view its turns.</p>';return}
 let panel=document.querySelector('#conversationTurns');panel.textContent='Loading conversation...';
 try{
  let r=await fetch('/api/conversations/'+encodeURIComponent(id));if(!r.ok)throw new Error('Could not load conversation');
  let d=await r.json();let h='<div class="actions"><span class="badge">'+esc(d.turns?.length||0)+' turns</span><button id="replaySelected" type="button">Replay conversation</button></div>';
  for(let turn of d.turns||[]){
   h+='<div class="turn"><h3>Turn '+esc(turn.turn_no)+' <span class="badge">'+esc(turn.speaker||'user')+'</span></h3><p>'+esc(turn.content)+'</p><b>Facts extracted or associated</b>'+table(Array.isArray(turn.facts)?turn.facts:[])+'</div>';
  }
  panel.innerHTML=h||'<p class="muted">No turns found.</p>';
  document.querySelector('#replaySelected').onclick=()=>replayConversation(id);
 }catch(exc){panel.innerHTML='<p class="muted">'+esc(exc.message)+'</p>'}
}
async function replayConversation(id){
 let panel=document.querySelector('#conversationTurns');
 panel.insertAdjacentHTML('beforeend','<div class="turn"><h3>Replay preview</h3><p class="muted">Re-extracting original turns without writing facts...</p></div>');
 let r=await fetch('/api/conversations/'+encodeURIComponent(id)+'/replay',{method:'POST'});let d=await r.json();let h=panel.querySelector('.turn:last-child');h.innerHTML='<h3>Replay preview</h3>'+d.turns.map(t=>'<b>Turn '+esc(t.turn_no)+'</b><pre>'+esc(JSON.stringify(t,null,2))+'</pre>').join('');
}
async function loadTimeline(){
 let params=new URLSearchParams({subject:document.querySelector('#timelineSubject').value,predicate:document.querySelector('#timelinePredicate').value});
 if(document.querySelector('#validAt').value)params.set('valid_at',document.querySelector('#validAt').value);
 if(document.querySelector('#believedAt').value)params.set('believed_at',document.querySelector('#believedAt').value);
 let r=await fetch('/api/timeline?'+params);let d=await r.json();document.querySelector('#timeline').innerHTML=table(d.rows||[]);
}
async function correctFact(factId,action){
 let newObject=action==='replace'?prompt('Replacement object:'):null;if(action==='replace'&&!newObject)return;
 let reason=prompt('Reason for '+action+':');if(!reason)return;let actor=prompt('Corrected by:','dashboard-user')||'dashboard-user';
 let r=await fetch('/api/corrections',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({fact_id:factId,action,new_object:newObject,actor,reason})});let d=await r.json();
 alert(r.ok?'Correction saved: '+d.action:'Correction failed: '+(d.detail||'unknown error'));await refresh();
}
function factActions(rows){
 if(!rows.length)return '<p class="muted">No rows.</p>';let keys=Object.keys(rows[0]);let h='<div class="table-wrap"><table><thead><tr>'+keys.map(k=>'<th>'+esc(k.replaceAll('_',' '))+'</th>').join('')+'<th>Actions</th></tr></thead><tbody>';
 h+=rows.map(r=>{let factId=Number(r.fact_id);let active=r.active===true;return '<tr>'+keys.map(k=>'<td>'+displayValue(r[k],k)+'</td>').join('')+'<td><div class="actions"><button '+(active?'':'disabled')+' data-fact-action="replace" data-fact-id="'+factId+'">Replace</button><button '+(active?'':'disabled')+' data-fact-action="reject" data-fact-id="'+factId+'">Reject</button><button '+(!active?'':'disabled')+' data-fact-action="restore" data-fact-id="'+factId+'">Restore</button></div></td></tr>'}).join('');
 return h+'</tbody></table></div>';
}
async function refresh(){
 let r=await fetch('/api/state');let d=await r.json();document.querySelector('#current').innerHTML=table(d.current);document.querySelector('#facts').innerHTML=factActions(d.facts);document.querySelector('#corrections').innerHTML=table(d.corrections||[]);document.querySelector('#sources').innerHTML=table(d.sources);await loadConversations();
}
document.querySelector('#conversationSelect').addEventListener('change',event=>loadConversation(event.target.value));
document.querySelector('#facts').addEventListener('click',event=>{let button=event.target.closest('[data-fact-action]');if(button&&!button.disabled)correctFact(Number(button.dataset.factId),button.dataset.factAction)});
refresh();
</script></div></body></html>"""
