# Ralph for ZCode

ZCode 移植版 Ralph —— 自主 AI 编码循环。每一轮迭代都是**全新上下文**的代理实例，它只实现一个
`prd.json` 用户故事，跑完项目自己的检查后提交，并把经验追加到 `progress.txt`。迭代之间的记忆只存在于
三处：git 历史、`prd.json`、`progress.txt`。

上游项目：[snarktank/ralph](https://github.com/snarktank/ralph)（基于
[Geoffrey Huntley 的 Ralph 模式](https://ghuntley.com/ralph/)）。本仓库是它的 ZCode 插件化改造。

## 与上游的差异

上游依赖外部的 `amp` / `claude` CLI 来派生每一次迭代。ZCode 没有对应的 `zcode` 无头 CLI，所以本插件
提供**两条路径**，语义一致：

| 路径 | 驱动方式 | 适用场景 |
|---|---|---|
| `ralph-run` 技能（推荐） | 在 ZCode 会话内，每轮用 `Agent` 工具起一个全新上下文的子代理 | 直接在当前会话里跑；无需额外安装任何 CLI |
| `scripts/ralph.sh` | bash 循环，通过 stdin 把提示词喂给 `claude` / `amp`（或 `--tool custom` 指定任意命令） | 已经装了编码 CLI、想做无头长跑 |

此外：
- 迭代提示词从 `prompt.md` / `CLAUDE.md` 合并为插件内的 `templates/iteration-prompt.md`，由脚本渲染
  （`{{PROJECT_DIR}}` 等占位符），改一处即可，不会两份漂移。
- `dev-browser` 技能替换为 ZCode 的浏览器能力 `browser-use:web-gui-tester` / `browser-use:control-browser`。
- 上游的 `CLAUDE.md` 更新约定改为 `AGENTS.md`（ZCode 自动读取的指令文件）。
- 上游的 `flowchart/` 是一个静态的讲义式流程图站点；本插件改为**由项目真实产物驱动的只读看板**
  （`/ralph-dashboard`）：任务状态、当前阶段、迭代时间线都来自磁盘上的文件，不靠示例数据摆样子。

## 安装

把本目录（`plugins/`）作为本地插件市场添加，再安装 `ralph` 插件。详见交付说明中的
「插件市场 → 添加 → 添加插件市场」。

## 用法

```text
/prd 任务优先级系统              # 1. 生成 PRD → tasks/prd-task-priority.md
/ralph tasks/prd-task-priority.md # 2. 转成 prd.json
/ralph-run                       # 3. 跑循环，直到所有故事 passes: true
```

`/ralph-run 20` 可指定最大迭代次数（默认 10）。

也可以直接对话触发：`prd` / `ralph` / `ralph-run` 三个技能都会按描述自动加载。

### 无头运行（可选）

```bash
bash scripts/ralph.sh --dir /path/to/project --tool claude 10
bash scripts/ralph.sh --dir . --tool custom --cmd "my-agent --auto" 10
bash scripts/ralph.sh --dir . --dashboard            # 跑循环的同时起看板并打印 URL
bash scripts/ralph.sh --dir . --prepare-only     # 只做 preflight，输出状态 JSON
bash scripts/ralph.sh --dir . --render-prompt 1  # 只渲染第 1 轮提示词
```

## 看板（只读管理员页面）

`/ralph-dashboard` 打开一个本地页面，看 `prd.json` 的任务情况和循环的实时流程。
它**只读**：全部数据来自 `prd.json`、`progress.txt`、git 历史、`.ralph/events.jsonl` 与
`archive/`，读不到的东西会明确报缺，绝不编造进度。

三种用法：

| 方式 | 命令 | 说明 |
|---|---|---|
| 实时看板（推荐） | `/ralph-dashboard` 或 `scripts/ralph-dashboard.sh --dir <项目>` | 起一个只监听 127.0.0.1 的小服务并打印 URL；页面每 2 秒重读磁盘，循环跑着时是活的。`--stop` 停止 |
| 静态快照 | `scripts/ralph-dashboard.sh --snapshot out.html --dir <项目>` | 生成自包含单文件（数据内嵌），双击打开；不会自动更新 |
| 会话内视图 | `/ralph-dashboard 会话内` | 在 ZCode Desktop 里把看板直接渲染进对话（静态快照） |

无头跑循环时加 `--dashboard` 即可边跑边看，退出时服务随之停止。

页面内容：

- **任务看板** — 每个故事的状态（已完成 / 进行中 / 待办 / 已卡住）、优先级、验收标准、
  关联提交（含文件级增删行）、`progress.txt` 里的每一次尝试记录（含卡住的诊断）。
- **流程视图** — 写 PRD → 转 `prd.json` → 启动循环 → 挑故事 → 实现 → 跑检查 → 提交 →
  更新 `prd.json` → 写 `progress.txt` → 还有故事？的回环图；走过的路径点亮，当前阶段脉冲，
  故事令牌停在当前节点。
- **迭代时间线** — 每一轮的耗时与结果（绿=完成、琥珀=卡住、蓝=进行中），点一下跳到对应的故事卡。
- **代码库经验 / 历史运行** — `progress.txt` 的 `Codebase Patterns` 汇总，以及 `archive/` 里往次运行的完成度。

准确性说明：阶段以 `.ralph/events.jsonl` 的事件为准（`ralph-run` 技能与 `ralph.sh` 都会写）。
旧版本跑出的项目没有事件文件时，会回退为「最新提交 + `prd.json` 状态」的推断，并在页面上标注
「推断」；子代理执行期间「实现」与「跑检查」无法从磁盘区分，统一记为「实现中」。

## 测试

看板的验收套件在 `tests/`，一条命令重跑（夹具是临时目录里现造的 git 仓库，不碰你的项目）：

```bash
bash tests/run-all.sh
```

覆盖状态提取器的正常态与降级输入（缺 PRD / PRD 损坏 / 非 git 仓库 / 空仓库 / 事件文件损坏）、
无头循环的阶段事件与 `--dashboard` 起停、以及真浏览器里的四状态页面 / 改盘自动刷新 / 快照 /
会话内片段（明暗两套主题）。依赖与产物位置见 `tests/README.md`。

## 关键文件

| 文件 | 作用 |
|---|---|
| `skills/prd/SKILL.md` | 生成 PRD（含澄清问题、可验证验收标准） |
| `skills/ralph/SKILL.md` | PRD → `prd.json`，故事拆分与依赖排序规则 |
| `skills/ralph-run/SKILL.md` | 会话内循环编排：每轮一个全新上下文子代理，并写入阶段事件 |
| `skills/ralph-dashboard/SKILL.md` | 看板：起服务 / 导出快照 / 会话内渲染 |
| `scripts/ralph.sh` | 循环状态机：归档、进度初始化、提示词渲染、无头循环（`--dashboard` 可同时起看板） |
| `scripts/ralph-state.sh` | 只读状态聚合：prd / progress / git / events / archive → 一份 JSON |
| `scripts/ralph-dashboard.sh` | 看板入口：`--dir --port`（服务）、`--snapshot`、`--inline-fragment`、`--once`、`--stop` |
| `scripts/ralph-event.sh` | 向 `.ralph/events.jsonl` 追加上一条阶段事件 |
| `dashboard/index.html` | 看板页面：任务看板 + 流程视图 + 迭代时间线 + 历史运行（无外部依赖、无构建） |
| `dashboard/serve.py` | 本地只读服务，绑定 127.0.0.1，`/api/state` 每次请求现读磁盘 |
| `dashboard/inline.html` | 会话内视图的片段模板 |
| `tests/run-all.sh` | 看板验收套件：状态提取器 / 无头集成 / 真浏览器 UI |
| `templates/iteration-prompt.md` | 单轮迭代提示词模板（每次迭代注入给子代理/CLI 的全部指令） |
| `templates/prd.json.example` | `prd.json` 格式示例 |

## 完成判定

循环是否结束**只以 `prd.json` 里的 `passes` 状态为准**（`remaining == 0`），不以子代理的输出、
也不以 `<promise>COMPLETE</promise>` 令牌为准。这个令牌是给外部工具看的信号，噪音很大：子代理上下文
写满时返回的可能是它自己会话的**压缩摘要**，即便故事已经正确落地，摘要里也常常没有令牌。反过来，
子代理也可能声称成功而 `prd.json` 仍是 `passes: false`。

`ralph.sh` 同样遵循这条规则：令牌缺失但 `remaining == 0` 时，它依然以成功退出。

运行时在项目里产生的文件：`prd.json`、`progress.txt`、`archive/`，以及 `.ralph/`（harness 内部状态：
渲染出的每轮提示词与 last-branch 标记，内含自动生成的 `.gitignore`，不会被提交）。

`prd.json` 和 `progress.txt` 是**设计上要入库**的——它们就是迭代之间的记忆载体（上游同样如此）。
如果你不希望它们入库，自行加入 `.gitignore`，但那样循环就失去了跨迭代的共享上下文。

## 概念要点

- **每轮全新上下文**：故事必须小到能在一个上下文窗口内完成，否则模型会在写坏代码前耗尽上下文。
- **小步故事**：一个好故事是「加一列 + 迁移」「给现有页面加一个组件」这种量级；「构建整个看板」要拆开。
- **验收标准必须可验证**：「类型检查通过」可以，「用户体验良好」不行。
- **反馈回路**：类型检查、测试、CI 必须绿——坏代码会跨迭代累积。
- **UI 故事必须真实验证**：用 ZCode 的浏览器技能实际打开页面确认，不能只靠断言。
- **停止条件**：以 `prd.json` 的 `passes` 状态为准（见上节「完成判定」）；全部通过时输出
  `<promise>COMPLETE</promise>` 作为给外部工具的收尾信号。

## 许可

MIT，见 [LICENSE](LICENSE)。原始版权归 snarktank；本目录为 ZCode 适配版本。
