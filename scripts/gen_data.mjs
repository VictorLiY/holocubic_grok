#!/usr/bin/env node
/* 从 grok-ball 的 grok-ball.js 中抽取 data 层（EB_RINGS / EMOTION_SEED），
 * 生成 HoloCubic 的 Lua 数据模块 package/grok_data.lua。
 *
 * 只取纯数据段（第 1..DATA_END 行），不加载渲染器与驱动，避免依赖 DOM。
 * 用法： node scripts/gen_data.mjs [../grok-ball/src/grok-ball.js]
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PKG = path.resolve(HERE, '..', 'package');
const SRC = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.resolve(HERE, '..', '..', '..', 'grok-ball', 'src', 'grok-ball.js');

const source = fs.readFileSync(SRC, 'utf8');
const allLines = source.split(/\r?\n/);

/* 数据段只到这里为止：紧接着就是渲染器 IIFE（会引用 DOM） */
const rendererLine = allLines.findIndex((line) => line.trim() === '(function () {');
if (rendererLine < 0) throw new Error('找不到渲染器起始位置');
const dataCode = allLines.slice(0, rendererLine).join('\n');

const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(dataCode, sandbox, { filename: 'grok-data.js' });

const RINGS = sandbox.window.EB_RINGS;
const SEED = sandbox.window.EMOTION_SEED;
const GROUPS = sandbox.window.EMOTION_GROUPS || [];
if (!RINGS || !Array.isArray(RINGS.EXPRESSIONS)) throw new Error('EB_RINGS 解析失败');
if (!Array.isArray(SEED)) throw new Error('EMOTION_SEED 解析失败');

/* ---------------- JS 值 -> Lua 字面量 ---------------- */

const num = (v) => {
  if (!Number.isFinite(v)) return '0';
  const r = Math.round(v * 1000) / 1000;
  return Number.isInteger(r) ? String(r) : String(r);
};
const KEY_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

function toLua(value) {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'number') return num(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) {
    /* 纯数字数组写成紧凑形式，便于阅读与压缩体积 */
    if (value.every((v) => typeof v === 'number')) {
      return '{' + value.map(num).join(',') + '}';
    }
    return '{' + value.map(toLua).join(',') + '}';
  }
  const parts = [];
  for (const [k, v] of Object.entries(value)) {
    if (v === undefined) continue;
    const key = KEY_RE.test(k) ? k : '[' + JSON.stringify(k) + ']';
    parts.push(key + '=' + toLua(v));
  }
  return '{' + parts.join(',') + '}';
}

/* 情绪只保留引擎会消费的字段 */
const EMOTION_KEYS = [
  'id', 'name', 'group', 'gaze', 'transition',
  'pool', 'poolMs', 'poolSpeed', 'blinkMs', 'openness', 'antics',
  'body', 'eyes', 'anims', 'sequence',
];

const out = [];
out.push('-- 由 scripts/gen_data.mjs 自动生成，请勿手改。');
out.push('-- 数据来源：grok-ball/src/grok-ball.js（MIT License）');
out.push('-- RINGS: 25 组表情眼环，每组 {左眼环, 右眼环}，各 48 点，扁平 x,y 数组');
out.push('-- 坐标系：viewBox -15 -15 259 259，头部中心 HEAD_C');
out.push('return {');
out.push('  HEAD_C = ' + num(RINGS.HEAD_C) + ',');
out.push('  EYE_HALF = ' + num(RINGS.EYE_HALF) + ',');

const blob = RINGS.SHAPES && RINGS.SHAPES.blob;
if (blob && blob.face) out.push('  FACE = ' + toLua(blob.face) + ',');
else out.push('  FACE = {x=0,y=0,sx=0.89,sy=0.89,eye=0.99},');

out.push('');
out.push('  RINGS = {');
for (const pair of RINGS.EXPRESSIONS) {
  const left = pair[0].flat();
  const right = pair[1].flat();
  out.push('    {' + toLua(left) + ',');
  out.push('     ' + toLua(right) + '},');
}
out.push('  },');

out.push('');
out.push('  GROUPS = ' + toLua(GROUPS) + ',');

out.push('');
out.push('  EMOTIONS = {');
for (const raw of SEED) {
  const keep = {};
  for (const k of EMOTION_KEYS) if (raw[k] !== undefined) keep[k] = raw[k];
  /* JS 是 0 基索引，Lua 侧统一 1 基 */
  if (keep.pool) keep.pool = keep.pool.map((i) => i + 1);
  out.push('    ' + toLua(keep) + ',');
}
out.push('  },');
out.push('}');
out.push('');

fs.mkdirSync(PKG, { recursive: true });
const target = path.join(PKG, 'grok_data.lua');
fs.writeFileSync(target, out.join('\n'), 'utf8');

const kb = (fs.statSync(target).size / 1024).toFixed(1);
console.log(`rings=${RINGS.EXPRESSIONS.length} emotions=${SEED.length} -> ${target} (${kb} KB)`);
