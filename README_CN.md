# OpenClacky

[![Build](https://img.shields.io/github/actions/workflow/status/clacky-ai/openclacky/main.yml?label=build&style=flat-square)](https://github.com/clacky-ai/openclacky/actions)
[![Release](https://img.shields.io/gem/v/openclacky?label=release&style=flat-square&color=blue)](https://rubygems.org/gems/openclacky)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1.0-red?style=flat-square)](https://www.ruby-lang.org)
[![Downloads](https://img.shields.io/gem/dt/openclacky?label=downloads&style=flat-square&color=brightgreen)](https://rubygems.org/gems/openclacky)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE.txt)

> 想贡献代码？提 PR 前请先读 **[CONTRIBUTING.md](./CONTRIBUTING.md)**。

**最省 Token 的开源 AI Agent。**

OpenClacky 在任务能力上对齐 Claude Code，成本相当，同时相比其他开源 Agent 有显著优势（约节省 50% vs OpenClaw，成本约为 Hermes 的 1/3）。100% 开源（MIT），支持 BYOK 接入任意 OpenAI 兼容模型，背后是两年 Agentic 研发与 Harness 工程积累。

> 官网：https://www.openclacky.com/ · 投资方：**奇绩创坛 · 真格基金 · 红杉中国 · 高瓴资本**

## 为什么选 OpenClacky？

同一个任务，你要花多少钱？在可比的 Agent 工作负载下，OpenClacky 相比主流方案节省了大量 Token 费用。

| Agent | 相对成本 | 备注 |
|---|---|---|
| **OpenClacky** | **~0.8×** | 16 个工具 · 近 100% 缓存命中 · 子 Agent 路由 |
| Claude Code | 1.0×（基准） | 世界级 Harness，闭源订阅制 |
| OpenClaw | ~1.5× | 能力对标的 Harness Agent |
| Hermes | ~3× | 52 个内置工具，Schema 体积膨胀 ~3–4× |

*数据为内部常见 Agent 任务均值，以 Claude Code 为基准。完整基准测试报告将在 GitHub 发布。*

## 功能对比

核心 Agent 能力各家大致对齐，真正的差异在于**成本、开放性、Skill 进化能力和集成支持**。

| 功能 | Claude Code | OpenClaw | Hermes | **OpenClacky** |
|---|:---:|:---:|:---:|:---:|
| Token 成本 | 1.0× | ~1.5× | ~3× | **~0.8×** |
| 开源 | ❌ 闭源 | ✅ 开源 | ✅ 开源 | ✅ MIT |
| BYOK / 自由选模型 | ❌ 仅限 Anthropic | ✅ | ✅ | ✅ |
| Skill 自我进化 | ❌ | ❌ | ✅ | ✅ |
| IM 集成（飞书/企微/微信/Discord/Telegram） | ❌ | ✅ | ✅ | ✅ |

## 成本是怎么降下来的

不是靠裁剪功能——而是在每一层都做了正确的取舍，效果叠加。

### 1. 极高缓存命中率
Session 不重启、双缓存标记、**先插入再压缩**——System Prompt 从不被修改，压缩后仍能复用缓存。**实测缓存命中率：接近 100%。**

### 2. 极简工具集
仅 **16 个核心工具**。扩展能力通过一个 `invoke_skill` 元工具交给 Skill 生态承载。工具数量不是指标——任务完成率才是。

| OpenClacky | Claude Code | OpenClaw | Hermes |
|:--:|:--:|:--:|:--:|
| **16** | 40+ | 23 | 52 |

### 3. 空闲时自动压缩
去开个会、倒杯咖啡——Agent 在后台压缩长上下文并预热缓存。你回来发第一条消息就能直接命中缓存。**冷启动首 Token 成本降低 50%+。**

### 4. BYOK——你选模型，你定成本
任意 OpenAI 兼容 API，即插即用。官方直连、聚合路由、兼容中转——100% 由你决定。代码用 Claude，子任务自动路由到 DeepSeek，再省一截。

背后是 **2 年 · 3 代 Agentic 架构 · 6 个核心 Harness 工程决策**的积累。

## Skills——Agent 的灵魂

- **`/` 唤起** — 即时浏览、模糊搜索、直接调用。数百个 Skill 触手可及。
- **用自然语言创建 Skill** — 描述你想要的，Agent 自动起草 `SKILL.md`、拆解步骤、跑验证。无需写代码。
- **自我进化** — 每次运行后，Agent 根据执行上下文和结果更新 Skill。下次调用更稳定、更精准。
- **开放兼容** — 支持 Claude Skills / Markdown Pack / 自定义格式。
- **可变现** — 打磨好的 Skill 可打包出售，支持加密分发、License 管理、创作者自定价。

## 安装

### 桌面安装器（推荐）

双击安装，环境、依赖、Skill 全部自动配置好。

- **macOS** — [下载 `.dmg`](https://oss.1024code.com/openclacky-installer/official/openclacky-installer.dmg)（Apple Silicon / Intel）
- **Windows** — [下载 `.exe`](https://oss.1024code.com/openclacky-installer/official/openclacky-installer.exe)（Windows 10 2004+ / Windows 11）

更多选项：https://www.openclacky.com/

### 命令行安装

一键安装（Mac/Ubuntu）：

```bash
/bin/bash -c "$(curl -sSL https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.sh)"
```

Windows：

```bash
powershell -c "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.ps1')))"
```

或使用 Ruby（3.x/4.x）：

**环境要求：** Ruby >= 3.1.0

```bash
gem install openclacky
```

详见：https://www.openclacky.com/docs/installation

### Docker

#### 预构建镜像（GHCR）

镜像在版本 tag（`v*`）时自动发布到 GitHub Container Registry。

```bash
# 将 <owner> 替换为仓库所有者（如 clacky-ai 或你的 fork）
docker pull ghcr.io/<owner>/openclacky:latest
# 或固定某个版本：
# docker pull ghcr.io/<owner>/openclacky:1.5.3
```

**Linux:**

```bash
docker run -d --name openclacky --network=host \
  -e CLACKY_ACCESS_KEY="" \
  -v openclacky-data:/root/.clacky \
  ghcr.io/<owner>/openclacky:latest
```

`--network=host` 使容器与宿主机共享网络栈，Agent 可直接访问宿主机上运行的 Chrome 远程调试端口。

**macOS / Windows:**

```bash
docker run -d --name openclacky -p 7070:7070 \
  -e CLACKY_ACCESS_KEY="" \
  -v openclacky-data:/root/.clacky \
  ghcr.io/<owner>/openclacky:latest
```

> **注意：** macOS/Windows 不支持 `--network=host`，浏览器自动化功能可能受限。

启动后访问 **http://localhost:7070**。

#### 从源码构建

```bash
git clone https://github.com/clacky-ai/openclacky.git
cd openclacky
# 可选：设置 OCI 镜像版本标签
docker build --build-arg VERSION=1.5.3 -t openclacky .
docker run -d -p 7070:7070 -e CLACKY_ACCESS_KEY="" openclacky
```

环境变量：

| 变量 | 说明 |
|---|---|
| `CLACKY_ACCESS_KEY` | 设置访问密钥保护 Web UI（留空 = 公开模式；绑定 `0.0.0.0` 时必须设置该环境变量） |

## 快速开始

### 终端（CLI）

```bash
openclacky            # 在当前目录启动交互式 Agent
```

### Web UI

```bash
openclacky server     # 默认地址：http://localhost:7070
```

打开 **http://localhost:7070**，享受完整的聊天界面，支持多 Session 并行——同时跑编码、文案、研究等多个任务。

选项：

```bash
openclacky server --port 8080        # 自定义端口
openclacky server --host 0.0.0.0     # 监听所有接口（支持远程访问）
```

## 配置

```bash
$ openclacky
> /config
```

设置你的 **API Key**、**模型**和 **Base URL**（任意 OpenAI 兼容提供商）。

开箱即支持：**Claude (Anthropic) · GPT (OpenAI) · DeepSeek · Kimi (Moonshot) · MiniMax · OpenRouter · OrcaRouter**，或任意自定义端点。

### ChatGPT — Web UI 原型

ChatGPT 功能以客户端内置、默认启用的扩展随包交付，底层通过 Codex ACP 接入，不需要从扩展市场另行安装。本地 Web UI 可以把它作为 Agent 运行时使用。首次引导时点击**选择其他服务商（API 或 ChatGPT）**，或者进入**设置 → 模型 → 添加模型**，在原有服务商下拉框中选择 **ChatGPT**。OpenClacky 会立即连接，并通过一个临时 ACP 会话加载该账号可用的模型列表；保存前必须选择新会话平时默认使用的模型。Base URL、API Key 和 API Format 会保持隐藏，运行时配置卡只记录所选模型名，不保存 API 凭据。临时发现会话会立即关闭，也不会出现在会话列表中。进入具体会话后仍可在该会话的 ACP 候选列表中单独切换模型，不会改动卡片默认值。ChatGPT 为默认运行时时，设置页会把**视觉理解**显示为主模型自动提供；其他媒体配置保持原有行为。

OpenClacky 通过 ACP 连接固定版本组合：`@agentclientprotocol/codex-acp@1.11.0` + `@openai/codex@0.153.4`。当前原型需要满足以下任一条件：

- 已安装 Node.js 20+ 和 `npx`；回退方式会固定两个包的精确版本，依赖 npm 的包完整性校验，在首次使用时下载，之后使用 npm 缓存。平台包目前超过 100 MB，网络较慢时首次连接可能需要约五分钟。
- 仅用于开发或受控打包：通过 `CLACKY_CODEX_ACP_PATH` 指定受信任适配器的实际入口文件；`CLACKY_CODEX_PATH` 是由运维方显式信任的覆盖项，且必须报告 Codex 0.153.4。程序不会自动执行 `PATH` 中偶然发现的全局 `codex-acp`。

所有适配器路径（包括 `CLACKY_CODEX_ACP_PATH`）都会校验已发布适配器源码的 SHA-256、要求 Codex 包精确版本，并应用一个很小的兼容补丁，把会话工作区标记为不受信任，因此不会加载仓库内的 `.codex` 配置、Hook 和执行策略。精确版本校验不等于完整产物证明；正式打包还需要锁定并验证完整依赖树与平台二进制。

OpenClacky 使用独立的 managed home：macOS 为 `~/Library/Application Support/OpenClacky/codex`，其他 POSIX 系统为 `${XDG_DATA_HOME:-~/.local/share}/openclacky/codex`，不会直接共用整套来源 Codex home。它可以链接 `$CODEX_HOME`（未设置时为 `~/.codex`）中当前用户拥有、权限私密且不是符号链接的普通 `auth.json`，并只从源配置中读取、校验后重建三个顶层偏好：`model`、`model_reasoning_effort` 和 `service_tier`。源配置本身不会被复制或链接，MCP、插件、Skill、Hook、规则、历史和数据库也不会被导入。强制权限配置还会屏蔽源认证目录、managed home 和常见本地秘密路径，并禁止登录 Shell 初始化。无法安全复用时，请走浏览器登录。删除模型配置卡不会退出 ChatGPT，也不会修改源认证文件。客户端内置的是该扩展；当前原型尚未把 Node/codex-acp 运行制品一起打包。

当前限制：仅 Web UI 支持配置；普通 API 卡与 Agent 运行时卡不能在同一会话内热切换，需要新建会话。Codex ACP 会话建立后，可以在当前会话的模型选择器中切换运行时公布的模型。Codex 的思考等级会按 ACP 返回值显示，但此版本中只读；运行时会话会隐藏 OpenClacky 专属的 Skill、`/new` 初始化和 Fork 入口。仓库当前的 Docker 镜像尚未内置 Node/npm/npx 或适配器；远程/无头登录和 Windows 进程树托管仍属于发布前工作。连接面板里的 `missing_dependencies`、`incompatible_node`、`incompatible_codex_acp` 和 `untrusted_installed_codex_acp` 可定位常见启动问题。

## 代码开发场景

OpenClacky 是一款通用 AI 编程助手——搭建全栈应用脚手架、添加功能，或快速探索陌生代码库：

```bash
$ openclacky
> /new my-app        # 创建新项目脚手架
> 添加邮箱密码登录功能
> 支付模块是怎么实现的？
```

## Star 历史

<a href="https://star-history.dera.page/#clacky-ai/openclacky&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=clacky-ai/openclacky&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=clacky-ai/openclacky&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=clacky-ai/openclacky&type=date&legend=top-left" />
 </picture>
</a>

## 进阶——创作者计划

已有深度用户将自己的工作流打磨成垂直 AI 专家在 OpenClacky 上发布——支持加密分发、License 管理、自定义定价。法律、医疗、财务规划等领域均有落地。

了解更多：https://www.openclacky.com/ → Creators

## 从源码安装

```bash
git clone https://github.com/clacky-ai/openclacky.git
cd openclacky
bundle install
bin/clacky
```

## 信任与背书

- **100% 开源** — MIT 协议，所有代码公开，所有决策可溯源
- **2 年 Agentic 研发** — 经历 3 代架构演进
- **16 个核心工具** — 极简设计
- **投资方** — 奇绩创坛 · 真格基金 · 红杉中国 · 高瓴资本

## 关注作者公众号

本项目由 **李亚飞** 创立并主导开发。如果你对 AI Agent 工程、Harness 设计、创业经历感兴趣，欢迎关注微信公众号： **技术达人李亚飞**

近期文章：

- [从 ShowMeBug 到 OpenClacky：我对 AI 时代的 4 次下注](https://mp.weixin.qq.com/s/wTW-IU5Czu-OpJTFh_mwgA)
- [我把 AI 账单从 30 美金打到 5 美金](https://mp.weixin.qq.com/s/BDhE0y8xbX0ea3vLlV37Ig)
- [100% Cache 命中的 Harness 怎么设计：一个开源 AI Agent 的 7 个工程决策](https://mp.weixin.qq.com/s/Rc1xk0Qw168D4Y07kkBiGQ)

## 贡献者

每一行代码、每一个 Bug 报告、每一次认真的 Review，都让 OpenClacky 变得更好。感谢你们！

<a href="https://github.com/clacky-ai/openclacky/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=clacky-ai/openclacky" />
</a>

## 参与贡献

欢迎在 GitHub 提交 Bug 报告和 Pull Request：https://github.com/clacky-ai/openclacky 。参与贡献者须遵守[行为准则](https://github.com/clacky-ai/openclacky/blob/main/CODE_OF_CONDUCT.md)。

## 许可证

基于 [MIT 协议](https://opensource.org/licenses/MIT) 开源发布。
