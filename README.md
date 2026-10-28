# Grok Bot

把 [grok-ball](https://github.com/tycoding/grok-ball) 的 Grok 小球表情动画移植到 **HoloCubic**（320×240 横屏 / Lua + LVGL）的前台应用。

纯 Lua 实现，不需要编译，也不依赖任何图片素材——球体、眼睛、睡眠字母、撒花全部在 LVGL canvas 上逐帧实时绘制。待机 15 秒不动，它会自己开始轮播 32 套表情。

![预览](preview.png)

## 功能

### 32 套表情

| 分组 | 编号 | 数量 |
| --- | --- | --- |
| 生命周期 | 00 睡眠 · 01 唤醒 · 02 待机放空 · 03 好奇 · 04 发呆 · 05 加载苏醒 · 06 休眠 · 07 抖动唤醒 | 8 |
| 情绪反应 | 10 开心 · 11 疑惑 · 12 失落 · 13 惊讶 · 14 害羞 · 15 疲惫 · 16 专注 · 17 慌张 · 18 无奈 · 19 满意 · 20 困惑 · 21 生气 | 12 |
| 代理状态 | 30 思考中 · 31 接收任务 · 32 处理中 · 33 任务完成 · 34 出错 · 35 等待输入 · 36 联网加载 · 37 复述回忆 · 38 拒绝 · 39 输出回复 · 40 检索资料 · 41 停止终止 | 12 |

### 动画机制

- **逐点弹簧形变**：25 组眼睛轮廓，每组左右各 48 个点。换眼神时不是直接替换图形，而是每个点各自用二阶弹簧追目标点，形变过程中会自然过冲、回弹。
- **球面投影**：眼睛位置按"经度"换算——把眼睛的水平偏移归一化成角度，加上自旋偏航后取正弦作为横向位移、余弦作为宽度压缩。越靠球边缘的眼睛越窄，绕球转动时会被挤出/挤入。
- **纵向拟合**：眼睛越靠近球的上下两极，垂直方向压得越扁，贴合球面曲率。
- **眨眼**：带关键帧队列（闭合 50ms → 过冲张开 1.08 → 回落），弹簧驱动，14% 概率连眨两下。部分表情关闭眨眼（如睡眠）。
- **呼吸**：默认振幅 0.01 的缩放 + 纵向漂移，相位走绝对时间，切换表情不会跳变。
- **眼神漂移**：常态下两只眼睛有不同相位的正弦微动，靠得住的"活着"感主要来自这里。
- **自旋**：弹簧追整数圈（±2π），自旋期间余弦压缩会把两只眼睛甩到球体侧面，形成明显的 3D 滚动感。
- **弹跳**：4 段高度递减的抛物线（48 → 28 → 14 → 6）。
- **过渡**：换表情时新旧姿态用 `easeInOutCubic` 混合，时长由表情的 `transition` 决定（320~900ms）。
- **关键帧序列**：部分表情（如 01 唤醒）走脚本化关键帧，结束后可回落基础姿态（`settle='base'`）或自动切到下一个表情（`settle={next=...}`）。
- **睡眠字母**：`00 睡眠` 时三枚 `z` 错峰沿右上漂移，先淡入后淡出。
- **撒花**：`33 任务完成` 进入时喷 20 片彩色纸屑（阻力 + 重力 + 旋转 + 淡出）。

## 按键

| 按键 | 作用 |
| --- | --- |
| `←` / `→` | 上一个 / 下一个表情（循环） |
| `↑` | 自旋一圈 |
| `↓` | 弹跳 |
| `HOME` | 退出应用 |

无操作 15 秒后自动巡演，每 5.2 秒换一个表情；按任意方向键即退出巡演、回到手动模式。

## 安装

设备上的目标目录是 `/sd/apps/grok_bot/`，**`package/` 里的文件要平铺进去**（`app.info` 必须在目录第一层）：

```
/sd/apps/grok_bot/
├── app.info
├── config.lua
├── grok_ball.lua
├── grok_data.lua
├── grok_engine.lua
├── main.lua
└── main.png
```

三种方式任选：

**1. 文件管理器上传**：打开 `http://<设备IP>/` 里的文件管理（或 DevTools 页面），把 `package/` 里的 7 个文件上传到 `/sd/apps/grok_bot/`。

**2. HTTP API 上传**（脚本化部署）：

```bash
DEV=192.168.0.108
cd package
for f in app.info config.lua grok_data.lua grok_ball.lua grok_engine.lua main.lua main.png; do
  curl -X PUT --data-binary @"$f" \
    "http://$DEV/api/system/fs/upload?path=/sd/apps/grok_bot/$f&offset=0&total=$(wc -c < $f)"
done
curl -X POST "http://$DEV/devtools/api/apps/rescan"   # 让 launcher 重新扫描
```

**3. 直接拷 SD 卡**：把 `package/` 的内容拷到 SD 卡的 `apps/grok_bot/`，插回设备上电。

装好后重启设备（或在 DevTools 里点 rescan），launcher 里会出现「Grok 小球 / Grok Bot」，图标是浅色小球配一双圆眼。

**卸载**：删掉 `/sd/apps/grok_bot/` 整个目录再 rescan。

## 配置

改 `config.lua` 后重启应用生效：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `cx` / `cy` | `160` / `124` | 球心在屏幕上的位置 |
| `radius` | `84` | 球半径（像素），球直径 = `2*radius` |
| `bg` | `0x0B0C10` | 背景色 |
| `interval` | `33` | 重绘间隔 ms（≈30fps） |
| `start_emotion` | `"02"` | 启动表情 id |
| `fallback_emotion` | `"02"` | id 找不到时的回退表情 |
| `tour_delay` | `15000` | 多久无操作后开始自动巡演（ms） |
| `tour_step` | `5200` | 巡演时每个表情停留多久（ms） |
| `hint` | `<> switch   ^ spin   v bounce` | 启动时底部提示文字，4.5 秒后自动换成 `当前 id / 32` |
| `snapshot_ms` | `nil` | 调试：设为毫秒数，启动后把屏幕导出为 `shot.png` |
| `perf_log` | `false` | 调试：每 `perf_frames` 帧往 `perf.txt` 写一行 fps |
| `perf_frames` | `200` | 调试：性能统计窗口帧数 |


## 目录结构

```
grok_bot/
├── package/            # 需要部署到设备的内容
│   ├── app.info        # 应用元信息（名称、分类、入口、图标）
│   ├── config.lua      # 用户配置
│   ├── main.lua        # 应用外壳：canvas、主循环、按键、巡演、调试钩子
│   ├── grok_engine.lua # 驱动层：姿态合成、弹簧、眨眼、表情池、序列、过渡
│   ├── grok_ball.lua   # 绘制层：球体、球面投影眼睛、zzz、撒花
│   ├── grok_data.lua   # 生成数据：25 组眼环 + 32 套表情（42KB）
│   └── main.png        # 128×128 图标
├── scripts/
│   ├── gen_data.mjs    # 从上游 grok-ball.js 抽取几何/情绪数据生成 grok_data.lua
│   └── gen_icon.py     # 生成图标
├── preview.png
└── README.md
```

## 实现要点

LVGL 的 canvas 没有"填充多边形"图元，而眼睛是 48 点闭合轮廓。这里的做法是：

1. 在世界坐标（viewBox 259×259，头部中心 114.27，半径 114.27）里把眼环做完整仿射变换；
2. 用**扫描线**把多边形按行拆成水平线段，每帧每只眼睛约 40~60 次 `lv_canvas_draw_line`；
3. 整体再缩放到屏幕（球半径 84px）。

球体用一个 `radius = LV_RADIUS_CIRCLE` 的圆角矩形填充，再叠 5 层同色系浅色圆近似 SVG 的径向渐变高光。

热路径（每帧）不分配新表：姿态表、眼环缓冲、扫描线交点数组都是预分配的，只有换表情时才创建 2 个 96 元素数组。

## 性能

在 HoloCubic（ESP32-S3）上实测：

```
fps = 30.0   每帧 16.9ms
  engine  2.2ms   姿态合成 / 弹簧 / 序列
  canvas 14.2ms   bg 0.2  球体 0.9  眼睛 12.9  其他 0.2
```

瓶颈是眼睛填充（每次 `draw_line` 调用固定开销较大）。如果要提速，最直接的办法是把相邻两行合并成 2px 粗的线段，可省约 4ms，代价是眼缘略粗糙。`config.interval` 调到 40 会更省电（约 25fps）；调到 25 反而不会更快——单帧就要 17ms，加上 LVGL 刷新 16ms，CPU 跟不上会让实际帧率反降。

## 重新生成数据

`grok_data.lua` 是从上游 `grok-ball/src/grok-ball.js` 的数据段自动生成的，不要手改。上游改动后这样重新生成（需要 Node.js）：

```bash
node scripts/gen_data.mjs /path/to/grok-ball/src/grok-ball.js
python3 scripts/gen_icon.py /path/to/grok-ball/src/grok-ball.js   # 需要 Pillow
```

两个脚本都支持省略参数——此时会去 `../../grok-ball/src/grok-ball.js` 找（即与本仓库同级放置 grok-ball 源码的布局）。

## 与原版的差异

- 未实现原版的**彩带拖尾**（`ribbons` / trails）和**头顶环绕**（`orbit`），其余动画机制均已移植。
- 原版用 SVG 径向渐变画球体，这里用 5 层同心圆近似，静态截图下几乎无差别，但放大能看到极轻微分层。
- canvas 绘制无抗锯齿，球缘在纯黑背景上会有约 1px 的锯齿。

## 致谢与许可

眼环几何与 32 套表情数据、动画算法均来自 **grok-ball**（MIT License, Copyright (c) 2026 tycoding），原始许可见 [`LICENSE-grok-ball`](LICENSE-grok-ball)。本移植同样以 MIT 协议发布。
