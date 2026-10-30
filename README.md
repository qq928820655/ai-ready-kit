# ai-ready-kit

`.ai-ready` 规则目录的替换 / 还原工具。仓库里两个文件：

| 文件 | 作用 |
|---|---|
| `toggle-ai-ready.sh` | 主脚本（安装器 + 菜单 + 全部子命令） |
| `ai-ready-payload.tar.gz` | 载荷包，解包后是 `new/rules/` 与 `new/skills/`（22 个改写后的规则文件） |

---

## 一、安装

```bash
curl -fsSL https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main/toggle-ai-ready.sh | sh
```

装完直接进菜单。**安装本身不改动任何项目**，只有你在菜单里选「2) 替换」才会写目标目录。

raw 域名连不上时脚本会自动回退 jsDelivr → ghproxy，也可以自己指定：

```bash
AIREADY_URL_BASE=https://cdn.jsdelivr.net/gh/qq928820655/ai-ready-kit@main \
  curl -fsSL https://cdn.jsdelivr.net/gh/qq928820655/ai-ready-kit@main/toggle-ai-ready.sh | sh
```

装好后的短命令（root 或 `/usr/local/bin` 可写时自动建）：

```bash
ai-ready
```

没有短命令时用全路径：

```bash
bash /workspace/.ai-ready-kit/toggle-ai-ready.sh
```

---

## 二、重复执行的行为

同一条 `curl | sh` 命令可以反复执行，脚本按下面顺序判断：

| 现场状态 | 动作 |
|---|---|
| 没装过 | 落地脚本 + 载荷 → 进菜单 |
| 已装，远端版本相同 | 跳过更新，直接进菜单（约 1 秒，走 `.updatecheck` 缓存） |
| 已装，远端版本更高 | 先更新脚本与 `new/`，再 exec 新版本进菜单 |
| 已装，连不上远端 | 提示一行，用本地版本直接进菜单 |
| 已装，`new/` 被删或残缺 | 视为未装，重新落地 |

版本检查结果缓存 600 秒（`AIREADY_UPDATE_TTL` 可改）。离线环境想跳过检查：

```bash
AIREADY_SKIP_UPDATE=1 ai-ready
```

---

## 三、菜单

主菜单 6 项，每个动作下面再选一次具体参数：

```
===== .ai-ready 工具包 v2026103010 =====
已装 v2026103010   目标 2 个

  1) 目标与状态   列目标 + 一致性，可展开差异
  2) 替换         选目标 → 全部/仅 rules/仅 skills，完成后自动开监控
  3) 还原         选目标 → 选备份，完成后自动关监控
  4) 版本与更新   版本信息，有新版时询问
  5) 维护         修复 / 重装 / 卸载
  6) 实时监控     运行中 pid 14591
  0) 退出

选择 [1-6，0=退出，回车=取消]:
```

第 6 项实时显示监控状态，进去是 启动 / 停止 / 立即巡检 / 改模板 / 看日志。

**菜单里的联动**：`2) 替换` 成功后自动开启监控——替换等于切到改写版，理应有人守着；`3) 还原` 成功后自动关闭监控——还原等于回原始版，不该再被自动写回去。已开着的不会重复拉起，已关着的不会空转。手动开关仍在第 6 项，两处不冲突。

**回车语义**：主菜单回车＝取消（不执行任何动作，直接重画菜单）；进了某一路之后，
每个子提示回车都取第一个选项，确认提示回车＝`y`：

| 提示 | 回车结果 |
|---|---|
| `选择 [1-5，0=退出，回车=取消]:` | 取消，回到菜单 |
| `选择 [1-N/m，回车=1]:` | 第 1 个目标 |
| `范围 [1-3，回车=1]:` | 全部（rules + skills） |
| `选择 [1-N，回车=最近一次]:` | 最近一次备份 |
| `替换 …?[Y/n]:` / `看逐文件差异?[Y/n]:` / `现在更新?[Y/n]:` / `卸载…?[Y/n]:` | `y` |

**1) 目标与状态** — 一次列出全部目标，每个给一行摘要，不用先选目标：

```
目标 2 个（载荷 25 个文件）:
  1) /workspace/projA/.ai-ready
     部分一致（同 12 / 异 12 / 缺 1）
  2) /workspace/projB/.ai-ready
     一致 25/25
输入编号看详情 [1-2，回车=1]:
```

输入编号（回车＝第 1 个）→ 逐文件对比 → 再问「看逐文件差异?」，回车即展开 unified diff。

**2) 替换** — 选目标（回车=1）→ 选范围（1 全部 / 2 仅 rules / 3 仅 skills，回车=1）→ 确认（回车=y）。范围选完才动手，替换前自动快照。

**3) 还原** — 选目标 → 列备份。第 1 项固定是「最近一次」（还原点指向的那次），回车即用它；后面按时间倒序列出历史备份，前面带 `← 还原点` 标记的是当前指向。

**4) 版本与更新** — 先打一份版本信息（KIT 目录 / 脚本版本 / 已装版本 / 载荷数 / 远端地址 / 目标数），再查远端：有新版就问一句「现在更新?」，`y` 更新并自动重启到新版本；已最新只报一行。

**5) 维护** — 二级菜单（回车=1 修复）：修复 `new/`（只重下载荷）、强制重装（脚本 + 载荷）、卸载。

下面每个动作在命令行也都能单独调，见第四节。

目标探测范围默认 `/workspace` 与 `/root`（两个目录都扫，去重），最深 6 层，跳过 `node_modules` 与 `.git`。要换根：

```bash
SEARCH_ROOT=/data ai-ready list
```

---

## 四、子命令

```bash
ai-ready info                            # 安装状态 / 版本 / 目标数
ai-ready check                           # 只查版本：0=有新版 1=已最新 2=连不上
ai-ready update                          # 安装或更新，不动任何目标
ai-ready repair                          # 只重下载荷，重建 new/
ai-ready list                            # 探测目标
ai-ready status  /workspace/projA        # 逐文件对比现网与 new/
ai-ready diff    /workspace/projA        # 输出 unified diff
ai-ready replace /workspace/projA              # 全部替换
ai-ready replace /workspace/projA --rules      # 只换 rules
ai-ready replace /workspace/projA --skills     # 只换 skills
ai-ready backups /workspace/projA        # 列备份，* 标出还原点
ai-ready restore /workspace/projA               # 还原到最近一次
ai-ready restore /workspace/projA 20261029-161436
ai-ready uninstall                       # 卸载 kit，目标项目不受影响
```

管道里带参数执行（首次会先自动安装）：

```bash
curl -fsSL https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main/toggle-ai-ready.sh \
  | sh -s -- replace /workspace/projA
```

---

## 五、目录与备份

```
/workspace/.ai-ready-kit/
├── toggle-ai-ready.sh          主脚本
├── new/                        载荷解包结果（rules/ + skills/）
├── .installed                  安装版本与时间
├── .base                       命中的下载源
├── .updatecheck                版本检查缓存（TS / VER）
└── backups/
    ├── <目标slug>/<时间戳>/     每次替换前的完整快照（cp -a，保权限保时间）
    └── .markers/<目标slug>      指向"最近一次可还原点"
```

- 每次 `replace` 前自动快照，重复替换不会互相覆盖；
- `restore` 会先把当前状态也快照一份，所以还原本身可再还原（来回切）；
- 卸载只删 kit 目录内的内容，不碰任何项目的 `.ai-ready`。

---

## 六、环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `AIREADY_URL_BASE` | `https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main` | 指定后只用它，不走镜像回退 |
| `AIREADY_KIT_DIR` | `/workspace/.ai-ready-kit` | 安装目录 |
| `AIREADY_SKIP_UPDATE` | 空 | 非空则跳过启动时版本检查 |
| `AIREADY_UPDATE_TTL` | `600` | 版本检查缓存秒数 |
| `AIREADY_NO_TTY` | 空 | 非空则按无终端处理，不进菜单（cron/CI） |
| `SEARCH_ROOT` | `/workspace /root` | 目标探测根目录 |

---

## 七、下载源与缓存

脚本按 raw → jsDelivr → ghproxy 顺序探测，第一个成功的写进 `.base`，之后优先用它。

| 源 | 更新延迟 | 备注 |
|---|---|---|
| `raw.githubusercontent.com` | 约 5 分钟 | 主通道 |
| `cdn.jsdelivr.net/.../@main` | 最长 12 小时（分支引用缓存） | 回退通道 |
| `ghproxy.net` | 跟随 raw | 回退通道 |

刚发版、CDN 还在吐旧内容时，把 URL 里的 `@main` 换成具体 commit sha 立刻能拿到新版：

```bash
SHA=$(gh api repos/qq928820655/ai-ready-kit/commits/main --jq .sha)
curl -fsSL "https://cdn.jsdelivr.net/gh/qq928820655/ai-ready-kit@${SHA}/toggle-ai-ready.sh" | sh
```

同一份脚本里 `AIREADY_URL_BASE` 也可以直接指到 sha 路径，载荷会跟着一起取。

### 缓存源的版本复核

CDN 的分支引用有缓存，可能几小时内一直吐旧文件。脚本对此做了两道防护：

1. `check` / 菜单进版本菜单时，若命中源不是主通道（`raw.githubusercontent.com`），
   再向主通道要一次版本号，取较新者；主通道更高就同时作废 `.base` 缓存。
2. `update` 下载完脚本后，若拿到的版本不比当前新、且来源是镜像，作废 `.base` 并强制回主通道重下一次。

所以即便之前缓存到了落后的 jsDelivr 地址，也不会卡在旧版本，更不会把版本往回带。
显式设置 `AIREADY_URL_BASE` 时不做这套复核，只走你指定的源。

---

## 八、实时监控（切模型后被重置）

平台在「创建任务 / 重启会话 / 切换模型」时会重放 agent 资源，`~/.codingmatrix/project-tpl/.ai-ready/` 下的 rules 被重铺成原始版——手法固定为 `create .xxx.tmp.<随机数>` → `rename`。

监控直接盯那个目录，三层从快到慢：

| 层 | 触发 | 延迟 |
|---|---|---|
| inotify 事件 | `CLOSE_WRITE` / `MOVED_TO` / `CREATE` / `DELETE` | 毫秒级，实测 0.05s 内写回 |
| 静默合并 | 同批事件停 60ms 收齐，只比对一次 | 避免 20 个文件触发 20 轮扫描 |
| 轮询兜底 | 无事件时每 1s 全量比对（26 文件，微秒级） | 覆盖丢事件 / 队列溢出 / 目录被整棵换掉 |

另加一个 **opencode 进程检测**：`/proc/*/comm` 出现新的 `opencode` pid 时立刻比对一次，堵住「重铺 → 重启」之间的窗口。切模型时两层经常接上：事件层先修完，进程启动时 `DIFF_NOW=0`，什么都不用做。

**装完即守**，不需要额外执行任何命令：

```bash
curl -fsSL https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main/toggle-ai-ready.sh | sh
```

安装流程走到最后一步会自动拉起守护进程（`AIREADY_NO_WATCH=1` 可关掉这个默认行为）。之后：

```bash
ai-ready guard start          # 启动（已在跑则重启，同时重烤基准）
ai-ready guard stop           # 停止
ai-ready guard restart        # 重启
ai-ready guard once           # 立即巡检模板目录并写回
ai-ready guard status         # pid / 存活 / 当前差异数 / 最近日志
ai-ready reapply              # 另一回事：巡检「目标项目」的 .ai-ready 并回写
```

菜单入口：`6) 实时监控`（启动 / 停止 / 立即巡检 / 改模板 / 看日志）。

守护脚本以 base64 内嵌在 `toggle-ai-ready.sh` 里，安装时解码落到 `$KIT_DIR/bin/aiready-watch.py` 并做 AST 校验。所以 `curl` 单文件就能装完，不依赖仓库里的第二个文件，也不会因为 raw 域名限流装到一半。

日志在 `$KIT_DIR/watch.log`（超 512KB 自动截尾），基准副本在 `$KIT_DIR/.gold`。

`template apply` 的意义：如果重置是把某个 `*project-tpl*` 目录重新铺一遍，把模板本身改掉之后，重置结果天然就是改写版，监控只剩兜底。
