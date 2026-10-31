-- wb_status.lua —— WorkBuddy 状态联动：轮询 monitor-server 的 /api/holo
--
-- 设计文档：grok.bot.status.md（§4 状态集与映射、§5.2 设设备侧模块）
-- 职责边界：
--   本模块 = HTTP 轮询 + 解析 + 去重 + 离线退避 + 状态→表情映射/跃迁闪现/周期提醒；
--   表情应用（engine:set_emotion / spin / bounce / HUD / 巡演挂起）由 main.lua
--   通过回调完成，本模块不触碰 LVGL 与 engine。
-- 降级：host 为空 / http 缺失 → init() 返回 nil，app 保持纯动画行为。
--
-- 线协议（GET /api/holo，紧凑 JSON）：
--   {"v":42,"status":"working","detail":"...","statusSince":...,
--    "lastEventTs":...,"sessionId":"...","project":"...","model":"..."}
--   status ∈ idle | thinking | working | standby | error；offline 为本端合成。

local WB = {}

-- ---------------------------------------------------------------- 映射表

-- 状态 → 表情头像（可被 config.wb_status.map 按 status 覆盖 emo）
WB.MAP = {
  idle     = { emo = "02", hud = "idle" },                              -- 待机放空
  thinking = { emo = "30", hud = "think" },                             -- 思考中
  working  = { emo = "32", hud = "run",  spin = true },                 -- 处理中忙碌
  standby  = { emo = "35", hud = "ready", bounce = true, color = 0xE8B14A }, -- 等待输入
  error    = { emo = "34", hud = "error", color = 0xC0392B, spin = true },  -- 出错
  offline  = { emo = "36", hud = "--" },                                -- 联网加载（仅首次失败闪现）
}

-- working 状态下按 detail 关键字细分表情（匹配 monitor 的 TOOL_LABEL 中文文案）
WB.WORK_KW = {
  { kw = "检索",     emo = "40", hud = "search" },  -- 检索资料
  { kw = "搜索",     emo = "40", hud = "search" },
  { kw = "抓取",     emo = "40", hud = "fetch" },
  { kw = "规划任务", emo = "30", hud = "plan" },
  { kw = "更新任务", emo = "30", hud = "plan" },
  { kw = "派发",     emo = "31", hud = "agent" },   -- 接收任务
}

-- 跃迁闪现：{from, to} → 闪现表情 / 时长 / 动效 / HUD
WB.TRANSITIONS = {
  -- 一轮活干完：撒彩带庆祝（33 自带 confetti），然后落到"等待输入"
  { from = "working", to = "standby", flash = "33", ms = 2500, bounce = true, hud = "done" },
}

-- 会话切换闪现（sessionId 变化 = 新会话/新指令到达）
WB.SESSION_FLASH_EMO = "31"
WB.SESSION_FLASH_MS = 1500

WB.FALLBACK_STATUS = "working" -- 未知 status 的回退语义："它在忙"

WB.IDLE_SLEEP1_MS = 120000    -- idle → 06 休眠
WB.IDLE_SLEEP2_MS = 300000    -- idle → 00 睡眠
WB.STANDBY_REMIND_MS = 8000   -- standby 周期弹跳
WB.FAIL_LIMIT = 3             -- 连续失败 N 次 → offline
WB.BACKOFF = { 1, 2, 5 }      -- 轮询退避系数

-- ---------------------------------------------------------------- 小工具

local function now_ms()
  if millis then return millis() end
  return os.time() * 1000
end

-- HUD 文本安全化：剥离非 ASCII（LVGL 默认字体无 CJK 字形），压缩空白，限长
local function ascii_safe(s, n)
  s = tostring(s or ""):gsub("[\1-\31\127-\255]", " ")
  s = (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
  if #s > n then s = s:sub(1, n - 1) .. "." end
  return s
end

local function json_str(raw, name)
  return (tostring(raw):match('"' .. name .. '"%s*:%s*"([^"]*)"'))
end

local function json_num(raw, name)
  return tonumber(tostring(raw):match('"' .. name .. '"%s*:%s*(-?%d+%.?%d*)'))
end

-- 解析 /api/holo：优先 sjson，宿主缺失时用固定字段模式抽取
-- （xiaozhi protocol.lua 的兜底套路；本协议扁平、字段名固定，可靠）
local function parse_payload(body)
  local ok, obj = false, nil
  if sjson and sjson.decode then
    ok, obj = pcall(sjson.decode, body)
  end
  if ok and type(obj) == "table" then
    return {
      status  = tostring(obj.status or ""),
      detail  = tostring(obj.detail or ""),
      v       = tonumber(obj.v) or 0,
      session = tostring(obj.sessionId or ""),
      project = tostring(obj.project or ""),
    }
  end
  return {
    status  = json_str(body, "status") or "",
    detail  = json_str(body, "detail") or "",
    v       = json_num(body, "v") or 0,
    session = json_str(body, "sessionId") or "",
    project = json_str(body, "project") or "",
  }
end

local function entry_fx(e)
  if e.spin then return "spin" end
  if e.bounce then return "bounce" end
  return nil
end

-- ---------------------------------------------------------------- 实例

function WB.init(cfg, cb)
  cfg = cfg or {}
  cb = cb or {}
  if not cfg.host or cfg.host == "" then return nil end
  if not http or not http.get then return nil end

  local self = setmetatable({}, { __index = WB })
  self.cb = cb
  self.cfg = cfg
  self.dead = false
  self.online = false
  self.busy = false
  self.gen = 0
  self.fails = 0
  self.bo_i = 1
  self.next_poll = 0
  self.timeout_ms = cfg.timeout_ms or 3000
  self.poll_ms = cfg.poll_ms or 1000
  self.idle_tour = cfg.idle_tour and true or false
  self.url = "http://" .. tostring(cfg.host) .. ":" .. tostring(cfg.port or 8787)
    .. (cfg.path or "/api/holo")

  -- 映射表实例化（浅拷贝 + config 覆盖 emo）
  self.map = {}
  for k, e in pairs(WB.MAP) do
    self.map[k] = { emo = e.emo, hud = e.hud, spin = e.spin, bounce = e.bounce, color = e.color }
  end
  if type(cfg.map) == "table" then
    for k, id in pairs(cfg.map) do
      if self.map[k] then self.map[k].emo = tostring(id) end
    end
  end

  self.timer = tmr.create()
  self.timer:alarm(self.poll_ms, tmr.ALARM_AUTO, function()
    local ok, err = pcall(function() self:_poll_tick() end)
    if not ok and cb.log then pcall(cb.log, "poll error: " .. tostring(err)) end
  end)
  -- 启动立即发首拍，不必干等 1s
  local ok, err = pcall(function() self:_poll_tick() end)
  if not ok and cb.log then pcall(cb.log, "first poll error: " .. tostring(err)) end
  return self
end

function WB.shutdown()
  self.dead = true
  self.gen = self.gen + 1
  self:_cancel_flash()
  if self.timer then
    pcall(function() self.timer:unregister() end)
    self.timer = nil
  end
end

-- ---------------------------------------------------------------- 状态推导

function WB:_entry_for(status, detail)
  local e = self.map[status] or self.map[WB.FALLBACK_STATUS]
  if status == "working" and type(detail) == "string" then
    for _, kw in ipairs(WB.WORK_KW) do
      if detail:find(kw.kw, 1, true) then
        return { emo = kw.emo, hud = kw.hud }
      end
    end
  end
  return e
end

function WB:_hud_text(e, detail, project)
  local t = e.hud or ""
  if self.status == "idle" then
    if self.idle_stage == 2 then
      t = "zzz"
    elseif self.idle_stage == 1 then
      t = "idle 2m+"
    elseif project and project ~= "" then
      t = "idle " .. ascii_safe(project, 10)
    end
  elseif detail and detail ~= "" then
    t = t .. " " .. ascii_safe(detail, 16)
  end
  return t, e.color
end

function WB:_apply_entry()
  local e = self.entry
  if not e then return end
  local p = self.last_p or {}
  self.cur_emo = e.emo
  if self.cb.apply then
    self.cb.apply(e.emo, entry_fx(e))
  end
  if self.cb.hud then
    local text, color = self:_hud_text(e, self.detail, p.project)
    self.cb.hud(text, color)
  end
end

function WB:_refresh_hud()
  if not self.cb.hud or not self.entry then return end
  local p = self.last_p or {}
  local text, color = self:_hud_text(self.entry, self.detail, p.project)
  self.cb.hud(text, color)
end

function WB:_set_hold(on)
  if self.idle_tour and self.online and self.status == "idle" then on = false end
  if self.hold_on ~= on then
    self.hold_on = on
    if self.cb.hold then pcall(self.cb.hold, on) end
  end
end

function WB:_cancel_flash()
  if self.flash_tmr then
    pcall(function() self.flash_tmr:unregister() end)
    self.flash_tmr = nil
  end
  self.flash = nil
end

function WB:_start_flash(f)
  self:_cancel_flash()
  self.flash = f
  self.cur_emo = f.emo
  if self.cb.apply then self.cb.apply(f.emo, f.bounce and "bounce" or nil) end
  if self.cb.hud then
    self.cb.hud(f.hud or (self.entry and self.entry.hud) or "")
  end
  local t = tmr.create()
  self.flash_tmr = t
  t:alarm(f.ms or 2000, tmr.ALARM_SINGLE, function()
    if self.flash_tmr ~= t then return end
    self.flash_tmr = nil
    if self.dead or self.flash ~= f then return end
    self.flash = nil
    if self.paused and self.paused() then
      self.pending_apply = true
    else
      self:_apply_entry()
    end
  end)
end

-- 跃迁处理：闪现规则 → 应用表情 → 挂起巡演 → 日志
function WB:_transition(p, recovered)
  local prev = self.status
  -- 会话切换闪现：恢复连接时若 sessionId 已变（换会话干活）也要提示
  local session_changed = self.session ~= nil
    and p.session ~= "" and p.session ~= self.session

  self.status = p.status
  self.detail = p.detail
  self.v = p.v
  self.last_p = p
  if p.session ~= "" then self.session = p.session end

  if self.status == "idle" then
    self.idle_since = now_ms()
    self.idle_stage = 0
  else
    self.idle_stage = 0
  end

  self:_cancel_flash()
  self.entry = self:_entry_for(self.status, self.detail)

  -- 闪现优先级：会话切换 < 跃迁闪现（working→standby 的庆祝更具体）
  local flash = nil
  if session_changed then
    flash = { emo = WB.SESSION_FLASH_EMO, ms = WB.SESSION_FLASH_MS }
  end
  for _, tr in ipairs(WB.TRANSITIONS) do
    if tr.from == prev and tr.to == self.status then
      flash = { emo = tr.flash, ms = tr.ms, bounce = tr.bounce, hud = tr.hud }
    end
  end

  self:_set_hold(true)

  -- 有闪现时先播闪现（如 33 庆祝），落点回调再应用目标表情；
  -- 无闪现直接应用
  if self.paused and self.paused() then
    -- 用户手动看表情期间：只记录状态，解除后补播
    self.pending_apply = true
  elseif not flash then
    self:_apply_entry()
  end
  if flash then self:_start_flash(flash) end

  if self.cb.log then
    pcall(self.cb.log, string.format("status=%s%s emo=%s%s detail=%s",
      tostring(self.status), recovered and " (recovered)" or "",
      tostring(self.entry.emo),
      flash and ("+" .. tostring(flash.emo) .. " " .. tostring(flash.ms) .. "ms") or "",
      tostring(self.detail)))
  end
end

-- 每次成功轮询的持续期逻辑：补播 / idle 梯度 / standby 周期弹跳
function WB:_tick()
  if self.paused and self.paused() then return end
  if self.flash then return end  -- 闪现期间不做梯度/提醒，落点回调自己处理

  if self.pending_apply then
    self.pending_apply = nil
    self:_apply_entry()
    return
  end

  local now = now_ms()

  if self.status == "idle" and self.idle_since then
    local stage = 0
    local d = now - self.idle_since
    if d >= WB.IDLE_SLEEP2_MS then stage = 2
    elseif d >= WB.IDLE_SLEEP1_MS then stage = 1 end
    if stage ~= self.idle_stage then
      self.idle_stage = stage
      local emo = self.entry.emo
      if stage == 2 then emo = "00" elseif stage == 1 then emo = "06" end
      if emo ~= self.cur_emo then
        self.cur_emo = emo
        if self.cb.apply then self.cb.apply(emo, nil) end
        self:_refresh_hud()
      end
    end
  end

  if self.status == "standby"
    and (now - (self.last_remind or 0)) >= WB.STANDBY_REMIND_MS then
    self.last_remind = now
    if self.cb.fx then pcall(self.cb.fx, "bounce") end
  end
end

function WB:_go_offline()
  if not self.online then return end
  self.online = false
  self.status = "offline"
  self.entry = self.map.offline
  self:_cancel_flash()
  self:_set_hold(false)  -- 释放巡演
  if self.paused and self.paused() then
    self.pending_apply = true
  else
    self:_apply_entry()
  end
  if self.cb.log then pcall(self.cb.log, "offline after " .. tostring(self.fails) .. " fails") end
end

-- ---------------------------------------------------------------- 轮询

function WB:_on_fail()
  self.fails = self.fails + 1
  if self.fails >= WB.FAIL_LIMIT then
    self:_go_offline()
    local bo = WB.BACKOFF
    self.bo_i = math.min(self.bo_i + 1, #bo)
    self.next_poll = now_ms() + self.poll_ms * bo[self.bo_i]
  end
end

function WB:_on_response(code, body)
  if code ~= 200 or type(body) ~= "string" or #body == 0 then
    self:_on_fail()
    return
  end
  local ok, p = pcall(parse_payload, body)
  if not ok or type(p) ~= "table" or p.status == "" then
    self:_on_fail()
    return
  end

  self.fails = 0
  self.bo_i = 1

  if not self.online then
    self.online = true
    self:_transition(p, true)
  elseif p.status ~= self.status
    or (p.session ~= "" and p.session ~= self.session) then
    self:_transition(p, false)
  elseif (p.v or 0) ~= self.v or p.detail ~= self.detail then
    -- 事件计数或 detail 变化：刷新 HUD detail；
    -- 但 working 的关键词子表情（如"搜索"→40）也随 detail 变化切换
    -- （手动覆盖 POST /api/state 只改 detail 不改 v，故两者任一变化都要处理）
    self.v = p.v
    self.detail = p.detail
    self.last_p = p
    local new_entry = self:_entry_for(self.status, self.detail)
    if new_entry.emo ~= self.entry.emo then
      self.entry = new_entry
      if self.flash then
        -- 闪现期间只更新落点，不动当前表情
      elseif self.paused and self.paused() then
        self.pending_apply = true
      else
        self:_apply_entry()
      end
      if self.cb.log then
        pcall(self.cb.log, string.format("status=%s sub emo=%s detail=%s",
          tostring(self.status), tostring(new_entry.emo), tostring(self.detail)))
      end
    else
      self:_refresh_hud()
    end
  end
  self:_tick()
end

function WB:_poll_tick()
  if self.dead then return end
  local now = now_ms()
  if now < self.next_poll then return end
  if self.busy and (now - self.busy_at) < self.timeout_ms * 2 + 2000 then return end

  self.busy = true
  self.busy_at = now
  self.gen = self.gen + 1
  local gen = self.gen

  local ok, err = pcall(function()
    http.get(self.url, {
      timeout = self.timeout_ms,
      headers = { Accept = "application/json", ["Cache-Control"] = "no-cache" },
    }, function(code, body)
      if self.dead or gen ~= self.gen then return end
      self.busy = false
      local ok2, err2 = pcall(function() self:_on_response(code, body) end)
      if not ok2 and self.cb.log then pcall(self.cb.log, "resp error: " .. tostring(err2)) end
    end)
  end)
  if not ok then
    self.busy = false
    if self.cb.log then pcall(self.cb.log, "http error: " .. tostring(err)) end
    self:_on_fail()
  end
end

return WB
