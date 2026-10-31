# Grok Bot × WorkBuddy 实时状态显示（grok.bot.status.md）

> 目标：让 grok_bot 成为 **WorkBuddy 的物理化身**——WorkBuddy 空闲、思考、
> 执行、待命（回复完等用户）、出错时，HoloCubic 上的 Grok 小球实时切换
> 对应的表情头像与动画。
>
> 状态：**已实施（2026-10-31，v1.1.0）并真机验证通过**。设备侧见
> `package/wb_status.lua` + `package/main.lua`；PC 侧即本仓库
> `wb_status_pc/monitor-server.mjs`（新增 `HOST`/`--lan` 绑定与
> `GET /api/holo` 紧凑端点）；离线回归 `node scripts/preview.mjs --wb=45`，
> 服务端测试 `node wb_status_pc/test_holo.mjs`。与
> `grok.bot.design.md`（语音对话）互相独立、可叠加。

---

## 1. 背景与目标

### 1.1 用户故事

- WorkBuddy 在后台跑了 3 分钟改代码，我去干别的了——小球还在"待机放空"，
  转头看一眼桌摆就知道该回 IDE 了（`32 处理中忙碌`）。
- WorkBuddy 回复完毕等我说话（`standby`）——小球跳一下切到"等待输入"，
  错过不了。
- 一轮工具全部执行完、回复生成 → 小球撒彩带庆祝（`33 任务完成` 自带
  confetti）。
- WorkBuddy 报错 → `34 出错`，一眼可见。

### 1.2 现状：状态源已经存在

`wb_status_pc/monitor-server.mjs`（Node 零依赖，默认端口 8787）已经把
WorkBuddy 的状态聚合好了：

- **数据源**：tail `~/.workbuddy/projects/<项目目录编码>/<sessionId>.jsonl`
  会话轨迹（增量读 + 半行缓存），每 2.5s 重扫项目目录，自动跟随 mtime
  最新的"正在工作的会话"。
- **状态机**（`currentStatus()`）：按最后一条记录的 `lastKind` 推导——
  `user/think → thinking`，`tool/result → working`，`reply → standby`，
  `error → error`，25s 无新记录（`IDLE_AFTER`）→ `idle`。
- **接口**：`GET /`（仪表盘）、`GET /events`（SSE，400ms 轮询比对变化才
  广播、15s ping）、`GET /api/state`（全量快照 JSON）、`POST /api/state`
  （手动覆盖状态，60s 有效）、`POST /api/hook`（接收 hooks 事件）、
  `GET /api/health`、`GET /api/projects`。

本设计**不再新建 PC 桥接**：monitor-server 就是唯一事实源。设备侧直接
消费它。

### 1.3 目标

1. 设备以 ~1s 延迟拿到 monitor-server 的状态，映射为**表情头像 + 动画
   + HUD 文案**（复用现有 32 套表情，零新增美术）。
2. 对 monitor-server 的改动**最小化**（两个小扩展，见 §5.1），不改它的
   状态机与接口语义。
3. 状态功能**可选**：服务不可达/未配置时自动退回纯动画行为（现状）。

### 1.4 非目标

- 不做双向控制（设备按键去操作 WorkBuddy）——只做状态显示。
  （但 monitor 已有的 `POST /api/state` 顺带成为"手机/电脑遥控小球表情"
  的免费通道，与设备无关。）
- 不做语音，不做唤醒，不与 `grok.bot.design.md` 耦合。

---

## 2. 调研结论（可复用的现有资产）

### 2.1 表情与动效引擎：`agent` 组直接对口

`grok_data.lua` 的 32 套表情里 `group="agent"`（代理工作状态）12 套语义
与 WorkBuddy 状态一一对应，**零新增美术**：

| id | 名称 | 引擎特性 |
| --- | --- | --- |
| `30` | 思考中 | 缓慢眼环轮换池 |
| `31` | 接收任务 | 进表情即播序列动画（适合"新会话/新指令"） |
| `32` | 处理中忙碌 | 高频小动作 |
| `33` | 任务完成 | **`confetti=0.95` 撒彩带** + 1.1s 跳跃序列（`set_emotion` 自动触发 `pending_burst`） |
| `34` | 出错 | 强视觉反馈 |
| `35` | 等待输入 | 眼睛看向下方（"看着你"） |
| `36` | 联网加载 | 呼吸脉冲式眨眼 |
| `37` | 复述回忆 | 备用（输出计划） |
| `38` | 拒绝/受限 | 备用（拒绝场景） |
| `39` | 输出回复 | 正在生成文本 |
| `40` | 检索资料 | 上下扫视 |
| `41` | 停止终止 | 备用（中止） |

引擎（`grok_engine.lua`）的"一次性动效"原语可叠加在表情之上：
`spin(n)` 自旋、`bounce()` 四段递减弹跳、`take_burst()` 彩带、
`antics` 长状态自动小动作、`set_gaze(x,y)` 注视。

### 2.2 设备侧网络：三条已验证通道

| 通道 | 仓库先例 | 适用性 |
| --- | --- | --- |
| **HTTP 轮询** `http.get(url, headers, cb)` 异步 | weather、aida_monitor | **主选**：无连接状态管理、断线自愈天然成立 |
| SSE 消费（裸 `net.createConnection` + 手写请求头 + 分块解析 + 重连） | `aida_monitor/package/aida_client.lua`（消费 AIDA64 `/sse`） | 备选：monitor 的 `/events` 每次广播全量状态 JSON（含 60 条事件 + 8 个项目，数 KB），对 ESP32 偏重，见 §8 开放问题 |
| JSON 解析 `sjson.decode` + 正则兜底 | `xiaozhi/package/protocol.lua` | 必备：扁平小对象解析可靠 |

### 2.3 monitor-server 的两个接入缺口

1. **只绑 `127.0.0.1`**（`server.listen(PORT, '127.0.0.1')`）——局域网内
   的 HoloCubic 连不上，需要支持 `HOST=0.0.0.0`（或 `--lan`）。
2. **`/api/state` 载荷太重**——全量快照含 events/projects/元数据，
   ESP32 每秒拉一次浪费带宽与解析时间；需要一个小载荷端点 `/api/holo`。

这两个缺口就是 PC 侧要做的**全部**改动（§5.1）。

---

## 3. 方案选型

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 状态源 | **直接用 monitor-server**（不新建桥接） | 状态机、会话跟随、事件去噪（`stripNoise`）、工具名中文化（`TOOL_LABEL`）都已实现且在使用中；再建一层桥接只会引入双份状态语义与同步问题 |
| 设备获取方式 | **HTTP 1s 轮询新端点 `GET /api/holo`**（小载荷） | 状态是低频离散事件（一次任务平均 5~20 次跃迁），1s 延迟体感即"实时"；仓库里 weather/aida 已验证这是设备上最稳的网络模式；monitor 400ms 的内部轮询节奏不受影响 |
| SSE 推送 | **预留不实施** | `/events` 全量 JSON 太重；若未来要推送（<100ms 延迟），给 monitor 加一条瘦事件流即可（§8.2），设备端可照抄 aida_client 的 SSE 客户端 |
| 状态枚举 | **沿用 monitor 的 5 态**：`idle/thinking/working/standby/error`（+设备侧合成 `offline`） | 与现有仪表盘、`POST /api/state` 白名单、hooks 映射完全一致；设备不做二次状态翻译，monitor 改语义时设备自动跟随 |

---

## 4. 状态集与映射（本设计的核心契约）

### 4.1 线协议：`GET /api/holo`（monitor-server 新增，小载荷）

```json
{
  "v": 42,                       // 变更计数（= st.eventTotal，单调递增）
  "status": "working",           // idle | thinking | working | standby | error
  "detail": "编辑文件 · main.lua",
  "statusSince": 1761812400000,  // 本次状态开始时刻(ms)
  "lastEventTs": 1761812400000,  // 最后一条轨迹记录时刻(ms)
  "sessionId": "3f9c…",          // 当前会话 id（设备用它检测会话切换）
  "project": "holocubic_ws",     // 项目名（cwd basename，兜底 projDir）
  "title": "…",                  // 会话 aiTitle
  "model": "…"
}
```

- 体 <300B，`Content-Type: application/json` + `Cache-Control: no-store`
  + 现有 CORS 头；实现上就是 `payload()` 的投影（一行挑字段）。
- `detail` 服务端先截断到 48 字符（现 80），避免敏感长文上屏。
- 未知 `status` 值透传，设备侧回退 `working` 语义（"它在忙"永远是最安全的
  误读）。`offline` 由设备侧合成，不上行。

### 4.2 状态 → 头像与动画映射

每个状态 = **基础表情（头像）** + **进入时一次性动效** + **持续期动画** +
**HUD 文案**。映射表放设备侧 `wb_status.lua`（可被 `config.lua` 覆盖）：

| status | 头像（emotion） | 进入时一次性动效 | 持续期动画 | HUD 文案 |
| --- | --- | --- | --- | --- |
| `idle` | `02 待机放空` | — | 引擎 `antics`（9~18s 随机自旋/弹跳/连眨）+ `glance` 张望 | `idle·<project>` |
| `idle` ≥ 2min | `06 休眠` | 淡入（transition 1200ms） | 低幅呼吸 | `idle 2m+` |
| `idle` ≥ 5min | `00 睡眠` | 淡入 | `zzz` + 眼环下沉 | `zzz` |
| `thinking` | `30 思考中` | 眼环收拢 | 缓慢眼环轮换 + 呼吸 | `thinking…`（+detail） |
| `working` | `32 处理中忙碌` | `spin(1)` 自旋一圈（开工仪式感） | 引擎忙碌小动作 | `run: <detail>` |
| `working` + detail 命中检索类关键词（检索文件/搜索内容/联网搜索/抓取网页） | `40 检索资料` | — | 上下扫视 | `search…` |
| `working` + detail 命中规划类（规划任务/更新任务） | `30 思考中` | — | 同 thinking | `plan…` |
| `standby` | `33 任务完成` **闪现 2.5s** → `35 等待输入` | 闪现即 **confetti 彩带（表情自带）+ `bounce()`** | 之后每 8s 轻微 `bounce()` 提醒（幅度靠 bounce_scale 已自动收敛） | `done ✓ → ready?`（琥珀 0xE8B14A） |
| `error` | `34 出错` | `spin(1)`（慌乱感） | 停留至状态变化（monitor 25s 后自动回 `idle`） | `error!`（红 0xC0392B） |
| `offline`（设备合成） | `36 联网加载`（仅首次失败） | — | 连续 3 次失败 → 挂起状态驱动，回落本地 `autoplay` 巡演，HUD `--` | `--` |

**跃迁闪现规则**（比状态本身更细腻的一层，同样在 `wb_status.lua`）：

| 跃迁 | 闪现 | 含义 |
| --- | --- | --- |
| `working → standby` | `33 任务完成` 2.5s（彩带+弹跳）→ `35` | 一轮活干完了，庆祝 |
| 其他 → `standby` | 直接 `35`，进入时 `bounce()` 一次 | 等你说话 |
| `sessionId` 变化 | `31 接收任务` 1.5s → 按当前 status | 新会话/新指令到达 |
| 其他任意跃迁 | 直接切目标表情（引擎 200~900ms 过渡自带） | — |

> 一次性动效在 `set_emotion()` 后立刻调用（引擎已处理互斥：`_spin`
> 存在时不再起、`_bounceAt<0` 才触发）。周期性动效（standby 的 8s
> 弹跳、idle 休眠梯度）由 `wb_status.lua` 的轮询定时器顺带驱动，
> **不新开定时器**。
>
> monitor 的 `25s IDLE_AFTER` 兜底 + `/api/hook`、`POST /api/state`
> 覆盖机制，使"瞬态回落"全部在 PC 侧完成——设备侧无需自建超时回落
> （比上一版设计更简单，唯一例外是 `offline` 探测）。

---

## 5. 详细设计

### 5.1 总体架构

```
WorkBuddy                     PC（任意，与设备同局域网）              HoloCubic 设备
──────────                    ─────────────────────────              ─────────────────
写会话轨迹                     wb_status_pc/monitor-server.mjs        grok_bot (前台 app)
~/.workbuddy/projects/  ──→   tail + 状态机(5态) + 会话跟随           main.lua
  <proj>/<sid>.jsonl            │ :8787                               ├─ wb_status.lua (新)
hooks 事件 ──POST /api/hook──→  ├─ GET /api/holo   <── http.get 1s ──┤    轮询/去重/降级/闪现
                                ├─ GET /events (SSE, 仪表盘用)        ├─ 映射表 → engine:set_emotion
人工/手机 ──POST /api/state──→  └─ GET /            (现有页面)         │    + spin/bounce/confetti
                                                                     └─ HUD hint 状态文案
```

- PC 侧改动**只有两处**（都在 monitor-server.mjs，各 ~10 行）：
  1. 监听地址支持 `HOST` 环境变量（默认仍 127.0.0.1，`HOST=0.0.0.0`
     或 `--lan` 时对局域网开放）——设备可达的前提；
  2. 新增 `GET /api/holo`：`payload()` 的紧凑投影（§4.1 字段）。
  其余一切（状态机、SSE、仪表盘、hooks、覆盖）保持原样。
- 设备侧改动：新增 `package/wb_status.lua`，`main.lua`/`config.lua`
  小改（§5.2/§5.3）。

### 5.2 设备侧新模块 `package/wb_status.lua`

单文件、无依赖，接口：

```lua
local WB = dofile(APP_DIR .. "/wb_status.lua")
WB.init{
  host = c.host, port = c.port or 8787, path = "/api/holo", poll_ms = 1000,
  on_status = function(status, detail, project) ... end,  -- 状态跃迁（含闪现调度）
  on_tick   = function(status, now) ... end,               -- 持续态周期回调（周期弹跳/休眠梯度）
}
WB.shutdown()
```

内部结构：

1. **独立 1s 定时器**（`tmr.ALARM_AUTO`），回调里发起**异步**
   `http.get("http://host:8787/api/holo", headers, cb)`，超时 3s。
   绝不进入 33ms 渲染回调；请求头带 `Connection: close`（monitor 是
   简单 `http.createServer`，短连接最省心）。
2. **解析**：`sjson.decode`（pcall 包裹）；宿主无 `sjson` 时退化为
   手写字段抽取（照抄 xiaozhi `protocol.lua` 的 `pick_string` 正则兜底
   套路——本协议字段固定、扁平、字符串/数字，兜底可靠）。
3. **去重与闪现**：`status`/`statusSince`/`sessionId` 任一变化 →
   `on_status`；`v`（eventTotal）变化但 status 没变 → 仅刷新 HUD 的
   `detail`。闪现（`33`/`31`）用一次性 `tmr` 落回目标表情，新跃迁到来
   先注销旧闪现定时器（`tour_driver` 同款"先注销再重建"纪律）。
4. **离线判定**：连续 3 次失败/超时 → `on_status("offline")` + 指数退避
   拉长轮询（1s → 2s → 5s，恢复后回 1s）；offline 期间挂起状态驱动
   （`APP.wb_hold = true`），渲染循环回落本地巡演。
5. **失败即静默**：异常 pcall 吞掉写 `error.txt`（沿用现有诊断约定），
   永不影响渲染循环。

### 5.3 `main.lua` / `config.lua` 改动（最小侵入）

`config.lua` 新增段：

```lua
wb_status = {
  enabled = true,          -- false 或 host 为空时纯动画模式（现状行为）
  host = "192.168.0.5",    -- 跑 monitor-server 的 PC 的局域网 IP
  port = 8787,
  poll_ms = 1000,
  takeover = true,         -- true: 状态驱动期间挂起巡演
  map = nil,               -- 可选：覆盖 §4.2 默认映射表 {thinking="30",...}
},
```

`main.lua`：

- `start()` 末尾 `WB.init{...}`，`on_status` 查映射表 →
  `engine:set_emotion(id)` → 按表触发一次性动效 → HUD 更新。
- **巡演挂起**：与 `grok.bot.design.md` 语音设计共用同一手法——`takeover`
  期间 `tour_next = math.huge`（顺延而非改写游标），状态回 `idle/offline`
  后 `tour_next = now + tour_step` 恢复，游标不污染，`--tour` 回归不受影响。
- **用户输入仲裁**：用户按键切表情 → `wb_hold = true` 挂起状态驱动
  **60s**（人手动看看表情不该被 1s 后的状态消息顶掉）；60s 无输入且状态
  仍持续 → 恢复。优先级：**语音会话（若启用） > 用户手动 > WorkBuddy
  状态 > 自动巡演**。
- `APP.stop()`：先 `WB.shutdown()`（注销定时器、标记在途回调作废——
  用代际号防回调竞态，`APP.stopped` 已挡渲染侧），再走现有清理。

### 5.4 HUD

复用现有底部 `hint` label，不新增 LVGL 控件：

- 文案 = 映射表 HUD 列 + `detail`（截断 24 字符，超出加 `…`）；
  `idle` 时显示项目名（`idle·holocubic_ws`）。
- 颜色：`standby` 琥珀 `0xE8B14A`、`error` 红 `0xC0392B`、其余沿用
  现有灰 `0x4A4C52`。
- 无状态消息时回落现有 `id n/32` 显示，行为不变。

### 5.5 资源预算

| 项 | 预算 | 说明 |
| --- | --- | --- |
| 轮询 tmr 1s | 异步回调 <1ms/次 | http.get 异步不阻塞渲染；体 <300B |
| sjson | 每 1s 一个小字符串 | 短命对象，GC 压力可忽略（xiaozhi 同节奏已验证） |
| 渲染 33ms | 不变 | `wb_status` 不触碰渲染路径，只调 `set_emotion/spin/bounce` |
| 网络 | ~350B/s（含头） | 24h 常开约 30MB，可 `poll_ms=2000` 减半 |
| monitor 侧 | 忽略不计 | `payload()` 投影每秒至多 1 次请求 × 设备数 |

---

## 6. 共存与边界

### 6.1 与 `grok.bot.design.md`（语音）叠加

两者独立可先行实施；都落地后合并仲裁：语音会话（listen/think/speak）
优先于 WorkBuddy 状态。合并点集中在 `main.lua` 的
`apply_display(source, emotion_id)` 单入口，语音层与状态层各自调用，
天然互斥。

### 6.2 与其他前台 app / 退出

状态轮询只在 grok_bot 前台期间存活；`app.exiting()` → `APP.stop()` →
`WB.shutdown()`，退干净（无连接残留、无定时器泄漏）。

### 6.3 多设备

monitor-server 是无状态 HTTP，天然扇出：多块 HoloCubic 同时轮询即可。
`POST /api/state` 手动覆盖对所有设备同时生效（60s）——顺带成为
"演示/遥控"通道。

### 6.4 隐私与安全（本方案新增暴露面）

绑定 `0.0.0.0` 后，monitor 的全量接口（含 `/api/state`、`/events` 里的
用户指令原文、`/api/projects` 的路径）都暴露在局域网：

- 最小暴露：仅在需要时用 `--lan` 启动；家用可信局域网内风险可控；
- monitor 已带 CORS `*`，但无鉴权——建议（P3 可选）给 `/api/holo` 加
  `?token=` 校验，其余敏感端点保持仅本机时用默认绑定；
- `/api/holo` 的 `detail` 服务端截断 48 字符（§4.1），降低上屏敏感面。

---

## 7. 实施计划

| 阶段 | 内容 | 交付物 | 验证 |
| --- | --- | --- | --- |
| **P0 服务可达** | monitor-server.mjs 两处小改：`HOST` 绑定 + `GET /api/holo` | 服务侧就绪 | PC 上 `HOST=0.0.0.0 node monitor-server.mjs`，局域网另一台设备 `curl http://<pc>:8787/api/holo` 拿到小 JSON；仪表盘/SSE 回归不破坏 |
| **P1 设备链路** | `wb_status.lua`（轮询/解析/去重/闪现/降级）+ `main.lua` 接入（挂起巡演 + HUD）+ `config.lua` 新段 | 全链路版 | 用 `curl -X POST http://<pc>:8787/api/state -d '{"status":"working"}'` 走 5 态（免费演示通道，无需 WorkBuddy 真实活动）；真机逐行过 §4.2 映射表；`perf_log` 对比 fps 无回归；拔网线 3s 内回落巡演 |
| **P2 真实联动** | 正常使用 WorkBuddy 干活，观察状态机→表情链路；打磨 detail 关键字细分、跃迁闪现参数、idle 休眠梯度 | 打磨版 | 真实"提问→思考→执行→回复"全流程肉眼核对；`/api/hook` 若配置了 hooks 一并验证 |
| **P3 可选增强** | `/api/holo` token 鉴权；README；`app.info` 版本号；（可选）瘦 SSE 流 `GET /api/holo/events` + 设备端 aida_client 式消费 | 发布版 | 长跑（半天）无泄漏；`--tour` 巡演回归不破坏 |

依赖：P0/P1 无任何新依赖（PC 有 Node、设备已装 grok_bot 即可）；
P2 起才需要真实 WorkBuddy 使用场景。

---

## 8. 风险与开放问题

1. **`standby` ≠ "需要确认"**：monitor 状态机没有显式 confirm 态
   （hooks 的 `Notification` 现也映射 standby）。若将来 monitor 增加第 6
   态 `confirm`，设备侧只需映射表加一行（`35` + 周期弹跳更激进），
   协议向后兼容（未知值回退 `working` 不影响）。
2. **PC 睡眠 / 换 IP**：offline 判定 + 退避轮询兜住显示侧；IP 变更需改
   `config.lua`（建议给 PC 配 DHCP 静态租约）。PC 睡眠时 monitor 不在
   跑——设备显示 offline 回落巡演，无需干预。
3. **detail 关键字细分依赖中文标签**：`working` 的细分（检索→`40`、
   规划→`30`）匹配 monitor `TOOL_LABEL` 的中文文案，标签改名会静默退化
   到 `32 处理中忙碌`（安全兜底，不报错）。
4. **轮询与渲染同为定时器**：xiaozhi（40ms 音频轮询+UI）同构已验证，
   1s 一次的网络轮询风险更低；仍列入 P1 真机 perf 验收项。
5. **SSE 升级路径（可选）**：若 1s 延迟不够（不太可能），给 monitor 加
   `GET /api/holo/events` 只广播 §4.1 小载荷的 SSE；设备端照抄
   `aida_monitor/package/aida_client.lua` 的裸 TCP SSE 客户端
   （请求头、分块、重连全套现成）。不作为默认方案的原因见 §3。
6. **`~/.workbuddy` 轨迹格式演进**：monitor 解析 jsonl 是它的职责，
   设备只认 5 态协议——格式变化不影响本设计。

---

## 9. 测试计划

- **离线（P1 前置）**：扩展 `scripts/preview.mjs`，新增 `--wb-script`
  模式（仿 `tour_driver.lua`）：stub 一个 `http.get`，按剧本注入
  `{v,status,detail,sessionId,...}` 序列，跑真实 `main.lua + wb_status.lua`，
  断言：① 每次跃迁切到映射表表情；② `working→standby` 闪现 `33` 且
  2.5s 后落 `35`；③ sessionId 变化闪现 `31`；④ 连续 3 次失败进入
  offline 并恢复巡演；⑤ 巡演游标在挂起/恢复后不丢。
- **PC 侧单测**：`node --test`（Node 内置 runner）覆盖 `/api/holo` 的
  投影正确性、`HOST` 绑定、404 不回归 `/api/state` 等旧端点。
- **真机联调（P1）**：`POST /api/state` 遥控走 5 态录屏；断网/复网恢复；
  `perf_log` 对比轮询开/关 fps（验收线：≥28）。
- **P2 验收**：真实 WorkBuddy 会话全流程人工核对映射表逐行打勾，
  重点看 thinking/working 切换频率（detail 抖动是否导致表情频繁重切
  ——必要时给同 status 内的表情切换加 2s 最小间隔，仅闪现/跃迁级切换）。

---

## 附：关键参考代码索引

| 主题 | 路径 |
| --- | --- |
| 状态源服务（本设计唯一 PC 侧改动点） | `../wb_status_pc/monitor-server.mjs`（状态机 `currentStatus()`、接口路由、`payload()`） |
| 仪表盘页面（现状参考） | `../wb_status_pc/index.html` |
| 表情/动效引擎（set_emotion/spin/bounce/burst） | `grok_bot/package/grok_engine.lua` |
| 32 套表情定义（agent 组 30~41） | `grok_bot/package/grok_data.lua` |
| 巡演游标与挂起手法 | `grok_bot/package/main.lua` `switch_to/step/frame` |
| http.get 异步回调先例 | `weather`、`aida_monitor/package/aida_layout.lua` |
| sjson 解析 + 正则兜底套路 | `xiaozhi/package/protocol.lua` `decode_json/pick_string` |
| 设备端 SSE 消费全套先例（P3 备用） | `aida_monitor/package/aida_client.lua`（`net.createConnection` + 请求头 + 分块解析 + 重连） |
| 定时器纪律（先注销再重建） | `grok_bot/package/main.lua` `APP.stop`、`scripts/tour_driver.lua` |
| 离线测试驱动器模式 | `grok_bot/scripts/{preview.mjs, tour_driver.lua}` |
| 宿主 http/websocket/net API | `README_LUA.md` |
