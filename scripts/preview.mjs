#!/usr/bin/env node
/* preview.mjs —— 离线预览：在 Node 里用 fengari(Lua 5.3) 跑 grok_bot 的真实渲染代码，
 * 由 scripts/preview_canvas.lua 提供的打桩 canvas 光栅化到 320x240 位图，导出 PNG。
 *
 *   npm install fengari          # 一次性
 *   node scripts/preview.mjs --emotion=02 --frames=150 --out=preview.png
 *
 * 用途：在没有板子的情况下检查构图、球缘/眼睛锯齿、渐变分层等问题。
 * 位图是 1:1 的 320x240（不做超采样），所以看到的就是设备上的实际观感。
 */
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { lua, lauxlib, lualib, to_luastring } from 'fengari';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const PKG = path.join(ROOT, 'package');

const args = {};
for (const a of process.argv.slice(2)) {
  const m = /^--([^=]+)=?(.*)$/.exec(a);
  if (m) args[m[1]] = m[2];
}

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function fail(L, where) {
  const msg = toJs(lua.lua_tostring(L, -1));
  throw new Error(`${where}: ${msg}`);
}

function toJs(v) {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  return Buffer.from(v).toString('utf8');
}

/* 加载一个 Lua 文件，把它的返回值注册成全局变量 */
function loadAs(file, globalName) {
  const src = fs.readFileSync(file, 'utf8');
  if (lauxlib.luaL_loadstring(L, to_luastring(src, true)) !== lua.LUA_OK) fail(L, file);
  const ok = lua.lua_pcall(L, 0, 1, 0);
  if (ok !== lua.LUA_OK) fail(L, file);
  if (globalName) lua.lua_setglobal(L, to_luastring(globalName));
  else lua.lua_pop(L, 1);
}

/* 位图：读 Lua 里的 PREVIEW.fb（1..W*H，0xRRGGBB） */
function readFramebuffer() {
  lua.lua_getglobal(L, to_luastring('PREVIEW'));
  lua.lua_getfield(L, -1, to_luastring('fb'));
  const W = 320, H = 240;
  const fbIdx = lua.lua_gettop(L);
  const raw = Buffer.alloc(H * (1 + W * 3));
  for (let y = 0; y < H; y++) {
    const rowStart = y * (1 + W * 3);
    raw[rowStart] = 0;
    for (let x = 0; x < W; x++) {
      lua.lua_rawgeti(L, fbIdx, y * W + x + 1);
      const c = lua.lua_tonumber(L, -1) | 0;
      lua.lua_pop(L, 1);
      const o = rowStart + 1 + x * 3;
      raw[o] = (c >> 16) & 0xff;
      raw[o + 1] = (c >> 8) & 0xff;
      raw[o + 2] = c & 0xff;
    }
  }
  lua.lua_pop(L, 2);
  return raw;
}

/* 极简 PNG 编码（RGB8，无滤波） */
const crcTable = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function writePng(file, raw, w, h) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
  fs.writeFileSync(file, png);
  return png.length;
}

/* ---------------- 装配 ---------------- */
const W = 320, H = 240;
const tourMode = args.tour !== undefined;

loadAs(path.join(HERE, 'preview_canvas.lua'));

if (tourMode) {
  /* 巡演模拟不需要像素：摘掉 canvas 绘制接口，Ball:render 会直接返回 */
  for (const name of ['lv_canvas_draw_rect', 'lv_canvas_draw_line', 'lv_canvas_draw_arc',
    'lv_canvas_draw_text', 'lv_canvas_fill_bg', 'lv_canvas_set_px_color']) {
    lua.lua_pushnil(L);
    lua.lua_setglobal(L, to_luastring(name));
  }
}

loadAs(path.join(PKG, 'grok_data.lua'), 'GROK_DATA');
loadAs(path.join(PKG, 'grok_ball.lua'), 'GROK_BALL');
loadAs(path.join(PKG, 'grok_engine.lua'), 'GROK_ENGINE');
loadAs(path.join(PKG, 'config.lua'), 'GROK_CONFIG');

lua.lua_newtable(L);
const setField = (k, v) => {
  if (typeof v === 'number') lua.lua_pushnumber(L, v);
  else lua.lua_pushstring(L, to_luastring(String(v)));
  lua.lua_setfield(L, -2, to_luastring(k));
};
setField('emotion', args.emotion || '02');
setField('frames', Number(args.frames || 150));
setField('dt', Number(args.dt || 33));
if (args.action) setField('action', args.action);
if (args.at) setField('at', Number(args.at));
if (args.aa !== undefined) setField('aa', Number(args.aa));
if (tourMode) {
  setField('seconds', Number(args.tour));
  setField('main_source', fs.readFileSync(path.join(PKG, 'main.lua'), 'utf8'));
}
lua.lua_setglobal(L, to_luastring('PREVIEW_ARGS'));

if (tourMode) {
  loadAs(path.join(HERE, 'tour_driver.lua'));
  lua.lua_getglobal(L, to_luastring('PREVIEW'));
  lua.lua_getfield(L, -1, to_luastring('tour_log'));
  const log = toJs(lua.lua_tostring(L, -1));
  lua.lua_getfield(L, -2, to_luastring('tour_count'));
  const count = lua.lua_tonumber(L, -1);
  console.log(`tour ${args.tour}s: ${count} 次切换`);
  console.log(log.replace(/ /g, '  '));
  process.exit(0);
}
loadAs(path.join(HERE, 'preview_driver.lua'));

const raw = readFramebuffer();
const out = args.out ? path.resolve(args.out) : path.join(ROOT, 'preview.png');
const bytes = writePng(out, raw, W, H);

lua.lua_getglobal(L, to_luastring('PREVIEW'));
lua.lua_getfield(L, -1, to_luastring('px_calls'));
const pxCalls = lua.lua_tonumber(L, -1);
lua.lua_getfield(L, -2, to_luastring('emotion'));
const emo = toJs(lua.lua_tostring(L, -1));
lua.lua_getfield(L, -3, to_luastring('dbg'));
const dbg = toJs(lua.lua_tostring(L, -1));

console.log(`emotion=${emo} -> ${out} (${(bytes / 1024).toFixed(1)} KB) set_px=${pxCalls}`);
if (dbg) console.log(dbg);
