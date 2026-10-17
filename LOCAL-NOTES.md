# 本机改造记录

`github.com/demouo/claude-code-cache-keepalive`（克隆于 2026-10-12，上游提交 `a1cdeae`）的本地副本，带两处未上游化的补丁。插件从本目录安装（`claude plugin marketplace add` 指向本目录），安装时复制到 `~/.claude/plugins/cache/claude-cache-tools/cache-keepalive/<版本>/`。`git pull` 会冲掉补丁；更新后重打补丁，再 `claude plugin install cache-keepalive@claude-cache-tools` 重装。

## 用途

主会话空闲约 50 分钟时续一次 1 小时档缓存，免得回来后整段重写。只管主会话，管不到子代理（子代理一律 5 分钟档，见 `E:\AI\LLM_Chat\Misc\LLM_BenchMark\skill\agent-dispatch\from_claude_code.md`）。

## 本机前提

- 依赖 Monitor 工具，`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` 和 `DISABLE_TELEMETRY` 任一设置都会让它不运行。2026-10-12 起 `~/.claude/settings.json` 去掉了前者，改为单独设 `DISABLE_AUTOUPDATER`、`DISABLE_ERROR_REPORTING`、`DISABLE_BUG_COMMAND`，只放开遥测。改前原样在 `~/.claude/archive/settings_261012_before_keepalive.json`。
- 只在交互式命令行会话里运行。
- 配置 `~/.claude/cache-keepalive/config`：空闲 3000 秒触发、5 分钟检查一次、空闲 12 小时停、TTL 3600 秒（补丁 1 用）。

## 补丁

| 文件 | 改了什么 | 为什么 |
|---|---|---|
| `scripts/cache-keepalive-monitor.sh` | 新增 `CCKA_TTL_SECONDS`（默认 3600）：缓存最后一次被用到（真实活动或上次续期）已超过 TTL 时不续，等真实活动 | 电脑睡眠醒来后缓存早已过期，原版会立刻续一次，只会付一次整段重写 |
| `scripts/cache-keepalive-stamp.sh` | 紧跟在插件续期之后、中间没有用户输入的 `Stop` 不计为活动 | 原版每次续期回合的 `Stop` 都重置空闲计时，`CCKA_MAX_IDLE_SECONDS` 永远到不了，会话开着就一直续 |

两处都标了 `LOCAL PATCH`。验证方式：用很短的时间参数和临时 `CCKA_STATE_DIR` 跑脚本，在 Claude Code 里测要先 `env -u CLAUDE_CODE_SESSION_ID`，否则会话 ID 取的是当前会话。

## 两台机器

| 机器 | 仓库位置 | settings.json 的 env |
|---|---|---|
| Windows 本机 | `E:\AI\LLM_Management\Claude_Code\claude-code-cache-keepalive` | 去掉 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`，单设 `DISABLE_AUTOUPDATER`、`DISABLE_ERROR_REPORTING`、`DISABLE_BUG_COMMAND` |
| Mac mini（`192.168.5.50`） | `~/AI/LLM_Management/claude-code-cache-keepalive` | 用户已把 `NONESSENTIAL` 改名为 `_off_…` 停用；2026-10-12 加 `DISABLE_AUTOUPDATER`、`DISABLE_ERROR_REPORTING`，改前原样在 `~/.claude/archive/settings_261012_before_keepalive.json` |

两边都打了同样两处补丁，配置文件相同。Mac 的副本从 Windows 复制过去：Windows 上 git 克隆出的是 CRLF，复制后要在 Mac 上转回 LF（`find . -type f -not -path "./.git/*" -exec perl -pi -e "s/\r\n/\n/" {} +`），否则 macOS 的 bash 3.2 跑不了脚本。两处补丁在 bash 3.2 上测过。

## 查看与关闭

- 状态：新会话里 `/cache-keepalive:status`；日志 `~/.claude/cache-keepalive/cache-keepalive.<会话>.log`。
- 关闭：`/cache-keepalive:off`（本会话）；卸载 `claude plugin uninstall cache-keepalive@claude-cache-tools` 加 `claude plugin marketplace remove claude-cache-tools`。
