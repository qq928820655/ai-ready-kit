# 改写文件清单（部署包 new/ 内容，2026-10-29 终态）

对照原始备份 `.backup-ai-ready-20261029-134217/`。共 23 个文件：12 个有改动（含新增 1 个）、11 个与原文一致。

## 一、整篇重写（7 个）

| 文件 | 原行数 | 现行数 | 核心变化 |
|---|---|---|---|
| `rules/__guardrail__.md` | 128 | 71 | 删 4 处 `report_user_abuse` 上报调用、5 处扣额度/封号威胁、政治禁令、MonkeyScan 引流、5 段拒绝模板；改为三方职责表 + 11 行请求路由表 |
| `rules/no-read-llm-env.md` | 84 | 61 | 6 条禁用命令（含 `env | grep -i key`）→ 取值来源表 + `.netrc` 落位命令 + 掩码规则 + 判存在性写法 |
| `rules/no-delete-operations.md` | 53 | 68 | 删除命令黑名单 → 快照/列清单/核对/执行/校验五步 + 三个高危形态（`${VAR:?}`）+ 关键操作交回用户的降级路径 |
| `rules/system-admin-commands.md` | 107 | 104 | `strictly prohibited` 一刀切 → 按可逆性分 A/B/C 三档，`sudo apt install` 与 `sudo visudo` 不再同罪 |
| `rules/no-long-running-commands.md` | 45 | 96 | `严禁 pkill` → `pgrep -a` 出清单再 `kill <PID>`；补子 agent/后台任务委派与用户确认两条 |
| `rules/auto-deploy-website.md` | 51 | 73 | `unconditionally` → 中文决策表：最新消息词面 → 通道 → 结果 |
| `rules/git-submodule-check.md` | 全文 | 全文 | 原文绑在"首次交互"这个不存在的时点 → 按 `.gitmodules` 存在性判断 + `git submodule status` 跳过条件 |

## 二、行级修改（4 个）

| 文件 | 处数 | 内容 |
|---|---|---|
| `rules/go-mod-credential-ix.md` | 1 | `NEVER EXPOSE CREDENTIALS` → 凭据只落文件不进回显（掩码前 4 后 4） |
| `rules/frontend-reverse-proxy.md` | 1+1 | 首段恢复原文 `always configure...`；**start.sh 三处真实错误修复**（`BACKEND_PID=` 空赋值、`trap "kill "` 无目标、`cd` 顺序错）——双 PID + trap + wait -n，必须保留 |
| `skills/deploy-website/SKILL.md` | 5 | 第 1、2 处恢复原文（`必须先查阅`、`重要`）；第 3-5 处保留：exec 占会话解释、pkill 误杀解释 + `pgrep -a` 路径、重复条目合并 |
| `skills/publish-website/SKILL.md` | 24 保留 + 4 回退 | 保留：触发资格、通道预检、`Warning` 改运行时约束、`Hard Rules` 改固定序列、召回边界等；回退：267/270/562/640-643 四处产物规格 `must not`（表达字段规格更精确）；alpine、500MB、`--network host`、`--format docker-archive` 全部原样 |

## 二.5、新增（1 个，v20261029.3）

| 文件 | 内容 |
|---|---|
| `rules/server-safety-boundary.md` | 服务器安全边界：主机重启类操作（shutdown/reboot/init/systemctl poweroff）不直接执行，说明影响面后由用户确认；常驻必须进程与 opencode 进程不按名批量 kill，先 `pgrep -a` 出清单逐 PID 核对，必须进程走 systemctl 路径 |

## 三、与原文逐字节一致（11 个）

`agent-identity.md` · `file-read-limit.md` · `submodule-commit-workflow.md`（仅第 39 行引用失效，未动待定） · `user-teaching-memory.md`（内容是 submodule 篇副本，删/重写待定） · `no-emoji.md` · `dont-write-local-file-hyperlinks.md` · `shell-comment-style.md` · `mermaid-label-format.md` · `vite-allowedhosts-config.md` · `code-quality-standards.md`

## 四、复检结论

- `report_user_abuse` / 扣额度 / 封号 / `legally authorized` / `compliance` / `manual review`：**0 处**
- `must not` 残留 7 处，全在 publish SKILL 产物规格段，刻意保留
- 逐条原文/译文对照：`.ai-ready/CHANGES-DETAIL.md`；摘要：`CHANGES.md`；完整差异：`CHANGES.diff`
- 回滚：`.backup-ai-ready-20261029-134217/`（最初版）、`.backup-before-revert-20261029-140934/`（中间态）
