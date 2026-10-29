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

装完直接进菜单。**安装本身不改动任何项目**，只有你选 8/9/10 才会写目标目录。

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

```
 -- 安装维护 --
   1) 安装状态 / 版本信息       (info)
   2) 检查更新                 (check)
   3) 安装 / 更新到最新版       (update)
   4) 重新解包 new/（修复）      (repair)
   5) 卸载本工具包              (uninstall)
 -- 目标操作 --
   6) 重新探测目标列表          (list)
   7) 查看目标状态              (status)
   8) 替换全部 rules + skills   (replace)
   9) 只替换 rules              (replace --rules)
  10) 只替换 skills             (replace --skills)
  11) 查看差异                  (diff)
 -- 备份还原 --
  12) 备份列表                  (backups)
  13) 还原最近一次备份           (restore)
  14) 还原到指定备份             (restore <时间戳>)
   0) 退出
```

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
