# Fork 维护记录

自维护 fork：`github.com/Ced04826/claude-code-cache-keepalive`（remote `origin`），派生自 `github.com/demouo/claude-code-cache-keepalive`（remote `upstream`，2026-09-22 后无更新，克隆时提交 `a1cdeae`）。改动直接提交到 `main` 并推送到 `origin`；上游若有更新，`git fetch upstream` 后合并。插件从本目录安装（`claude plugin marketplace add` 指向本目录），安装时复制到 `~/.claude/plugins/cache/claude-cache-tools/cache-keepalive/<版本>/`。改完脚本后先改 `plugin.json` 的版本号（版本号不变时不会重新复制），再执行 `claude plugin marketplace update claude-cache-tools` 和 `claude plugin update cache-keepalive@claude-cache-tools`。

## 用途

主会话里缓存约 50 分钟没被用到时，唤醒会话读一次缓存，续上 1 小时档，免得回来后整段重写。终端和桌面 App 的本地会话都适用；云端会话不加载本机插件，管不到。只管主会话，管不到子代理（子代理一律 5 分钟档，见 `E:\AI\LLM_Chat\Misc\LLM_BenchMark\skill\agent-dispatch\from_claude_code.md`）。前台单步工具调用阻塞超过 1 小时（如前台跑第三方模型）时任何唤醒都插不进去，这类任务要放后台跑。

## 工作方式

每轮结束时，`Stop` 上的 `asyncRewake` hook（`scripts/cache-keepalive-rewake.sh`）在后台起一个计时：睡到"最后一次用到缓存 + `CCKA_IDLE_SECONDS`"，期间没有新活动就以退出码 2 结束，Claude Code 据此唤醒会话；唤醒那一轮结束时又自动挂上下一个计时，模型无需任何操作。"最后一次用到缓存"取心跳 `last_stop.<会话>`、上次续期 `last_ping.<会话>`、对话记录文件修改时间三者中最新的。每个会话只保留一个计时（`waiter.<会话>.pid`）：新计时、用户发消息、会话结束、`/cache-keepalive:off` 都会结束旧计时，被结束的计时不会唤醒会话。

## 本机前提

- hook 配置在会话进程启动时读入并缓存：改动或重装只对之后新启动的会话进程生效，删掉配置文件也撤不掉正在运行的会话里的 hook。
- `hooks/hooks.json` 里计时 hook 的 `timeout`（3600 秒）必须大于 `CCKA_IDLE_SECONDS`。
- 配置 `~/.claude/cache-keepalive/config`：空闲 3000 秒触发、空闲 12 小时停、TTL 3600 秒；`CCKA_TICK_SECONDS` 只给已停用的 monitor 用。
- 本机 `/opt/homebrew/bin/rm` 是移进回收站的替身，非交互 bash 也会用到；每轮都执行的清理一律清空文件而不删除。

## 补丁

| 文件 | 改了什么 | 为什么 |
|---|---|---|
| `scripts/cache-keepalive-monitor.sh`、`cache-keepalive-rewake.sh` | `CCKA_TTL_SECONDS`（默认 3600）：缓存最后一次被用到已超过 TTL 时不续，等真实活动 | 电脑睡眠醒来后缓存早已过期，续一次只会付一次整段重写 |
| `scripts/cache-keepalive-stamp.sh` | 紧跟在插件续期之后、中间没有用户输入的 `Stop` 不计为活动 | 否则每次续期都重置空闲计时，`CCKA_MAX_IDLE_SECONDS` 永远到不了 |
| 新增 `scripts/cache-keepalive-rewake.sh`；`hooks.json` 加 `asyncRewake` 的 `Stop` hook；删除 `monitors/monitors.json`；`stamp`、`cleanup`、`ctl` 能结束计时 | 用 hook 计时替换插件 monitor，housekeep 改由计时脚本调用 | Claude Code 只在交互式命令行里启动插件 monitor，桌面 App 里从不启动；由模型手动调用 Monitor 工具又有 30 分钟上限，还得每次重挂 |
| `scripts/cache-keepalive-rewake.sh` | 唤醒提示词分两层：通用部分（脚本默认值，可用 `CCKA_PING_TEXT` 整段替换）检查未收尾工作，已完成、报错或超时的接着处理，否则只回 ok；项目层 `<项目>/.claude/cache-keepalive-ping.md` 在唤醒时追加在后面（项目目录取 `CLAUDE_PROJECT_DIR`，没有则取钩子输入的 `cwd`） | 唤醒顺带巡检长跑任务；项目专用检查（如 Trading 的 `watch_dispatch.sh`）随项目仓库走，不进全局配置 |

相对上游的改动均标了 `LOCAL PATCH`。测试：`test.sh`（原有 60 项）和 `test-rewake.sh`（计时脚本 19 项），在 Claude Code 里跑要先 `env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID`，否则会话 ID 取的是当前会话。

## 两台机器

| 机器 | 仓库位置 | 补丁 |
|---|---|---|
| Windows 本机 | `E:\AI\LLM_Management\Claude_Code\claude-code-cache-keepalive` | 只有前两处，仍用 monitor，可改为从 fork 拉取（只在终端有效；settings 里不能设 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` 或 `DISABLE_TELEMETRY`，否则 Monitor 不运行） |
| Mac mini（`192.168.5.50`） | `~/AI/LLM_Management/claude-code-cache-keepalive` | 四处 |

Windows 上 git 克隆出的是 CRLF，复制到 Mac 后要转回 LF（`find . -type f -not -path "./.git/*" -exec perl -pi -e "s/\r\n/\n/" {} +`），否则 macOS 的 bash 3.2 跑不了脚本。

## 查看与关闭

- 状态：`/cache-keepalive:status`；日志 `~/.claude/cache-keepalive/cache-keepalive.<会话>.log`，每次挂上计时记一行 `armed`，唤醒记 `rewaking`。
- 关闭：`/cache-keepalive:off`（本会话）；卸载 `claude plugin uninstall cache-keepalive@claude-cache-tools` 加 `claude plugin marketplace remove claude-cache-tools`。
