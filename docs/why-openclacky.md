# Why OpenClacky?

## The Vision: AI-Powered Development for Everyone

**Clacky** is an open-source, CLI-first AI development assistant designed to make software creation accessible to non-technical users while remaining powerful enough for professional developers.

Our ultimate vision: **OpenClacky = Lovable + Supabase** — an open-source alternative that combines the ease-of-use of no-code platforms with the flexibility of a modern Rails application.

---

## The Problem

Building software today is still too hard for most people:

| Challenge | Current Solutions |
|-----------|-------------------|
| **Too technical** | Requires learning programming, DevOps, deployment |
| **Too expensive** | Enterprise tools cost $100+/month |
| **Too locked-in** | Vendor lock-in with proprietary platforms |
| **Too complex** | Modern tech stacks have steep learning curves |

Non-technical founders, designers, and product managers often have great ideas but can't build them. Existing AI tools either:
- **Are too technical** (Claude Code, GitHub Copilot)
- **Are too expensive** (Lovable $25+/month)
- **Lock you into proprietary platforms** (v0, Lovable)

---

## The Solution: Clacky

Clacky bridges the gap between no-code simplicity and developer-grade power.

### Our Two-Part Strategy

#### Part 1: CLI for Everyone (Current Focus)

A command-line AI assistant that's approachable for non-technical users but powerful enough to rival Claude Code.

**Key Differentiators:**

```
┌─────────────────────────────────────────────────────────────┐
│                     Clacky CLI Features                      │
├─────────────────────────────────────────────────────────────┤
│ ✅ confirm_safes mode     │ More automation than Claude     │
│ ✅ Real-time cost monitor │ See token usage in real-time    │
│ ✅ Session persistence    │ Pause & resume your work        │
│ ✅ SafeShell protection   │ Commands made safe automatically│
│ ✅ Multi-API support      │ DeepSeek, OpenRouter, OpenAI    │
│ ✅ Skills system          │ Extensible command shortcuts    │
│ ✅ Open source            │ MIT License - no vendor lock-in │
│ ✅ $0 monthly cost        │ Pay only for API usage          │
└─────────────────────────────────────────────────────────────┘
```

**Why Non-Technical Users Love Clacky:**

1. **Natural Language Commands**
   ```
   clacky agent "Create a REST API for user management"
   clacky agent "Add authentication to my Rails app"
   ```

2. **Safe by Default**
   - Dangerous commands (`rm`, `curl | sh`) are automatically made safe
   - Files moved to trash instead of deleted
   - Project boundaries enforced

3. **Transparent Costs**
   ```
   💰 Cost: $0.0042 (Claude 3.5 Sonnet)
   📊 Tokens: 1,250 in / 850 out
   🗜️  Compression saved: 60%
   ```

4. **Permission Modes for Every Situation**

   | Mode | Behavior | Best For |
   |------|----------|----------|
   | `auto_approve` | Execute all tools automatically | Batch operations |
   | `confirm_safes` | Auto-approve safe operations | Daily development |
   | `plan_only` | Generate plans only | Code review |

5. **Session Recovery**
   ```bash
   clacky agent -c              # Continue last session
   clacky agent -l              # List recent sessions
   clacky agent -a 2            # Attach to specific session
   ```

#### Part 2: AI-Ready Rails Template (Coming Soon)

```
clacky new my_project
```

A production-ready Rails application scaffold designed specifically for AI-powered development, including:

| Feature | Description |
|---------|-------------|
| 🔐 **Authentication** | Built-in login/registration with Devise |
| 🤖 **LLM Integration** | Pre-configured for Claude, OpenAI, DeepSeek |
| ⚡ **Async Jobs** | Sidekiq for background processing |
| 🔄 **WebSockets** | Action Cable for real-time features |
| 🎨 **Beautiful UI** | Tailwind CSS + Hotwire components |
| 📊 **Admin Dashboard** | ActiveAdmin or Avo integration |
| 🚀 **One-Click Deploy** | Docker + Kamal/Cloud66 ready |

**Why Rails?**

- Mature, stable, and well-documented
- Great for AI apps (LLM calls, async processing, web interface)
- Strong conventions reduce decision fatigue
- ActiveJob, Action Cable, Hotwire built-in

---

## Clacky vs. The Competition

| Feature | **Clacky** | Claude Code | Lovable | Cursor |
|---------|------------|-------------|---------|--------|
| **Target Users** | Non-technical + Devs | Developers only | Non-technical | Developers |
| **Interface** | CLI | CLI + IDE + Web | Web only | IDE |
| **Open Source** | ✅ MIT | ❌ Closed | ❌ Closed | ❌ Closed |
| **Monthly Cost** | $0 (API only) | $17-200 | $25-99+ | $20+ |
| **Self-Hosted** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Multi-API** | ✅ DeepSeek, OpenRouter | ❌ Anthropic only | ❌ Limited | ❌ OpenAI only |
| **SafeShell** | ✅ Auto-protection | ⚠️ Manual | N/A | ⚠️ Manual |
| **Sessions** | ✅ Persistent | ⚠️ Limited | ⚠️ Limited | ⚠️ Limited |
| **Skills/Plugins** | ✅ Extensible | ❌ No | ❌ No | ⚠️ Limited |
| **Rails Template** | ✅ Coming soon | ❌ No | ⚠️ Limited | ❌ No |

---

## Why Now?

### The AI Development Revolution

We're at a unique moment in software history:

1. **AI models are now capable** of generating production-quality code
2. **APIs are affordable** - DeepSeek is 95% cheaper than OpenAI
3. **CLI is experiencing a renaissance** - Developers prefer terminal tools
4. **Open source AI is viable** - No vendor lock-in

### The Open Source Advantage

Unlike proprietary platforms, Clacky gives you:

- **Freedom**: Use any model, any API, any provider
- **Control**: Self-host everything, no data leaves your machine
- **Customization**: Modify the source code for your needs
- **Community**: Learn from others, contribute back
- **Longevity**: No risk of the platform shutting down

---

## Our Roadmap

### Phase 1: CLI Excellence (Current)
- [x] Core agent with tool execution
- [x] confirm_safes mode (more automation)
- [x] Real-time cost monitoring
- [x] SafeShell protection
- [x] Session persistence
- [x] Skills system

### Phase 2: Rails Template (Coming Soon)
- [ ] `clacky new` command
- [ ] Pre-configured authentication
- [ ] LLM integration ready
- [ ] Async job system
- [ ] WebSocket support
- [ ] Admin dashboard
- [ ] Docker + deployment configs

### Phase 3: The Lovable Alternative
- [ ] Web-based project manager
- [ ] Visual component library
- [ ] Database schema designer
- [ ] One-click deployment

---

## Pricing Philosophy

We believe AI development tools should be accessible to everyone.

```
┌────────────────────────────────────────────────────────────┐
│                    Clacky Pricing                          │
├────────────────────────────────────────────────────────────┤
│ 📦 Clacky CLI           │ $0/month (Open Source)           │
│    • All features       │ Pay only for API usage           │
│    • No subscription    │ Use DeepSeek, OpenRouter, etc.   │
│                        │                                  │
│ 🚀 Rails Template      │ $0 (Open Source)                 │
│    • Full source code   │ MIT License                      │
│    • Self-host          │ No vendor lock-in                │
│                        │                                  │
│ 💎 Enterprise Support  │ Contact us                        │
│    • Custom development│ Training & consulting            │
└────────────────────────────────────────────────────────────┘
```

---

## Get Started

### Quick Install

```bash
# One-line installation (macOS/Linux)
curl -sSL https://raw.githubusercontent.com/clacky-ai/open-clacky/main/scripts/install.sh | bash

# Or if you have Ruby 3.1+
gem install openclacky
```

### First Steps

```bash
# Configure your API key
clacky config set

# Start the agent
clacky agent

# Or give it a task
clacky agent "Create a TODO list app"

# See all tools
clacky tools
```

---

## Join Us

Clacky is an open-source project. We welcome contributions!

- **GitHub**: https://github.com/clacky-ai/open-clacky
- **Discord**: https://discord.gg/clacky
- **Twitter**: https://twitter.com/clacky_ai

---

## Summary

**Clacky** is for anyone who wants to build software but has been held back by technical complexity or expensive tools.

Whether you're a:
- 🎨 **Designer** who wants to prototype ideas
- 💼 **Product Manager** who wants to validate concepts
- 🚀 **Founder** who wants to build an MVP
- 👨‍💻 **Developer** who wants a more automated CLI

...Clacky is here to help.

**The future of software development is accessible, open, and AI-powered.**

**Welcome to Clacky.**

---

*Last updated: February 2025*
