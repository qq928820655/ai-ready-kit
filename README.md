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

主菜单 5 项，每个动作下面再选一次具体参数：

```
===== .ai-ready 工具包 v2026103001 =====
已装 v2026103001   目标 2 个

  1) 目标与状态   列目标 + 一致性，可展开差异
  2) 替换         选目标 → 全部 / 仅 rules / 仅 skills
  3) 还原         选目标 → 选备份（回车=最近一次）
  4) 版本与更新   版本信息，有新版时询问
  5) 维护         修复 / 重装 / 卸载
  0) 退出
```

**1) 目标与状态** — 一次列出全部目标，每个给一行摘要，不用先选目标：

```
目标 2 个（载荷 25 个文件）:
  1) /workspace/projA/.ai-ready
     部分一致（同 12 / 异 12 / 缺 1）
  2) /workspace/projB/.ai-ready
     一致 25/25
输入编号看详情，回车返回:
```

输入编号 → 逐文件对比 → 再问一句「看逐文件差异?」展开 unified diff。

**2) 替换** — 选目标 → 选范围（1 全部 / 2 仅 rules / 3 仅 skills，回车=1）→ 确认 `y`。范围选完才动手，替换前自动快照。

**3) 还原** — 选目标 → 列备份。第 1 项固定是「最近一次」（还原点指向的那次），回车即用它；后面按时间倒序列出历史备份，前面带 `← 还原点` 标记的是当前指向。

**4) 版本与更新** — 先打一份版本信息（KIT 目录 / 脚本版本 / 已装版本 / 载荷数 / 远端地址 / 目标数），再查远端：有新版就问一句「现在更新?」，`y` 更新并自动重启到新版本；已最新只报一行。

**5) 维护** — 二级菜单：修复 `new/`（只重下载荷）、强制重装（脚本 + 载荷）、卸载。

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
