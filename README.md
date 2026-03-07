# OpenClacky

[![Build](https://img.shields.io/github/actions/workflow/status/clacky-ai/open-clacky/main.yml?label=build&style=flat-square)](https://github.com/clacky-ai/open-clacky/actions)
[![Release](https://img.shields.io/gem/v/openclacky?label=release&style=flat-square&color=blue)](https://rubygems.org/gems/openclacky)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1.0-red?style=flat-square)](https://www.ruby-lang.org)
[![Downloads](https://img.shields.io/gem/dt/openclacky?label=downloads&style=flat-square&color=brightgreen)](https://rubygems.org/gems/openclacky)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE.txt)

**From expertise to business — turn your professional knowledge into a monetizable OpenClaw Skill.**

OpenClacky is the creator-side platform for the OpenClaw ecosystem. Package your methods and workflows into encrypted, white-labeled Skills that your clients install and use — under your name, your brand, your price.

## Why OpenClacky?

The OpenClaw ecosystem has 5,700+ Skills and growing. But almost all of them are open-sourced, free, and easily copied. The real scarcity isn't more Skills — it's **expertise-backed, production-grade Skills worth paying for**.

OpenClacky is built for the people who have that expertise.

|  | **Openclaw** | **OpenClacky** |
|---|---|---|
| **Core model** | Open sharing | Encrypted & protected |
| **Primary users** | Users who install Skills | Creators who sell Skills |
| **Revenue** | None | Creator-defined pricing |
| **Brand** | Platform brand | Your own brand |
| **Driven by** | Technical contributors | Domain expertise |

## How It Works

**Four steps from capability to business:**

1. **Craft your Skill** — Turn your domain methodology into a repeatable AI workflow
2. **Encrypt & protect** — Your logic stays yours; clients can't inspect or copy it
3. **Package your brand** — Ship under your name, your logo, your onboarding experience
4. **Launch & acquire** — One-click sales page, built-in SEO, start converting traffic

## Who It's For

OpenClacky is built for domain experts whose knowledge can be expressed as *information processing + executable actions*:

- **SEO specialists** — keyword research, content scoring, rank monitoring
- **Lawyers** — contract review, case retrieval, risk flagging
- **Traders** — signal detection, strategy backtesting, automated execution
- **Data analysts** — cleaning, modeling, report generation
- **Content strategists** — topic selection, outlines, drafts at scale

## Features

- [x] **Skill builder** — Create AI workflows via conversation or UI, iterate and ship fast
- [x] **Encryption** — Protect your knowledge assets; end users cannot read your Skill source
- [x] **White-label packaging** — Your brand, your product line, your client experience
- [x] **Auto-update delivery** — Push updates to all users seamlessly, with version control
- [x] **Cross-platform distribution** — Windows, macOS, Linux — one Skill, every platform
- [x] **Sales page generator** — Launch your storefront fast, with built-in SEO foundations
- [x] **Cost monitoring** — Real-time token tracking, automatic compression (up to 90% savings)
- [x] **Multi-provider support** — OpenAI, Anthropic, DeepSeek, and any OpenAI-compatible API
- [ ] **Skill marketplace** — Discover and distribute premium Skills *(coming soon)*

## Coding Support

OpenClacky also works as a general AI coding assistant — scaffold full-stack Rails apps, add features, or explore an unfamiliar codebase:

```bash
$ openclacky
> /new my-app        # scaffold a full-stack Rails app
> Add user auth with email and password
> How does the payment module work?
```

Built on a production-ready Rails architecture with one-click deployment, dev/prod isolation, and automatic backups.

## Installation

### Method 1: One-line Install (Recommended)

```bash
/bin/bash -c "$(curl -sSL https://raw.githubusercontent.com/clacky-ai/open-clacky/main/scripts/install.sh)"
```

### Method 2: RubyGems

**Requirements:** Ruby >= 3.1.0

```bash
gem install openclacky
```

## Quick Start

### Terminal (CLI)

```bash
openclacky            # start interactive agent in current directory
```

### Web UI

```bash
openclacky server     # start the web server (default: http://localhost:7070)
```

Then open **http://localhost:7070** in your browser. You'll get a full-featured chat interface with multi-session support — run separate sessions for coding, copywriting, research, and more, all in parallel.

Options:

```bash
openclacky server --port 8080          # custom port
openclacky server --host 0.0.0.0      # listen on all interfaces (e.g. remote access)
```

## Configuration

```bash
$ openclacky
> /config
```

You'll be prompted to set your **API Key**, **Model**, and **Base URL** (any OpenAI-compatible provider).

## Install from Source

```bash
git clone https://github.com/clacky-ai/open-clacky.git
cd open-clacky
bundle install
bin/clacky
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/clacky-ai/open-clacky. Contributors are expected to adhere to the [code of conduct](https://github.com/clacky-ai/open-clacky/blob/main/CODE_OF_CONDUCT.md).

## License

Available as open source under the [MIT License](https://opensource.org/licenses/MIT).
