🇺🇸 [English](README.md) · 🇧🇷 [Português](README.pt.md)

# mead

**Smart LLM Router & Cost-Aware Agent Runtime built on the BEAM / OTP.**

`mead` is an open-source, fault-tolerant orchestration runtime designed to manage AI conversations, coordinate multiple models, and expose tools via the Model Context Protocol (MCP). Built on the Erlang/Elixir BEAM virtual machine, every conversation turn and external tool invocation runs inside supervised, isolated actor processes.

---

## Ecosystem Architecture

`mead` forms the core engine of a decoupled three-repository personal assistance platform:

* **`mead` (this repository):** Core Elixir/OTP agent runtime, hybrid cost-aware scheduler (local Ollama vs. cloud providers), and concurrent MCP Hub.
* **[`agent-swarm-deck`](../agent-swarm-deck):** Multiplatform Flutter client featuring an Action-First conversational stream (interactive approval cards, live progress tracking, structured selection).
* **[`open-butler`](../open-butler):** Personal assistant domain application providing high-level operational workflows (daily routines, email sweeping, calendar organization) and safe local execution bridges.

---

## Key Pillars

1. **Actor-Model Process Supervision:** Every active user session is dynamically supervised (`DynamicSupervisor`). A timeout, rate-limit error, or crashed external tool is contained within that specific turn without affecting adjacent conversations.
2. **Hybrid Cost & Model Scheduler:** A sub-200ms intent classifier evaluates incoming prompts, routing low-cost mechanical tasks (formatting, categorization, simple queries) to local models (Ollama: Gemma 2 / Llama 3) while delegating deep multi-step reasoning to cloud models (Claude / Gemini).
3. **Concurrent MCP Hub:** Acts as both an MCP Client (aggregating external tools over stdio/HTTP) and an MCP Server (allowing external CLI agents to tap into `mead`).
4. **Real-Time Telemetry & Token Ledger:** Fine-grained accounting of token consumption, latency metrics, and financial expenditure per session.

---

## Technical Documentation

* Detailed architecture and supervisor tree: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
* Agent governance and contributing guidelines: [AGENTS.md](AGENTS.md)
* Historical project decisions and log: [docs/superpowers/PROJECT-LOG.md](docs/superpowers/PROJECT-LOG.md)

---

## License

MIT © Alberto Cavalcanti
