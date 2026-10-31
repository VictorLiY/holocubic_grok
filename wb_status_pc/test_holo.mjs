/**
 * test_holo.mjs —— monitor-server /api/holo 端点与状态机联动测试
 *
 * 用法：node test_holo.mjs
 * 做法：临时 HOME 里伪造 ~/.workbuddy/projects/<proj>/<sid>.jsonl 轨迹，
 * 启动子进程 monitor-server（随机端口），按剧本追加轨迹记录、POST 覆盖，
 * 断言 /api/holo 的紧凑输出与状态推导，并回归检查 /api/state。
 */
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(HERE, 'monitor-server.mjs');

function mkFixture() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'wbholo-'));
  const proj = path.join(home, '.workbuddy', 'projects', 'demo-proj');
  fs.mkdirSync(proj, { recursive: true });
  const sid = 'sess-a1';
  const file = path.join(proj, sid + '.jsonl');
  const now = Date.now();
  fs.writeFileSync(file, JSON.stringify({
    type: 'message', role: 'user', timestamp: now, sessionId: sid,
    content: [{ type: 'input_text', text: '请帮我重构 main.lua' }],
  }) + '\n', 'utf8');
  return { home, proj, sid, file };
}

function startServer(home, port) {
  const child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, HOME: home, USERPROFILE: home, PORT: String(port), HOST: '127.0.0.1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write('[server] ' + d));
  return child;
}

async function waitReady(port, timeoutMs = 5000) {
  const t0 = Date.now();
  for (;;) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (r.ok) return;
    } catch { /* retry */ }
    if (Date.now() - t0 > timeoutMs) throw new Error('server not ready');
    await new Promise((r) => setTimeout(r, 100));
  }
}

async function holo(port) {
  const r = await fetch(`http://127.0.0.1:${port}/api/holo`);
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type') || '', /json/);
  return r.json();
}

/* 轮询直到 /api/holo 满足谓词（服务端 pump 是 400ms 周期，首拍有延迟） */
async function waitHolo(port, pred, timeoutMs = 5000) {
  const t0 = Date.now();
  for (;;) {
    const h = await holo(port);
    if (pred(h)) return h;
    if (Date.now() - t0 > timeoutMs) throw new Error('waitHolo timeout: ' + JSON.stringify(h));
    await sleep(150);
  }
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

test('/api/holo tracks trace state and manual override', async () => {
  const fx = mkFixture();
  const port = 18800 + Math.floor(Math.random() * 1000);
  const child = startServer(fx.home, port);
  try {
    await waitReady(port);

    // 1) 初始：用户消息 → thinking（等首轮 pump 消化轨迹）
    let h = await waitHolo(port, (x) => x.status === 'thinking');
    assert.equal(h.sessionId, fx.sid);
    assert.equal(h.project, 'demo-proj');
    assert.ok(typeof h.v === 'number');
    assert.ok(typeof h.statusSince === 'number');
    const v0 = h.v;

    // 2) 追加 reasoning 记录 → 仍 thinking，v 增长（仅刷新 detail）
    fs.appendFileSync(fx.file, JSON.stringify({
      type: 'reasoning', timestamp: Date.now(), sessionId: fx.sid,
      rawContent: [{ type: 'reasoning_text', text: '先分析依赖关系…' }],
    }) + '\n', 'utf8');
    await sleep(800);
    h = await holo(port);
    assert.equal(h.status, 'thinking');
    assert.ok(h.v > v0);
    assert.ok(h.detail.includes('先分析'), 'detail 应带推理文本: ' + h.detail);

    // 3) 追加 function_call → working
    fs.appendFileSync(fx.file, JSON.stringify({
      type: 'function_call', timestamp: Date.now(), sessionId: fx.sid,
      name: 'Edit', arguments: { file_path: 'D:/w/main.lua' },
    }) + '\n', 'utf8');
    await sleep(800);
    h = await holo(port);
    assert.equal(h.status, 'working');
    assert.ok(h.detail.includes('编辑文件'), 'detail 应带工具中文名: ' + h.detail);

    // 4) POST /api/state 手动覆盖 → standby（60s 内生效）
    let r = await fetch(`http://127.0.0.1:${port}/api/state`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: 'standby', detail: '遥控测试' }),
    });
    assert.equal((await r.json()).ok, true);
    h = await holo(port);
    assert.equal(h.status, 'standby');
    assert.equal(h.detail, '遥控测试');

    // 5) 清除覆盖后，追加失败的 function_call_result → error
    //    （覆盖在 60s 窗口内优先于轨迹状态，须先 clear 才能看到轨迹推导）
    await fetch(`http://127.0.0.1:${port}/api/state`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ clear: true }),
    });
    fs.appendFileSync(fx.file, JSON.stringify({
      type: 'function_call_result', timestamp: Date.now(), sessionId: fx.sid,
      name: 'Bash', status: 'error',
    }) + '\n', 'utf8');
    h = await waitHolo(port, (x) => x.status === 'error');
    assert.ok(h.detail.includes('执行失败'), 'error detail: ' + h.detail);

    // 6) 回归：/api/state 全量快照仍可用且包含 events
    const r2 = await fetch(`http://127.0.0.1:${port}/api/state`);
    const doc = await r2.json();
    assert.equal(doc.status, 'error');
    assert.ok(Array.isArray(doc.events) && doc.events.length > 0);
    assert.ok(doc.project && doc.project.name === 'demo-proj');
  } finally {
    child.kill('SIGTERM');
    fs.rmSync(fx.home, { recursive: true, force: true });
  }
});

test('/api/holo payload stays compact', async () => {
  const fx = mkFixture();
  const port = 18800 + Math.floor(Math.random() * 1000);
  const child = startServer(fx.home, port);
  try {
    await waitReady(port);
    const r = await fetch(`http://127.0.0.1:${port}/api/holo`);
    const text = await r.text();
    assert.ok(text.length < 600, '/api/holo 载荷应 <600B，实际 ' + text.length);
    assert.ok(!text.includes('"events"'), '紧凑载荷不应包含 events 数组');
    assert.ok(!text.includes('"projects"'), '紧凑载荷不应包含 projects 数组');
  } finally {
    child.kill('SIGTERM');
    fs.rmSync(fx.home, { recursive: true, force: true });
  }
});
