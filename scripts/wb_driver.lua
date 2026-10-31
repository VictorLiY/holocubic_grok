-- wb_driver.lua —— WorkBuddy 状态机离线回归：跑真正的 main.lua + wb_status.lua
--
-- 由 scripts/preview.mjs --wb=<秒> 加载。canvas 绘制接口已摘掉（Ball:render
-- 直接返回），只验证调度链路：http.get 打桩 → wb_status 状态机 → 表情应用
-- → 巡演挂起/恢复 → HUD。时间轴剧本见 script()。
-- 结果写 PREVIEW.wb_report / PREVIEW.wb_pass。

local PKG = PREVIEW_ARGS.pkg or "/sd/apps/grok_bot"

-- main.lua 用 dofile(APP_DIR .. "/xxx.lua") 加载同目录模块，映射到已加载副本
local modules = {
  ["grok_data.lua"] = GROK_DATA,
  ["grok_ball.lua"] = GROK_BALL,
  ["grok_engine.lua"] = GROK_ENGINE,
  ["config.lua"] = GROK_CONFIG,
  ["wb_status.lua"] = WB_STATUS,
}

function dofile(path)
  local name = tostring(path):match("([^/]+)$")
  local mod = modules[name]
  if mod == nil then error("unexpected dofile: " .. tostring(path)) end
  return mod
end

-- ---------------------------------------------------------------- http 打桩
--
-- 按模拟时刻出数（不按调用序号，时钟跳跃后依然自洽）。
-- 响应在下一个调度步送达（模拟网络往返）。

local function holo(status, detail, v, session, project)
  return {
    code = 200,
    body = string.format(
      '{"v":%d,"status":"%s","detail":"%s","statusSince":1700000000000,'
      .. '"lastEventTs":0,"sessionId":"%s","project":"%s","model":"test"}',
      v, status, detail or "", session or "s1", project or "demo"),
  }
end

-- 时间轴剧本（t = 模拟毫秒）：
--   0-2s   thinking（v1→v2：第二拍只刷 detail）
--   2-4s   working（v3 → 32+spin；v4 detail 命中"搜索"→ 40）
--   4-13s  standby（v5：working→standby 闪现 33 → 落 35；之后周期弹跳）
--   13-14s error（v6 → 34）
--   14-18s idle（v7 → 02）
--   18-30s 三连失败 → offline（36，释放巡演；25.2s 巡演恢复推进一格）
--   32s    thinking v9 新会话 s2 → 会话闪现 31 → 落 30
--   34-40s idle v10/v11 → 02（v 变化只刷 HUD）
--   40s 后 idle + 时钟跳跃 → 休眠梯度 06 → 00
local function script(t)
  if t < 2000 then return holo("thinking", "先分析依赖", t < 1000 and 1 or 2, "s1") end
  if t < 4000 then
    if t < 3000 then return holo("working", "编辑文件 · main.lua", 3, "s1") end
    return holo("working", "搜索内容 · pattern", 4, "s1")
  end
  if t < 13000 then return holo("standby", "回复完成", 5, "s1") end
  if t < 14000 then return holo("error", "Bash 执行失败", 6, "s1") end
  if t < 18000 then return holo("idle", "", 7, "s1") end
  if t < 32000 then return { code = 0, body = nil } end
  if t < 34000 then return holo("thinking", "新会话新指令", 9, "s2") end
  if t < 40000 then return holo("idle", "", 10, "s2") end
  return holo("idle", "", 11, "s2")
end

local PV = PREVIEW
PV.http_calls = 0
PV.http_pending = nil

http = {
  get = function(url, opts, cb)
    PV.http_calls = PV.http_calls + 1
    PV.http_last_url = tostring(url)
    PV.http_pending = { cb = cb, resp = script(PV.clock) }
  end,
}

local function fire_http()
  if PV.http_pending then
    local p = PV.http_pending
    PV.http_pending = nil
    p.cb(p.resp.code, p.resp.body)
  end
end

-- ---------------------------------------------------------------- 跑 main.lua

local src = PREVIEW_ARGS.main_source
assert(load(src, "main.lua"))()

local APP = _G.__grok_bot
assert(APP, "main.lua 未注册 __grok_bot")
assert(APP.wb, "wb_status 未初始化（http 打桩未生效？）")

local STEP = 50                 -- 模拟步长 ms
local total_ms = math.floor((PREVIEW_ARGS.seconds or 45) * 1000)
local deadline = total_ms

local sampled_tour_idx_24, sampled_tour_idx_28
local jumped_1, jumped_2

while PV.clock < deadline do
  PV.step_time(STEP)
  fire_http()

  -- offline 期间巡演应恢复推进：25.2s 会 step 一次，前后游标应不同
  if not sampled_tour_idx_24 and PV.clock >= 24000 then
    sampled_tour_idx_24 = APP.tour_idx
  end
  if not sampled_tour_idx_28 and PV.clock >= 28500 then
    sampled_tour_idx_28 = APP.tour_idx
  end

  -- idle 休眠梯度：时钟跳跃（+121s → 06；再 +185s → 00）
  -- 跳跃同时顺延 deadline，保证跳跃后还有仿真步触发轮询与梯度
  if not jumped_1 and PV.clock >= 40000 then
    jumped_1 = true
    PV.clock = PV.clock + 121000
    deadline = deadline + 121000
  elseif jumped_1 and not jumped_2 and PV.clock >= 165000 then
    jumped_2 = true
    PV.clock = PV.clock + 185000
    deadline = deadline + 185000
  end
end

-- ---------------------------------------------------------------- 断言

local fails = {}
local function check(cond, msg)
  if cond then return end
  fails[#fails + 1] = msg
end

-- 表情应用轨迹（wb_trace 由 main.lua 在 PREVIEW 环境自动记录）
local trace = APP.wb_trace or {}
local expect_emo = { "30", "32", "40", "33", "35", "34", "02", "36", "31", "30", "02", "06", "00" }
for i, e in ipairs(expect_emo) do
  local got = trace[i] and trace[i]:match("^(%w+)@")
  check(got == e, string.format("trace[%d] 期望 %s，实际 %s (%s)", i, e, tostring(got), tostring(trace[i])))
end
check(#trace == #expect_emo, "轨迹条数 " .. #trace .. " ≠ " .. #expect_emo
  .. "：" .. table.concat(trace, " "))

-- 巡演挂起/恢复：offline 后（25.2s）巡演推进过一格
check(sampled_tour_idx_24 and sampled_tour_idx_28
  and sampled_tour_idx_24 ~= sampled_tour_idx_28,
  "offline 期间巡演未恢复（tour_idx " .. tostring(sampled_tour_idx_24)
  .. " → " .. tostring(sampled_tour_idx_28) .. "）")
check(APP.wb_active, "结束时状态层应接管（wb_active=true）")

-- wb 实例终态：idle 睡眠、在线、持巡演
local wb = APP.wb
check(wb.status == "idle", "终态 status=" .. tostring(wb.status))
check(wb.idle_stage == 2, "idle 梯度应到 stage2(00)，实际 " .. tostring(wb.idle_stage))
check(wb.online, "终态应在线")
check(wb.hold_on, "终态应挂起巡演")

-- 轮询健康：http 打桩被调用过，URL 正确
-- （次数 < 仿真秒数是正常的：offline 退避把间隔拉长到 2s/5s）
check(PV.http_calls > 30, "http 轮询次数异常：" .. tostring(PV.http_calls))
check(PV.http_last_url == "http://192.168.0.112:8788/api/holo",
  "轮询 URL 异常：" .. tostring(PV.http_last_url))

-- HUD：状态文案出现过（label 历史）
local label_blob = table.concat(PV.labels, "\n")
for _, kw in ipairs({ "done", "ready", "error", "idle", "zzz" }) do
  check(label_blob:find(kw, 1, true), "HUD 缺少关键词 " .. kw)
end

-- ---------------------------------------------------------------- 报告

local lines = {}
lines[#lines + 1] = string.format("wb 状态机回归：trace %d 步，http 轮询 %d 次",
  #trace, PV.http_calls)
lines[#lines + 1] = "trace: " .. table.concat(trace, "  ")
if #fails == 0 then
  lines[#lines + 1] = "PASS"
  PV.wb_pass = true
else
  for _, m in ipairs(fails) do lines[#lines + 1] = "FAIL: " .. m end
  PV.wb_pass = false
end
PV.wb_report = table.concat(lines, "\n")
