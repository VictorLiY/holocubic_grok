# Grok Bot 语音对话功能设计（grok.bot.design.md）

> 目标：给 grok_bot 增加"语音输入 → 大模型 → 语音输出"的完整对话链路，
> 并让 Grok 小球的 32 套表情与对话状态实时联动。
>
> 状态：设计稿（未实施）。基于 2026-10-30 对 holocubic-apps 仓库的代码调研。

---

## 1. 背景与目标

### 1.1 现状

grok_bot 是纯前台动画 app（`kind = app`）：320×240 LVGL canvas、33ms 定时器主循环
（姿态合成 + 抗锯齿渲染，单帧约 20ms），无任何音频与网络能力。

### 1.2 目标

1. 按住/触发按键后采集麦克风音频，上传给云端大模型服务（ASR → LLM → TTS）。
2. 把模型返回的语音合成结果实时流式播放。
3. 对话全流程驱动 Grok 表情：聆听、思考、回答、出错各有专属表情与动画。
4. 语音功能**可选**：未配置/出错时自动降级为纯动画 app，不影响现有体验。

### 1.3 非目标

- 不做唤醒词常驻监听（`wake.so` 可作为后续增强，见 §8）。
- 不做回声消除/全双工（复用的硬件链路本身是半双工，见 §2.2）。
- 不自研 ASR/TTS 云服务，只做客户端。

---

## 2. 调研结论（可复用的现有资产）

### 2.1 设备音频能力全部在 app 自带的 C 模块里

宿主 Lua 层只有裸 I2S API（`i2s.start/read/write/stop/mute`，README_LUA.md），
**没有** Opus 编解码、没有 MP3 解码、没有 TTS。真正能用的音频能力都是
app 通过 `modules/*.so`（Host ABI 动态模块）自带的：

| 模块 | 位置 | 能力 |
| --- | --- | --- |
| `xiaozhi.so`（service 版叫 `xzvoice.so`，二进制相同） | `xiaozhi/package/xiaozhi.so` | `voice` 表：I2S 采集 + **设备端 Opus 编码**；Opus 解码 + I2S 播放；音量 |
| `wake.so` / `xzwk.so` | `xiaozhi/package/wake.so` | ESP-SR WakeNet 唤醒词（"你好小智"） |
| `audio.so`（mp3_player/mjpeg_player） | `mp3_player/package/modules/audio.so` | MP3/文件解码 + I2S 播放（适合播放本地/下载好的音频文件，不适合实时流对话） |

对本设计最关键的是 `xiaozhi.so` 的 `voice` API（`xiaozhi/package/audio.lua` 中的
完整用法）：

```lua
voice.start{rate=16000, channels=1, frame_ms=60, tx=true, rx=true,
            bitrate=12000, complexity=0}          -- 创建 Opus 编解码器
voice.capture_start{rate=16000, bits=32, i2s_id=0,
                    bclk_pin=41, ws_pin=45, din_pin=42,
                    buffer_count=4, buffer_len=128, pack="b23", gain_shift=2,
                    queue_depth=6, task_stack=32768, priority=2, core=0,
                    read_timeout_ms=100}           -- 启动采集（C 任务，独立于 Lua）
voice.capture_read() -> opus_packet|string         -- 轮询取一个 60ms Opus 帧
voice.capture_stop()
voice.playback_start() / playback_write(opus_pkt)  -- Opus 解码播放
voice.playback_status() -> {running, drained, ...}
voice.playback_finish() / playback_stop() / set_volume(0-100)
```

采集/解码在 C 任务里完成（core 0），Lua 侧只做 40ms 定时器轮询搬运，
**不会挤占 grok_bot 的渲染循环**（xiaozhi app 自己也是 40ms 轮询 + UI 并存）。

### 2.2 半双工约束

`audio.lua` 首行注释明确：**采集与播放互斥，不做全双工**（I2S 通道同一时刻
只有一个方向）。xiaozhi 的模式机是 `off → wake → listen → speak → off`。
grok_bot 必须遵守同样的半双工状态机。

### 2.3 "传给大模型"的现成通道：小智（XiaoZhi）协议

仓库内唯一的端到端先例是 xiaozhi：**设备只传 Opus，ASR/LLM/TTS 全在服务端**。

- 传输：宿主 `websocket.createClient`，JSON 控制消息 + 二进制 Opus 帧
  （v3 协议二进制帧带 4 字节头 `0x00 0x00 + u16be(len)`）。
- 连接握手：`hello` 消息声明 `audio_params = {format="opus", sample_rate=16000,
  channels=1, frame_duration=60}`；鉴权头 `Device-Id` / `Client-Id` /
  `Authorization: Bearer <token>`。
- 上行：`listen start/stop`（开始/结束说话）、二进制 Opus 帧、`abort`（打断）。
- 下行 JSON：`stt`（识别文本）、`tts start/sentence_start/stop`（语音段落）、
  `llm`（含 emotion）、`hello`、`mcp`、`alert`；下行二进制：Opus TTS 帧。
- 服务端：官方 `api.tenclass.net`（OTA 配对拿 URL+token），或自建
  xiaozhi-esp32-server 兼容服务端（开源生态，可自己接 OpenAI/任意 LLM）。
- VAD 在服务端：客户端持续上传，服务端判定说完后下发 `stt`+`tts start`。

关键参考文件：
`xiaozhi/package/{audio.lua, protocol.lua, playback_queue.lua, config.lua, runtime.lua}`、
`xiaozhi/src/main/xiaozhi_module.c`（C 侧）。

### 2.4 音频仲裁（多 app 抢 I2S）

- 仲裁是**单向的**：`xiaozhi-service`（若安装）持有音频，前台切到 deny 名单
  app 时**主动让出**（`suspend_audio_for_app`），退出时恢复。
- deny 名单在设备上的 `/sd/apps/xiaozhi-service/service.json` → `deny_apps`。
- **当前目标设备（192.168.0.109）没有安装 xiaozhi / xiaozhi-service**，
  所以 grok_bot 自带 `.so` 独占音频没有冲突；但设计必须考虑"用户装了
  xiaozhi-service"的场景（§6.1）。

### 2.5 HTTP 客户端（备用能力）

宿主有 `http.get/post/request(url, options, body, callback)`（weather、
aida_monitor 在用）。若将来要做"单轮 TTS 点播"（如播报一段固定文案），
可走 HTTP 拉音频文件 + `mp3_player` 的 `audio.so` 播放；但**实时对话**
的主链路必须是 WebSocket + Opus（§3 说明为什么）。

---

## 3. 方案选型

| 方案 | 描述 | 结论 |
| --- | --- | --- |
| **A. 内嵌小智协议客户端** | grok_bot 自带 `xiaozhi.so` 副本 + 精简版 audio/protocol，直连官方或自建小智服务端 | **采用**。设备端零 AI 计算、协议成熟、有现成参考实现与开源服务端生态 |
| B. 自定义 HTTP 链路（录音→上传→拿音频文件→播） | `http.post` 传音频给自建网关 | 否。设备端只能产 Opus，HTTP 云 ASR 普遍要 WAV；且无法流式播放，首响延迟 >10s，体验差 |
| C. IPC 委托 xiaozhi-service | grok_bot 当 UI 壳，音频和会话交给 service | 否。service 的表情/UI 协议是给 xiaozhi 自己的界面用的，不暴露原始 `stt/llm/tts` 事件流，grok_bot 无法驱动自己的表情引擎；且要求用户必须装 service |
| D. 本地 ASR/LLM | 端侧跑模型 | 否。ESP32-S3 无此算力 |

A 的一个前提：`xiaozhi.so` 是本仓库自带、随仓库分发的产物，grok_bot 复制
一份到自己的目录（与 mp3_player 复制 audio.so 同样的做法）没有额外许可问题。

---

## 4. 总体架构

```
┌────────────────────────── grok_bot (前台 app) ──────────────────────────┐
│                                                                         │
│  main.lua（现有外壳）                                                    │
│   ├─ 渲染循环 tmr(33ms) ──> Engine:tick ──> Ball:render（不动）          │
│   └─ voice.lua（新，会话编排层 / 状态机）                                │
│        │  半双工状态机 idle/listen/think/speak/error                     │
│        │  表情映射  state ──> Engine:set_emotion(id)                     │
│        ├─ audio_io.lua（新，精简自 xiaozhi/audio.lua）                    │
│        │    └─ tmr(40ms) 轮询                                            │
│        │         ├─ voice.capture_read ──> opus 上行                     │
│        │         └─ playback_queue ──> voice.playback_write              │
│        ├─ xz_client.lua（新，精简自 xiaozhi/protocol.lua）               │
│        │    └─ websocket ──> 小智服务端（ASR+LLM+TTS）                    │
│        └─ modules/xiaozhi.so（复制自 xiaozhi/package/）                  │
└─────────────────────────────────────────────────────────────────────────┘
                                   │ WebSocket / TLS
                            小智服务端（官方 或 自建
                            xiaozhi-esp32-server → 接任意 LLM）
```

设计原则：

1. **渲染优先**：音频轮询是独立 40ms 定时器，C 侧任务跑在 core 0，
   Lua 轮询单次耗时 <1ms；渲染循环不感知音频（只通过表情引擎交互）。
2. **会话层与传输层分离**：`voice.lua` 只管状态机与表情映射，
   `xz_client.lua` 只管协议，`audio_io.lua` 只管硬件——三者都可单测
   （复用 tools/ 下 xiaozhi 的纯 Lua mock 测试套路）。
3. **渐进降级**：`.so` 缺失 / 配置为空 / WS 断连 → 语音功能关闭，
   app 回到今天的纯动画行为，按键映射还原。

---

## 5. 详细设计

### 5.1 文件结构（新增 4 个 Lua + 1 个 .so）

```
grok_bot/package/
├── app.info            # version 1.1.0，描述加"语音对话"
├── config.lua          # + 语音配置段（§5.6）
├── main.lua            # + 语音会话初始化、按键绑定、生命周期
├── grok_ball.lua       # 不动
├── grok_engine.lua     # 不动
├── grok_data.lua       # 不动
├── voice.lua           # 新：会话编排 + 状态机 + 表情映射
├── audio_io.lua        # 新：xiaozhi/audio.lua 精简版（去 wake 分支）
├── xz_client.lua       # 新：xiaozhi/protocol.lua 精简版（去 MCP/OTA 配对，仅静态 URL+token）
├── playback_queue.lua  # 新：自 xiaozhi 复制（有界 jitter buffer，容量调小到 96 帧）
└── modules/
    └── xiaozhi.so      # 新：自 xiaozhi/package/xiaozhi.so 复制
```

不复制 `wake.so` 与唤醒模型（~几百 KB），唤醒词作为后续增强。

### 5.2 会话状态机（voice.lua）

```
idle ──(按键/触发)──> listen ──(服务端 stt/tts start)──> think* ──> speak ──(tts stop+排空)──> idle
  ^                                                                                      │
  └──────────────────────────── 任意状态 error/abort  ←──────────────────────────────────┘
```

| 状态 | 音频方向 | 触发 | Grok 表情（emotion id） |
| --- | --- | --- | --- |
| `idle` | 关 | 初始/会话结束 | 恢复巡演（tour 继续）或 `02 待机放空` |
| `listen` | 采集+上行 | 用户按键开始说话 | `35 等待输入`（`03 好奇` 池轮换）；说话音量驱动呼吸振幅 |
| `think` | 保持上行（服务端 VAD 收尾）→ 停采集 | 收到 `stt`（可显示字幕） | `30 思考中` / `40 检索资料` 池轮换 |
| `speak` | 下行+播放 | 首个 `tts` 二进制帧 | `39 输出回复`；若服务端 `llm.emotion` 有情绪词则映射到对应表情池 |
| `error` | 关 | WS 断连/音频失败 | `34 出错` 停 2s → `idle` |

表情联动是本设计的核心卖点：语音事件 → `engine:set_emotion()` 复用现有
`follow_settle` / 巡演游标机制——**会话期间挂起巡演**（`APP.tour_next` 顺延），
会话结束恢复，不污染游标。

打断：speak 状态再按通话键 → 发 `{"type":"abort"}` + `playback_stop` → listen。

### 5.3 采集/播放（audio_io.lua）

直接精简 `xiaozhi/package/audio.lua`：

- 保留 `set_mode("listen"|"speak"|"off")`、40ms 轮询、错误上抛（`on_error`）。
- 删除 wake 模式与 `begin_wake_bridge`。
- `playback_queue` 容量 256 帧/256KB → **96 帧/96KB**（对话场景够用，
  省下的内存给 canvas；grok_bot 不需要长 TTS 缓冲，因为是一问一答）。
- 采集参数照抄验证过的配置：16kHz/mono/60ms 帧/opus 12kbps/complexity 0/
  b23 打包/gain_shift 2/引脚 41·45·42。
- `on_send(packet)` 回调直接对接 `xz_client:send_audio(packet)`，
  遇到发送队列满（背压）返回 false → audio_io 照 xiaozhi 的做法 fail 该次会话。

### 5.4 协议客户端（xz_client.lua）

精简 `xiaozhi/package/protocol.lua`（约保留 40%）：

- 保留：连接/握手 `hello`（v3）、上行 `listen start/stop`、二进制 Opus 帧
  （4 字节头）、`abort`、有序发送队列（深度 16/64KB，1500ms 积压断链）、
  `on("stt"/"tts"/"llm"/"close")` 事件分发。
- 删除：OTA 配对/激活流、MCP、设备控制、goodbye 重连复杂策略
  （保留指数退避简单重连：1s/2s/5s，最多 3 次）。
- **鉴权简化**：只支持静态配置 `ws_url + token`（自建服务端场景）。
  官方服务端需要 OTA 配对，第一版不做（见 §8 开放问题）。

### 5.5 与主循环共存（资源预算）

| 项 | 预算 | 说明 |
| --- | --- | --- |
| 渲染 tmr 33ms | ~20ms/帧（现状） | 不变；语音不进这个回调 |
| 音频 tmr 40ms | <1ms/次 ×2 方向互斥 | `capture_read` 最多 6 帧或 `queue:drain` 12 帧 |
| PSRAM | canvas ~150KB + 队列 96KB + .so 数据 | S3-N16R8 充裕 |
| WS 发送队列 | 64KB | opus 12kbps → 60ms 帧约 90B，几秒缓冲 |

Lua 堆注意点：每帧 opus packet 是短命字符串（60ms 一个，GC 压力小，
xiaozhi 同节奏已验证）；**热路径照旧零表分配**的原则不受影响。

### 5.6 配置（config.lua 新增段）

```lua
voice = {
  enabled     = true,     -- 总开关；false 或 .so 缺失时纯动画模式
  ws_url      = "",       -- 例: wss://my.server/xiaozhi/v1/ (留空=语音不可用)
  token       = "",
  volume      = 70,       -- 0-100（映射 voice.set_volume；同时轮询 sys.getvolume 同步系统音量）
  ptt_key     = "DOWN",   -- 按住说话的键（见 §5.7）
  subtitles   = true,     -- 底部 hint 轮显 stt 文本
  idle_emotion = "02",    -- 会话结束回落表情
},
```

### 5.7 交互设计（按键）

现有：`←/→` 切表情、`↑` 自旋、`↓` 弹跳、`HOME` 退出。语音模式新增：

| 按键 | 语音模式下的行为 |
| --- | --- |
| `↓` **按住**（PTT） | 进入 listen；松开 → 发 `listen stop`，转 think |
| `↓` 短按 | 切换到自动 VAD 模式：按一下开始，服务端判定说完自动收尾（xiaozhi 同款）；再按一下中止 |
| `↑` | speak 中 = 打断回 listen；否则维持自旋彩蛋 |
| `HOME` | 会话中止（abort+stop_i2s）后退出 app |

首次按下时若 `ws_url` 为空/未连接，hint 显示 `voice not configured`，
并切 `38 拒绝/受限` 表情 2 秒（充分利用现有表情语义）。

### 5.8 字幕

复用现有底部 `hint` label：`stt` 文本与 `tts sentence` 文本截断 28 字符轮显，
4s 无更新回落 `id n/32`。不新开 LVGL 控件，避免与 canvas 抢刷新。

### 5.9 生命周期与错误处理

- `APP.stop()`：先 `voice:shutdown()`（abort → stop_i2s → WS close → 注销定时器），
  再走现有清理；`app.exiting()` 路径同样挂接。
- `.so` 加载失败/缺文件：启动时探测，置 `voice.enabled=false`，写一行日志到
  `error.txt`（沿用现有诊断约定），纯动画模式。
- I2S 被占（如用户装了 xiaozhi-service 且未让出）：`capture_start` 返回错误 →
  按可恢复错误处理（xiaozhi 的 `fail()` 语义），hint 提示后回 idle，
  不退出 app。

---

## 6. 共存与仲裁

### 6.1 与 xiaozhi-service（若用户安装）

- grok_bot 是前台 app，service 检测到前台切换会主动让出音频
  （`suspend_audio_for_app`）——前提是 grok_bot 在 deny 名单里。
- 安装文案（README）指导用户在 `/sd/apps/xiaozhi-service/service.json` 的
  `deny_apps` 中加 `"grok_bot": true`；未来可提供一键脚本。
- 反向：grok_bot 退出时确保 `stop_i2s()`，让 service 能恢复唤醒监听。

### 6.2 与 mp3_player / mjpeg_player

同为前台 app，天然互斥（一个时刻只有一个前台 app），无额外处理；
只需保证退出清理彻底（§5.9）。

### 6.3 音量

遵循仓库约定：固件只存共享音量值不缩放 PCM。`voice.set_volume` 由
`xzvoice.so` 在 PCM 域做增益；同时按建议 200ms 轮询 `sys.getvolume()`
同步用户在系统设置里的改动（参考 `mjpeg_player/package/volume.lua` 适配器，
可直接复制该文件）。

---

## 7. 实施计划

| 阶段 | 内容 | 交付物 | 验证 |
| --- | --- | --- | --- |
| **P1 硬件通路** | 复制 `.so`；移植 `audio_io.lua` + `playback_queue.lua`；main.lua 挂 tmr；做"按键录音→回放自己的声音"闭环（不经网络） | 硬件自环 demo | 真机：按住↓说话，松开听到自己的声音（opus 编解码往返），渲染不掉帧（perf_log 对比） |
| **P2 协议链路** | 移植 `xz_client.lua`；接自建 xiaozhi-esp32-server；跑通 listen→stt→tts→speak | 最小对话版 | 真机对答一句；断网/断服务自动降级不崩 |
| **P3 表情联动** | `voice.lua` 状态机 + 表情映射 + 巡演挂起/恢复 + 字幕 | 功能完整版 | 状态↔表情对照表逐项过；巡演回归（--tour）仍 32 个全走 |
| **P4 打磨** | 打断、音量适配器、错误语义、README、deny_apps 文案、app.info 1.1.0 | 发布版 | 全表情×语音状态组合冒烟；电量/内存长跑 |

依赖：P2 起需要用户提供一个自建小智服务端（或官方 token）。

---

## 8. 风险与开放问题

1. **官方服务端接入**：官方 `api.tenclass.net` 走 OTA 配对流程，
   第一版只支持自建服务端的静态 URL+token。是否值得移植整套 activation.lua？
   （建议：有真实需求再做，自建生态已够用。）
2. **半双工体验**：用户在 TTS 播放中说话无法被打断采集（需先 abort）。
   已用"按键打断"规避；真全双工需换支持 AEC 的硬件方案，超出范围。
3. **`.so` 双份分发**：xiaozhi.so（210KB）在 xiaozhi 与 grok_bot 各存一份，
   占 SD 卡可忽略，但**版本升级要同步**（记录来源 commit 于 README）。
4. **唤醒词**：wake.so + 模型 ~1MB。若用户装了 xiaozhi-service，唤醒职责
   应归 service；grok_bot 内不常驻唤醒，避免双实例抢 I2S。
5. **首响延迟**：链路为 采满→VAD→LLM 首字→TTS 首帧，实测取决于服务端
   （自建 OpenAI 类后端一般 1~3s）。表情先切"思考中"可以掩盖等待感。
6. **60ms×6 帧的 Lua 轮询与渲染循环同为定时器**：理论无冲突（不同回调），
   但 ESP32 Lua 定时器并发上限需在 P1 实测（xiaozhi app 同构已验证，风险低）。

---

## 9. 测试计划

- **离线**：`scripts/preview.mjs` 已可跑真实 Lua。为 `voice.lua` 状态机加
  mock（音频/WS 均打桩）后用 `--tour` 同款方式做状态转移回归：
  idle→listen→think→speak→idle 全路径 + 打断路径 + 各类错误注入。
- **真机**：P1 自环；P2 对话；`perf_log` 对比语音开/关的 fps（验收线：
  开语音后 fps ≥ 27）；`--tour` 巡演完整性不回归。
- **共存**：装 xiaozhi-service 的设备上切前台/退出，观察双方音频让出/恢复。

---

## 附：关键参考代码索引

| 主题 | 路径 |
| --- | --- |
| voice API 完整用法 | `xiaozhi/package/audio.lua` |
| 半双工状态机 + 轮询 | `xiaozhi/package/audio.lua` `set_mode`/`poll` |
| WS 协议（hello/帧格式/背压） | `xiaozhi/package/protocol.lua` |
| Opus jitter buffer | `xiaozhi/package/playback_queue.lua` |
| C 侧（采集/编解码引脚） | `xiaozhi/src/main/xiaozhi_module.c` |
| 服务端示例配置 | `xiaozhi/package/config.example.json` |
| 音量共享适配器 | `mjpeg_player/package/volume.lua` |
| 仲裁测试（mock 套路） | `tools/test_xiaozhi_audio_arbitration.py` |
| 宿主 i2s/http/sys API | `README_LUA.md` |
