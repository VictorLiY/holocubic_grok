/**
 * WorkBuddy 实时状态监控 · 本地服务
 * ------------------------------------------------------------
 * 数据从哪里来？
 *   WorkBuddy 的每个「工作区(项目)」在
 *     ~/.workbuddy/projects/<项目目录编码>/
 *   下按会话存放轨迹：
 *     <sessionId>.jsonl               ← 会话全量轨迹（逐行追加）
 *     <sessionId>/tool-results/       ← 该会话的工具产物
 *     <sessionId>.file-rollback.ndjson← 文件改动回滚记录
 *
 * 项目目录编码规则：小写盘符 + 把 ":" 和 "\" 换成 "-"，例如
 *   C:\Users\Li_Yu\WorkBuddy\2026-10-30  →  c-Users-Li_Yu-WorkBuddy-2026-10-30
 * 该编码不可逆（路径本身含 "-"），所以项目真实路径一律以轨迹记录里的
 * cwd 字段为准，目录名只作兜底。
 *
 * 新工作(项目)如何被发现：
 *   每 2.5s 扫描 projects 目录 → 出现新的一级目录即为新项目；
 *   每个项目下 mtime 最新的 .jsonl 即该项目当前会话；
 *   全局 mtime 最新的那一份即「正在工作的会话」，自动跟随。
 *
 * 启动： node monitor-server.mjs [--open] [--lan]
 * 可选： PORT=9000 node monitor-server.mjs
 *        HOST=0.0.0.0 node monitor-server.mjs   （或 --lan，开放给局域网设备）
 *
 * 接口：
 *   GET  /             → 仪表盘页面
 *   GET  /events       → SSE 实时状态流
 *   GET  /api/state    → 当前状态快照（JSON）
 *   GET  /api/projects → 所有项目及其会话列表
 *   POST /api/state    → 手动覆盖状态 {"status":"working","detail":"..."}
 *   POST /api/hook     → 接收 hooks 事件 {"event":"PreToolUse","tool":"Bash"}
 *   GET  /api/holo     → 紧凑状态（HoloCubic grok_bot 轮询用，<300B）
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST
  || (process.argv.includes('--lan') ? '0.0.0.0' : '127.0.0.1');
const PROJECTS = path.join(os.homedir(), '.workbuddy', 'projects');
const IDLE_AFTER = 25000;   // 超过该时长没有新记录 → 空闲
const POLL = 400;           // 轮询间隔(ms)
const SCAN_EVERY = 2500;    // 重新扫描项目/会话的间隔(ms)

/* ---------------------------------------------------------------- 状态 */

const st = {
  status: 'idle',
  statusSince: Date.now(),
  detail: '',
  model: '',
  title: '',
  sessionId: '',
  cwd: '',
  projDir: '',          // projects 下的一级目录名（编码后的项目目录）
  sessionStart: 0,
  stepSeq: 0,
  toolCount: 0,
  eventTotal: 0,
  lastEventTs: 0,
  lastKind: null,
  events: [],
  file: '',
  errorAt: 0,
};

const clientOverrides = new Map(); // 手动覆盖状态（POST /api/state）

let cur = { file: null, off: 0, partial: '' };
let lastScan = 0;
let lastPayload = '';
let projectList = [];

/* ---------------------------------------------------------------- 工具 */

const TOOL_LABEL = {
  Bash: '执行命令', PowerShell: '执行命令', Read: '读取文件', Write: '写入文件',
  Edit: '编辑文件', Glob: '检索文件', Grep: '搜索内容', WebSearch: '联网搜索',
  WebFetch: '抓取网页', TaskCreate: '规划任务', TaskUpdate: '更新任务',
  Skill: '调用技能', Agent: '派发子智能体', present_files: '展示结果',
};

const metaCache = new Map(); // file:size → { title, cwd }

function trunc(s, n) {
  s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

function stripNoise(text) {
  let t = String(text || '');
  const m = t.match(/<user_query>([\s\S]*?)<\/user_query>/);
  if (m) t = m[1];
  t = t.replace(/<system-reminder[\s\S]*?<\/system-reminder>/g, '');
  t = t.replace(/<[^>]{0,120}>/g, ' ');
  return trunc(t, 90);
}

function contentText(content, pref) {
  if (!Array.isArray(content)) return typeof content === 'string' ? content : '';
  const hit = content.find((c) => c && (!pref || c.type === pref));
  return hit && hit.text ? hit.text : '';
}

function summarizeArgs(args) {
  let a = args;
  if (typeof a === 'string') {
    try { a = JSON.parse(a); } catch { return trunc(a, 58); }
  }
  if (!a || typeof a !== 'object') return '';
  const pick = a.command || a.file_path || a.path || a.pattern || a.query ||
               a.url || a.prompt || a.description || a.skill || a.name;
  if (!pick) return '';
  let v = String(pick).split('\n')[0];
  if (a.file_path || a.path) {
    const parts = v.split(/[\\/]+/).filter(Boolean);
    if (parts.length > 1) v = parts.slice(-2).join('/');
  }
  return trunc(v, 58);
}

function pushEvent(t, kind, text) {
  st.eventTotal = (st.eventTotal || 0) + 1;
  st.events.unshift({ t, kind, text });
  if (st.events.length > 60) st.events.length = 60;
}

/* ------------------------------------------------------- 项目/会话元信息 */

/** 从轨迹文件头部取会话标题（ai-title 记录），尾部取 cwd；按 size 缓存。 */
function fileMeta(file) {
  let size = 0;
  try { size = fs.statSync(file).size; } catch { return { title: '', cwd: '' }; }
  const key = file + ':' + size;
  const hit = metaCache.get(key);
  if (hit) return hit;

  let title = '';
  let cwd = '';
  try {
    const fd = fs.openSync(file, 'r');
    try {
      const headLen = Math.min(size, 128 * 1024);
      const head = Buffer.alloc(headLen);
      fs.readSync(fd, head, 0, headLen, 0);
      const m = head.toString('utf8').match(/"aiTitle"\s*:\s*"((?:[^"\\]|\\.)*)"/);
      if (m) { try { title = JSON.parse('"' + m[1] + '"'); } catch { title = m[1]; } }

      if (size > headLen) {
        const tailLen = Math.min(size, 24 * 1024);
        const tail = Buffer.alloc(tailLen);
        fs.readSync(fd, tail, 0, tailLen, size - tailLen);
        const all = tail.toString('utf8').match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/g);
        if (all && all.length) {
          const last = all[all.length - 1].match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/)[1];
          try { cwd = JSON.parse('"' + last + '"'); } catch { cwd = last; }
        }
      }
      if (!cwd) {
        const m2 = head.toString('utf8').match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/);
        if (m2) { try { cwd = JSON.parse('"' + m2[1] + '"'); } catch { cwd = m2[1]; } }
      }
    } finally { fs.closeSync(fd); }
  } catch { /* ignore */ }

  const meta = { title, cwd };
  if (metaCache.size > 400) metaCache.clear();
  metaCache.set(key, meta);
  return meta;
}

/** 扫描全部项目：新目录 = 新项目；每个项目取 mtime 最新的会话。 */
function scanProjects() {
  const list = [];
  let dirs = [];
  try {
    dirs = fs.readdirSync(PROJECTS, { withFileTypes: true }).filter((d) => d.isDirectory());
  } catch { return list; }

  for (const d of dirs) {
    const dp = path.join(PROJECTS, d.name);
    let entries = [];
    try { entries = fs.readdirSync(dp, { withFileTypes: true }); } catch { continue; }

    const sessions = [];
    for (const e of entries) {
      if (!e.isFile() || !e.name.endsWith('.jsonl')) continue;
      const fp = path.join(dp, e.name);
      let s;
      try { s = fs.statSync(fp); } catch { continue; }
      sessions.push({
        id: e.name.replace(/\.jsonl$/, ''),
        file: fp,
        size: s.size,
        mtime: s.mtimeMs,
      });
    }
    if (!sessions.length) continue;
    sessions.sort((a, b) => b.mtime - a.mtime);

    const latest = sessions[0];
    const meta = fileMeta(latest.file);
    list.push({
      dir: d.name,
      dirPath: dp,
      cwd: meta.cwd,
      name: meta.cwd ? path.basename(meta.cwd) : d.name,
      title: meta.title,
      count: sessions.length,
      lastActive: latest.mtime,
      session: latest,
      sessionDir: path.join(dp, latest.id),
    });
  }

  list.sort((a, b) => b.lastActive - a.lastActive);
  return list;
}

/* ---------------------------------------------------------------- 解析 */

/** 切换会话时重置「会话级」计数，事件流保留并插入分隔。 */
function switchSession(file) {
  const prevSession = st.sessionId;
  const dirName = path.basename(path.dirname(file));
  Object.assign(st, {
    status: 'idle', statusSince: Date.now(), detail: '', model: '', title: '',
    sessionId: '', cwd: '', projDir: dirName, sessionStart: 0,
    stepSeq: 0, toolCount: 0, lastEventTs: 0, lastKind: null, errorAt: 0, file,
  });
  lastPayload = '';
  if (prevSession) pushEvent(Date.now(), 'session', '会话切换 · 新会话开始');
}

function apply(rec) {
  const t = Number(rec.timestamp) || Date.now();
  if (t > st.lastEventTs) st.lastEventTs = t;
  if (!st.sessionStart || t < st.sessionStart) st.sessionStart = t;
  if (rec.sessionId) st.sessionId = rec.sessionId;
  if (rec.cwd && rec.cwd !== st.cwd) st.cwd = rec.cwd;
  if (rec.aiTitle) st.title = rec.aiTitle;

  const pd = rec.providerData;
  if (pd) {
    const m = pd.requestModelName || pd.modelName || pd.model;
    if (m && !String(m).includes('/')) st.model = m;
    if (typeof pd.stepSeq === 'number') st.stepSeq = Math.max(st.stepSeq, pd.stepSeq);
  }

  switch (rec.type) {
    case 'message': {
      if (rec.role === 'user') {
        const text = contentText(rec.content, 'input_text') || contentText(rec.content);
        st.lastKind = 'user';
        st.detail = trunc(stripNoise(text), 80);
        pushEvent(t, 'user', trunc(stripNoise(text), 88) || '收到新指令');
      } else {
        const text = contentText(rec.content, 'output_text') || contentText(rec.content);
        st.lastKind = 'reply';
        st.detail = trunc(text, 80);
        pushEvent(t, 'reply', trunc(text, 88) || '输出回复');
      }
      break;
    }
    case 'reasoning': {
      const arr = rec.rawContent || rec.content || [];
      const text = Array.isArray(arr)
        ? (arr.find((x) => x && (x.type === 'reasoning_text' || x.text)) || {}).text
        : '';
      st.lastKind = 'think';
      st.detail = trunc(text, 90) || '模型正在推理…';
      pushEvent(t, 'think', st.detail);
      break;
    }
    case 'function_call': {
      st.toolCount += 1;
      const name = rec.name || 'tool';
      const sum = summarizeArgs(rec.arguments);
      st.lastKind = 'tool';
      st.detail = TOOL_LABEL[name] ? `${TOOL_LABEL[name]} · ${sum || name}` : `${name} · ${sum}`;
      pushEvent(t, 'tool', `调用 ${name}${sum ? ' · ' + sum : ''}`);
      break;
    }
    case 'function_call_result': {
      const name = rec.name || 'tool';
      const ok = !rec.status || rec.status === 'completed' || rec.status === 'success';
      st.lastKind = ok ? 'result' : 'error';
      st.detail = `${name} ${ok ? '执行完成' : '执行失败'}`;
      if (!ok) st.errorAt = Date.now();
      pushEvent(t, ok ? 'result' : 'error', st.detail);
      break;
    }
    default:
      break;
  }
}

/* ---------------------------------------------------------------- 文件 */

function pump() {
  const now = Date.now();
  if (!cur.file || now - lastScan > SCAN_EVERY) {
    lastScan = now;
    projectList = scanProjects();
    const active = projectList[0];
    if (active && active.session.file !== cur.file) {
      cur = { file: active.session.file, off: 0, partial: '' };
      switchSession(active.session.file);
      st.sessionId = active.session.id;
      st.cwd = active.cwd;
      st.title = active.title;
    }
  }
  if (!cur.file) return false;

  let s;
  try { s = fs.statSync(cur.file); } catch { cur = { file: null, off: 0, partial: '' }; return false; }

  if (s.size < cur.off) { cur.off = 0; cur.partial = ''; }
  if (s.size === cur.off) return false;

  const len = s.size - cur.off;
  const buf = Buffer.allocUnsafe(len);
  const fd = fs.openSync(cur.file, 'r');
  try { fs.readSync(fd, buf, 0, len, cur.off); } finally { fs.closeSync(fd); }
  cur.off = s.size;

  const chunk = cur.partial + buf.toString('utf8');
  const lines = chunk.split('\n');
  cur.partial = lines.pop() || '';
  for (const line of lines) {
    const raw = line.trim();
    if (!raw) continue;
    let rec;
    try { rec = JSON.parse(raw); } catch { continue; }
    apply(rec);
  }
  return true;
}

/* ---------------------------------------------------------------- 状态机 */

function currentStatus() {
  const now = Date.now();
  if (!st.lastEventTs) return 'idle';
  if (now - st.lastEventTs > IDLE_AFTER) return 'idle';
  switch (st.lastKind) {
    case 'error': return 'error';
    case 'user':
    case 'think': return 'thinking';
    case 'tool':
    case 'result': return 'working';
    case 'reply': return 'standby';
    default: return 'idle';
  }
}

function payload() {
  const next = currentStatus();
  if (next !== st.status) {
    st.status = next;
    st.statusSince = Date.now();
  }
  const ov = clientOverrides.get('global');
  const active = ov && Date.now() - ov.at < 60000;

  const projectName = st.cwd ? path.basename(st.cwd) : st.projDir;
  const body = {
    type: 'state',
    status: active ? ov.status : st.status,
    statusSince: active ? ov.at : st.statusSince,
    detail: active ? ov.detail : st.detail,
    model: st.model,
    title: st.title,
    sessionId: st.sessionId,
    cwd: st.cwd,
    file: st.file,
    project: {
      name: projectName || '未识别',
      path: st.cwd || '',
      dir: st.projDir || '',
      dirPath: st.projDir ? path.join(PROJECTS, st.projDir) : '',
    },
    sessionDir: st.projDir && st.sessionId ? path.join(PROJECTS, st.projDir, st.sessionId) : '',
    sessionStart: st.sessionStart,
    stepSeq: st.stepSeq,
    toolCount: st.toolCount,
    eventTotal: st.eventTotal || 0,
    lastEventTs: st.lastEventTs,
    events: st.events,
    projects: projectList.slice(0, 8).map((p) => ({
      name: p.name,
      path: p.cwd,
      dir: p.dir,
      active: p.dir === st.projDir,
      count: p.count,
      title: p.title,
      lastActive: p.lastActive,
    })),
    projectCount: projectList.length,
    serverTime: Date.now(),
  };
  return body;
}

/* ---------------------------------------------------------------- 服务 */

const clients = new Set();

function broadcast(p) {
  const data = `data: ${JSON.stringify(p)}\n\n`;
  for (const res of clients) {
    try { res.write(data); } catch { clients.delete(res); }
  }
}

setInterval(() => {
  pump();
  const p = payload();
  const key = [p.status, p.events.length, p.lastEventTs, p.stepSeq, p.toolCount,
               p.sessionId, p.project.dir, p.title, p.projectCount].join('|');
  if (key !== lastPayload) {
    lastPayload = key;
    broadcast(p);
  }
}, POLL);

setInterval(() => {
  for (const res of clients) {
    try { res.write(': ping\n\n'); } catch { clients.delete(res); }
  }
}, 15000);

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function sendJson(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', ...CORS });
  res.end(JSON.stringify(obj, null, 2));
}

/* 紧凑 JSON（无缩进）：给 ESP32 这类小内存轮询客户端，省带宽与解析时间 */
function sendJsonCompact(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store', ...CORS });
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on('end', () => {
      try { resolve(JSON.parse(data || '{}')); } catch { resolve({}); }
    });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);

  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS);
    return res.end();
  }

  if (url.pathname === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
      ...CORS,
    });
    res.write('retry: 1500\n\n');
    res.write(`data: ${JSON.stringify(payload())}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }

  if (url.pathname === '/api/projects') {
    projectList = scanProjects();
    return sendJson(res, 200, {
      root: PROJECTS,
      active: st.projDir,
      count: projectList.length,
      projects: projectList.map((p) => ({
        name: p.name,
        path: p.cwd,
        dir: p.dir,
        dirPath: p.dirPath,
        sessions: p.count,
        title: p.title,
        sessionId: p.session.id,
        sessionDir: p.sessionDir,
        lastActive: p.lastActive,
        lastActiveText: new Date(p.lastActive).toLocaleString('zh-CN'),
        active: p.dir === st.projDir,
      })),
    });
  }

  if (url.pathname === '/api/state') {
    if (req.method === 'POST') {
      const b = await readBody(req);
      const allowed = ['thinking', 'working', 'standby', 'idle', 'error'];
      if (b && allowed.includes(b.status)) {
        clientOverrides.set('global', { status: b.status, detail: String(b.detail || ''), at: Date.now() });
        broadcast(payload());
        return sendJson(res, 200, { ok: true, applied: b.status });
      }
      if (b && b.clear) { clientOverrides.delete('global'); return sendJson(res, 200, { ok: true, cleared: true }); }
      return sendJson(res, 400, { ok: false, error: 'status must be one of ' + allowed.join('|') });
    }
    return sendJson(res, 200, payload());
  }

  if (url.pathname === '/api/hook' && req.method === 'POST') {
    const b = await readBody(req);
    const map = {
      SessionStart: 'idle', UserPromptSubmit: 'thinking', PreToolUse: 'working',
      PostToolUse: 'working', Notification: 'standby', Stop: 'standby', SubagentStop: 'working',
    };
    const status = map[b.event] || b.status;
    if (status) {
      clientOverrides.set('global', {
        status, detail: b.tool ? `hooks · ${b.tool}` : `hooks · ${b.event || status}`, at: Date.now(),
      });
      broadcast(payload());
    }
    return sendJson(res, 200, { ok: true, status: status || null });
  }

  if (url.pathname === '/api/holo') {
    const p = payload();
    return sendJsonCompact(res, 200, {
      v: p.eventTotal || 0,
      status: p.status,
      detail: trunc(p.detail, 48),
      statusSince: p.statusSince,
      lastEventTs: p.lastEventTs,
      sessionId: p.sessionId,
      project: (p.project && p.project.name) || '',
      model: st.model,
    });
  }

  if (url.pathname === '/api/health') {
    return sendJson(res, 200, {
      ok: true, watching: cur.file, project: st.projDir, clients: clients.size, uptime: process.uptime(),
    });
  }

  if (url.pathname === '/' || url.pathname === '/index.html') {
    const file = path.join(HERE, 'index.html');
    fs.readFile(file, (err, buf) => {
      if (err) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8', ...CORS });
        return res.end('index.html 未找到');
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache', ...CORS });
      res.end(buf);
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8', ...CORS });
  res.end('Not Found');
});

server.listen(PORT, HOST, () => {
  if (process.argv.includes('--open')) {
    const url = `http://127.0.0.1:${PORT}`;
    const cmd = process.platform === 'win32'
      ? ['cmd', '/c', 'start', '', url]
      : process.platform === 'darwin' ? ['open', url] : ['xdg-open', url];
    try { spawn(cmd[0], cmd.slice(1), { detached: true, stdio: 'ignore' }).unref(); } catch { /* ignore */ }
  }
  console.log('');
  console.log('  WorkBuddy 状态监控已启动');
  console.log('  仪表盘   →  http://127.0.0.1:' + PORT);
  console.log('  状态流   →  http://127.0.0.1:' + PORT + '/events');
  console.log('  HoloCubic → http://' + HOST + ':' + PORT + '/api/holo');
  console.log('  项目列表 →  http://127.0.0.1:' + PORT + '/api/projects');
  console.log('  监听目录 →  ' + PROJECTS);
  console.log('');
});
