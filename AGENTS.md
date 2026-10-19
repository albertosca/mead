# Agent Guidelines & Operational Rules — mead

Welcome! This document provides complete operational guidelines and technical constraints for any AI agent (Claude Code, Antigravity CLI, or human developer) working on the `mead` codebase.

---

## 1. Project Purpose & Ecosystem Role

`mead` is the **core backend runtime engine** of the author's personal assistant ecosystem. It is implemented in **Elixir on the BEAM / OTP platform**.

**Key Responsibilities:**
* Maintain dynamic process supervision per conversation session.
* Dispatch prompts intelligently: local Ollama for fast zero-cost tasks, cloud LLMs for complex turns.
* Provide concurrent MCP aggregation (client & server) over WebSockets and JSON-RPC.

---

## 2. Inviolable Governance Rules

1. **Language Convention:**
   * All code, comments, docstrings, variable names, commit messages, and documentation must be **100% in English**.
   * User interaction with the author is in Portuguese (PT-BR).
2. **No Short or Abbreviated Identifiers:**
   * Never use 1–2 letter or truncated variable names (`i`, `x`, `err`, `ctx`, `cfg`, `msg`, `opts`).
   * Always write full, meaningful words: `index`, `error`, `context`, `configuration`, `message`, `options`.
3. **No Mid-Paragraph Hard Line Wrapping:**
   * Write continuous paragraphs as a single logical line in markdown files without arbitrary wrapping at 80/100 columns.
4. **Git Safeguards:**
   * Never run destructive git commands (`git reset --hard`, `git clean -fd`, `git checkout .`, `git restore .`).
   * Remote push to GitHub is the maintainer's responsibility — do not push automatically.
5. **Testing Discipline:**
   * All features and refactorings must be verified with automated tests (`mix test`).
   * Never claim a task is complete without running verification commands and observing a green baseline.

---

## 3. Architecture Quick Reference

* Application Root: `Mead.Supervisor` (`rest_for_one` strategy)
* Session Pool: `Mead.Session.Pool` (`DynamicSupervisor`) starting one `Mead.Session.Supervisor` per conversation, which holds a `Mead.Session.History` agent and a `Mead.Session.Server`.
* Process Registry: Elixir `Registry` mapping UUIDs to running GenServer PIDs.
* Router: `Mead.Router`, a stateless turn handler (no process) that classifies each turn as local or cloud, calls the provider in that slot (`Mead.Provider`; Anthropic implemented, Ollama pending), and emits `[:mead, :router, :route]` events for the ledger.
* Ledger: `Mead.Ledger`, the first root child, aggregating those events per session and per route in ETS plus a ring of the last 100 turns; in memory only.
* MCP Hub: `Mead.MCP.Hub` translating JSON-RPC requests.
* Verification gates: `mix test`, `mix format --check-formatted`, and `mix compile --warnings-as-errors`.

For full architectural diagrams and specifications, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
