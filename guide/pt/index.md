# mead

Runtime para assistentes baseados em LLM sobre Elixir/OTP: sessões supervisionadas, um router de modelos local/nuvem e cliente e servidor MCP.

## O que oferece

* **Sessões.** Um par de processos supervisionado por conversa: um histórico e um servidor. Uma queda fica contida na conversa, e um turno que estava rodando volta marcado como `interrupted`.
* **Router.** Uma função sem estado que envia cada turno a um modelo local (Ollama) ou de nuvem (Anthropic).
* **MCP.** Um hub que conecta nos servidores MCP que você configurar e um servidor que expõe sessões a outros clientes.
* **Persistência.** Um arquivo só de acréscimo por conversa, para retomar uma sessão parada.
* **Ledger.** Tokens, chamadas de ferramenta e latência por sessão e por rota.

## Próximos passos

* [Início rápido](quickstart.md) para rodar uma sessão.
* [Router e providers](router.md) para enviar turnos a modelos de verdade.
* [MCP](mcp.md) para dar ferramentas aos modelos, ou controlar o `mead` a partir de outro cliente.
* [Persistência e ledger](persistence.md) para guardar conversas e contar o uso.
