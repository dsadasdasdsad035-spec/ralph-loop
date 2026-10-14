# Ralph 看板测试

看板的所有验收都在这里，可以用一条命令重跑。测试**不碰你的项目**：夹具是临时目录里现造的
git 仓库，脚本只读它们，跑完可以整个删掉。

```bash
bash tests/run-all.sh
```

| 套件 | 覆盖什么 | 依赖 |
|---|---|---|
| `test-state.sh` | `ralph-state.sh` 的正常态（循环中 / 已完成 / 卡住）与全部降级输入：缺 `prd.json`、PRD 损坏、非 git 目录、空仓库（无提交）、`events.jsonl` 损坏、缺 `progress.txt`。降级时必须仍然输出合法 JSON，并如实说明缺什么 | bash、jq、git |
| `test-headless.sh` | 用假代理真实驱动 `scripts/ralph.sh`：每轮事件写入、`--dashboard` 起停与残留进程、循环进行中看板返回 running/实现中/当前故事、卡住判定、完成即停 | bash、jq、git、curl、python3（看板服务） |
| `test-ui.py` | 真浏览器（Chromium）验收：四种状态的页面结构、改盘后 2 秒内自动刷新、阶段推进（实现中 → 收尾）、时间线联动、自动刷新开关、快照走 `file://` 且数据内嵌、会话内片段的明暗两种主题 | python3 + playwright（`pip install playwright && playwright install chromium`）；没有 playwright 时该套件报 SKIP 而不是失败 |

产物与截图落在 `$RALPH_TEST_DIR`（默认 `${TMPDIR}/ralph-plugin-tests`，可用环境变量覆盖）：

```bash
RALPH_TEST_DIR=/tmp/my-ralph-tests bash tests/run-all.sh
open /tmp/my-ralph-tests/shots          # 浏览器验收的截图
```

夹具的三种状态由 `make-fixture.sh` 生成（`running` / `complete` / `blocked`），
时间戳都是相对"现在"的，所以"最近活动 2 分钟前""进行中"这类相对时间逻辑会被真实检验；
`fake-agent.sh` 是 `--tool custom` 用的假迭代代理，`FAKE_AGENT_SLEEP` 控制单轮耗时，
`FAKE_AGENT_NOOP=1` 用来复现卡住的循环。

片段预览会优先使用本机 ZCode 安装里的 `visualize.css`（宿主设计系统），找不到时用内置回退样式，
并在输出里说明用的是哪一种 —— 预览只是验收手段，真正的渲染由 ZCode Desktop 的 Gen UI 完成。
