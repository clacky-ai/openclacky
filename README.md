# OpenClacky

[![Build](https://img.shields.io/github/actions/workflow/status/clacky-ai/openclacky/main.yml?label=build&style=flat-square)](https://github.com/clacky-ai/openclacky/actions)
[![Release](https://img.shields.io/gem/v/openclacky?label=release&style=flat-square&color=blue)](https://rubygems.org/gems/openclacky)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1.0-red?style=flat-square)](https://www.ruby-lang.org)
[![Downloads](https://img.shields.io/gem/dt/openclacky?label=downloads&style=flat-square&color=brightgreen)](https://rubygems.org/gems/openclacky)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE.txt)

<p align="center">
  <a href="README.md">English</a> · <a href="README_CN.md">简体中文</a> · <a href="README_JA.md">日本語</a>
</p>

> Contributing? Read **[CONTRIBUTING.md](./CONTRIBUTING.md)** before opening a PR.

**The most Token-efficient open-source AI Agent.**

OpenClacky matches Claude Code on capability at comparable cost, and saves significantly against other open-source agents (~50% vs OpenClaw, costs only ~1/3 of Hermes). 100% open source (MIT), BYOK with any OpenAI-compatible model, built on two years of Agentic R&D and harness engineering.

> Website: https://www.openclacky.com/ · Backed by **MiraclePlus · ZhenFund · Sequoia China · Hillhouse Capital**

## Why OpenClacky?

Same task, how much do you pay? Under comparable agent workloads, OpenClacky saves a large amount of Token spend compared to mainstream alternatives.

| Agent | Relative cost | Notes |
|---|---|---|
| **OpenClacky** | **~0.8×** | 16 tools · ~100% cache hit · subagent routing |
| Claude Code | 1.0× (baseline) | World-class harness, closed-source subscription |
| OpenClaw | ~1.5× | Comparable harness agent |
| Hermes | ~3× | 52 built-in tools — schema bloat ~3–4× |

*Numbers are averages measured on internal common agent tasks, using Claude Code as the baseline. Full benchmark reports will be published on GitHub.*

## Feature comparison

Core agent capability is roughly on par across the field — the real differentiators are **cost, openness, Skill evolution, and integrations**.

| Feature | Claude Code | OpenClaw | Hermes | **OpenClacky** |
|---|:---:|:---:|:---:|:---:|
| Token cost | 1.0× | ~1.5× | ~3× | **~0.8** |
| Open source | ❌ Closed | ✅ Open | ✅ Open | ✅ MIT |
| BYOK / model freedom | ❌ Anthropic only | ✅ | ✅ | ✅ |
| Skill self-evolution | ❌ | ❌ | ✅ | ✅ |
| IM integration (Feishu/WeCom/WeChat/Discord/Telegram) | ❌ | ✅ | ✅ | ✅ |

## How we get the cost down

Not by cutting features — by compounding the right choice at every layer.

### 1. Ultra-high cache hit rate
Sessions never restart, double cache markers, **Insert-then-Compress** — the system prompt is never mutated, so compression still reuses the cache. **Measured cache hit rate: near 100%.**

### 2. Minimal tool set
Only **16 core tools**. Capabilities are offloaded to the Skill ecosystem via a single `invoke_skill` meta-tool. Tool count is not the metric — task completion rate is.

| OpenClacky | Claude Code | OpenClaw | Hermes |
|:--:|:--:|:--:|:--:|
| **16** | 40+ | 23 | 52 |

### 3. Idle-time auto-compression
Go to a meeting, grab coffee — the agent compresses long context in the background and pre-warms the cache. Your first message back hits the cache directly. **Cold-start first-token cost reduced by 50%+.**

### 4. BYOK — you pick the model, you set the cost
Any OpenAI-compatible API, plug and play. Official direct, aggregate routing, compatible relays — the choice is 100% yours. Use Claude for code, auto-route subtasks to DeepSeek, save another chunk of tokens.

Built on **2 years · 3 generations of agentic architecture · 6 core harness engineering decisions**.

## Skills — the soul of the agent

- **Invoke with `/`** — instant browse, fuzzy search, direct call. Hundreds of Skills at your fingertips.
- **Create Skills in natural language** — just describe what you want; the agent drafts `SKILL.md`, breaks down steps, and runs validation. No code required.
- **Self-evolving** — after each run, the agent updates the Skill based on execution context and results. The next call is more stable and more accurate.
- **Open & compatible** — supports Claude Skills / Markdown Pack / custom formats.
- **Monetizable** — polished Skills can be packaged for sale, with encrypted distribution, License management, and creator-defined pricing.

## Installation

### Desktop installer (recommended)

Double-click to install — environment, dependencies, and Skills all set up automatically.

- **macOS** — [Download `.dmg`](https://oss.1024code.com/openclacky-installer/official/openclacky-installer.dmg) (Apple Silicon / Intel)
- **Windows** — [Download `.exe`](https://oss.1024code.com/openclacky-installer/official/openclacky-installer.exe) (Windows 10 2004+ / Windows 11)

More options: https://www.openclacky.com/

### Command line

One-line install(Mac/Ubuntu):

```bash
/bin/bash -c "$(curl -sSL https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.sh)"
```

Windows:

```bash
powershell -c "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.ps1')))"
```

or using Ruby(3.x/4.x):

**Requirements:** Ruby >= 3.1.0

```bash
gem install openclacky
```

see more: https://www.openclacky.com/docs/installation

### Docker

#### Pre-built image (GHCR)

Images are published to GitHub Container Registry on version tags (`v*`).

```bash
# Replace <owner> with the repo owner (e.g. clacky-ai or your fork)
docker pull ghcr.io/<owner>/openclacky:latest
# or pin a release:
# docker pull ghcr.io/<owner>/openclacky:1.5.3
```

**Linux:**

```bash
docker run -d --name openclacky --network=host \
  -e CLACKY_ACCESS_KEY="" \
  -v openclacky-data:/root/.clacky \
  ghcr.io/<owner>/openclacky:latest
```

`--network=host` is required so the agent inside the container can reach Chrome's remote debugging port running on the host.

**macOS / Windows:**

```bash
docker run -d --name openclacky -p 7070:7070 \
  -e CLACKY_ACCESS_KEY="" \
  -v openclacky-data:/root/.clacky \
  ghcr.io/<owner>/openclacky:latest
```

> **Note:** On macOS/Windows, `--network=host` is not supported — browser automation may be limited.

Open **http://localhost:7070** after starting.

#### Build from source

```bash
git clone https://github.com/clacky-ai/openclacky.git
cd openclacky
# optional: set the OCI image version label
docker build --build-arg VERSION=1.5.3 -t openclacky .
docker run -d -p 7070:7070 -e CLACKY_ACCESS_KEY="" openclacky
```

Environment variables:

| Variable | Description |
|---|---|
| `CLACKY_ACCESS_KEY` | Protect the Web UI with an access key (empty = public mode; env must be present when binding `0.0.0.0`) |


## Quick Start

### Terminal (CLI)

```bash
openclacky            # start interactive agent in current directory
```

### Web UI

```bash
openclacky server     # default: http://localhost:7070
```

Open **http://localhost:7070** for a full chat interface with multi-session support — run coding, copywriting, research sessions in parallel.

Options:

```bash
openclacky server --port 8080        # custom port
openclacky server --host 0.0.0.0     # listen on all interfaces (remote access)
```

## Configuration

```bash
$ openclacky
> /config
```

Set your **API Key**, **Model**, and **Base URL** (any OpenAI-compatible provider).

Supported out of the box: **Claude (Anthropic) · GPT (OpenAI) · DeepSeek · Kimi (Moonshot) · MiniMax · OpenRouter · OrcaRouter** — or any custom endpoint.

### ChatGPT — Web UI prototype

ChatGPT support ships with the client as a bundled, default-enabled extension backed by Codex ACP; no marketplace installation is required. The local Web UI can run it as an agent runtime. During onboarding, choose **Choose another provider (API or ChatGPT)**, or later open **Settings → Models → Add Model**, then select **ChatGPT** from the same provider dropdown. OpenClacky connects immediately, loads the account's ACP-advertised model list in a temporary session, and requires a default model for new conversations before saving. Base URL, API Key, and API Format remain hidden, and the saved runtime card contains the selected model name but no API credential. The temporary discovery session is closed immediately and never appears in the conversation list. A conversation may still switch among models advertised by its own ACP session without changing the saved default. When ChatGPT is the default runtime, **Visual Understanding** is shown as automatically supplied by the primary model; the other media rows keep their existing configuration behavior.

OpenClacky connects through ACP using the version-locked pair `@agentclientprotocol/codex-acp@1.11.0` + `@openai/codex@0.153.4`. This prototype requires one of:

- Node.js 20+ with `npx`; the fallback pins both exact packages, relies on npm's package-integrity verification, downloads them on first use, and then uses the npm cache. The platform package is currently over 100 MB, so a slow first connection can take up to five minutes.
- For development or controlled packaging only, a trusted adapter entry point selected with `CLACKY_CODEX_ACP_PATH`; `CLACKY_CODEX_PATH` is an explicit operator-trusted override and must report Codex 0.153.4. An implicitly discovered global `codex-acp` is never executed.

Every adapter path, including `CLACKY_CODEX_ACP_PATH`, verifies the published adapter source by SHA-256, requires the exact Codex package version, and applies a narrow compatibility patch that marks session roots untrusted. Repository-local `.codex` config, hooks, and exec policies therefore stay disabled. Exact-version checks are not full artifact attestation; a production bundle must additionally lock and attest the complete dependency tree and platform binary.

OpenClacky uses an independent managed home — `~/Library/Application Support/OpenClacky/codex` on macOS, or `${XDG_DATA_HOME:-~/.local/share}/openclacky/codex` on other POSIX systems — instead of sharing the whole source Codex home. It may link a regular, current-user, private-permission `auth.json` from `$CODEX_HOME` (or `~/.codex` when that variable is unset) and rebuilds its own config from only three validated top-level preferences: `model`, `model_reasoning_effort`, and `service_tier`. It never copies or links the source config, MCP servers, plugins, skills, hooks, rules, history, or databases. A forced permission profile blocks the source and managed credential paths plus common local secret locations and disables login-shell initialization. If the login cannot be reused safely, use the browser login. Removing the model card does not log out ChatGPT or modify the source auth file. The bundled extension is part of the client; the current prototype does not yet bundle its Node/codex-acp runtime artifacts.

Current limits: setup is Web-UI-only; API-backed and agent-runtime cards cannot be hot-switched inside one session, so changing provider still requires a new session. Once a Codex ACP session exists, models advertised by that runtime can be selected from the current session's model picker. Codex reasoning effort is displayed from ACP but is read-only in this version; OpenClacky-specific Skills, `/new` initialization, and Fork controls are hidden for runtime sessions. The repository's current Docker image does not bundle Node/npm/npx or the adapter, and remote/headless login plus Windows process-tree packaging still need release work. `missing_dependencies`, `incompatible_node`, `incompatible_codex_acp`, and `untrusted_installed_codex_acp` in the connection panel identify the common launcher failures.

## Coding use case

OpenClacky works as a general AI coding assistant — scaffold full-stack apps, add features, or explore unfamiliar codebases:

```bash
$ openclacky
> /new my-app        # scaffold a new project
> Add user auth with email and password
> How does the payment module work?
```

## Star History

<a href="https://star-history.dera.page/#clacky-ai/openclacky&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=clacky-ai/openclacky&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=clacky-ai/openclacky&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=clacky-ai/openclacky&type=date&legend=top-left" />
 </picture>
</a>

## Advanced — Creator Program

Already power users are turning their workflows into vertical AI experts on OpenClacky — encrypted distribution, License management, self-set pricing. Legal, healthcare, financial planning, and more.

Learn more: https://www.openclacky.com/ → Creators

## Install from Source

```bash
git clone https://github.com/clacky-ai/openclacky.git
cd openclacky
bundle install
bin/clacky
```

## Trust & Credibility

- **100% open source** — MIT License, all code public, all decisions traceable
- **2 years of Agentic R&D** — 3 generations of architecture
- **16 core tools** — minimal by design
- **Backed by** MiraclePlus · ZhenFund · Sequoia China · Hillhouse Capital

## Contributors

Every line of code, bug report, and thoughtful review matters. Thank you for making OpenClacky better.

<a href="https://github.com/clacky-ai/openclacky/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=clacky-ai/openclacky" />
</a>

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/clacky-ai/openclacky. Contributors are expected to adhere to the [code of conduct](https://github.com/clacky-ai/openclacky/blob/main/CODE_OF_CONDUCT.md).

## License

Available as open source under the [MIT License](https://opensource.org/licenses/MIT).
