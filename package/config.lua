-- Grok Bot 配置：改完直接重启 app 生效
return {
  -- 画面
  cx = 160,             -- 球心屏幕 X
  cy = 124,             -- 球心屏幕 Y（留出弹跳与底部文字空间）
  radius = 84,          -- 球半径（像素）
  bg = 0x0B0C10,        -- 背景色
  interval = 33,        -- 重绘间隔 ms（实测 33ms ≈ 30fps，单帧占用约 17ms）

  -- 表情轮播
  autoplay = true,      -- true：启动即按顺序循环播放全部 32 套表情
  start_emotion = "00", -- 轮播起点（00 睡眠 → 01 唤醒 → … → 41 → 回到 00）
  fallback_emotion = "02", -- id 不存在时的回退表情
  tour_step = 5200,     -- 每个表情停留时长 ms（一轮 32 个约 2.8 分钟）
  tour_delay = 15000,   -- 仅 autoplay=false 时生效：无操作多久后开始巡演

  hint = "<> switch   ^ spin   v bounce",

  -- 调试
  snapshot_ms = nil,    -- 设为毫秒数：启动后在 APP_DIR 导出 shot.png
  perf_log = false,     -- 设为 true：每 perf_frames 帧写一行 fps 到 perf.txt
  perf_frames = 200,
}
