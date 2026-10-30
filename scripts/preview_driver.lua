-- preview_driver.lua —— 离线预览的驱动脚本
--
-- 由 scripts/preview.mjs 加载：复用 package/ 里真正的 Ball / Engine，
-- 只把 canvas 换成 scripts/preview_canvas.lua 的打桩实现。
-- 参数通过全局 PREVIEW_ARGS 传入。

local cfg = GROK_CONFIG or {}
local D, Ball, Engine = GROK_DATA, GROK_BALL, GROK_ENGINE

local cvs = lv_canvas_create(0, PREVIEW.W, PREVIEW.H, LV_IMG_CF_TRUE_COLOR)

-- --aa=0/1 可临时覆盖 config.antialias，用来对比抗锯齿开关的效果
local aa = cfg.antialias
if PREVIEW_ARGS.aa ~= nil then aa = PREVIEW_ARGS.aa == 1 end

local ball = Ball.new(cvs, D, {
  cx = cfg.cx or 160,
  cy = cfg.cy or 116,
  radius = cfg.radius or 96,
  bg = cfg.bg or 0x0B0C10,
  antialias = aa,
})

local engine = Engine.new(D, {
  emotion = PREVIEW_ARGS.emotion,
  fallback = cfg.fallback_emotion or "02",
  seed = 0,
  bounce_scale = cfg.bounce_scale or Ball.bounce_scale(D, cfg.radius or 96, cfg.cy or 116),
})

local now = 0
local dt = PREVIEW_ARGS.dt or 33
for f = 1, (PREVIEW_ARGS.frames or 90) do
  -- 在指定帧插入一次动作，便于抓极端姿态（自旋中 / 弹跳最高点）
  if PREVIEW_ARGS.action and f == (PREVIEW_ARGS.at or 1) then
    if PREVIEW_ARGS.action == "spin" then
      engine:spin(1)
    elseif PREVIEW_ARGS.action == "bounce" then
      engine:bounce()
    end
  end
  now = now + dt
  local pose = engine:tick(now)
  local burst = engine:take_burst()
  if burst > 0 then ball:burst(burst) end
  ball:render(pose, now, engine._dt)
end

PREVIEW.emotion = engine:emotion_id()
PREVIEW.prof = ball:take_prof()

local pose = engine._pose
local function centroid(ring)
  if not ring then return 0, 0 end
  local sx, sy, n = 0, 0, #ring // 2
  for i = 1, n * 2, 2 do
    sx, sy = sx + ring[i], sy + ring[i + 1]
  end
  return sx / n, sy / n
end
local lx, ly = centroid(pose.ringL)
local rx, ry = centroid(pose.ringR)
PREVIEW.dbg = string.format(
  "id=%s openL=%.2f openR=%.2f scaleL=%.2f,%.2f scaleR=%.2f,%.2f yL=%.1f yR=%.1f lookL=%.1f,%.1f lookR=%.1f,%.1f ring=%.1f,%.1f/%.1f,%.1f body=%.2f,%.2f,%.2f col=%s",
  tostring(engine:emotion_id()), pose.left.open, pose.right.open,
  pose.left.scaleX, pose.left.scaleY, pose.right.scaleX, pose.right.scaleY,
  pose.left.y, pose.right.y, pose.left.lookX, pose.left.lookY, pose.right.lookX, pose.right.lookY,
  lx, ly, rx, ry, pose.body.x, pose.body.y, pose.body.scale, tostring(pose.body.color))
