# MCP

O `mead` é os dois lados do Model Context Protocol.

## Hub: dar ferramentas aos modelos

`config :mead, :mcp, servers: [...]` lista os servidores MCP. Cada um tem um transporte, `{:stdio, command:, arguments:}` ou `{:http, url:, headers:}`, e as ferramentas que você permite, cada uma declarada como `:read` ou `:effect`.

```elixir
config :mead, :mcp,
  servers: [
    # uma entrada por servidor: um transporte e as ferramentas permitidas, cada uma como :read ou :effect
  ]
```

* A política nega por padrão. Uma ferramenta que o servidor oferece e a configuração não lista não existe para o modelo.
* Ferramentas `:read` são sempre mostradas. Ferramentas `:effect` só quando o turno passa `tools: :effect`.
* A classe vem da sua configuração, nunca do servidor.
* Uma conexão que falha é retentada após 1, 2, 5, 15 e depois 30 segundos, e nunca derruba a aplicação.

## Servidor: controlar o mead a partir de outro cliente

`config :mead, :mcp_server, token: "...", port: 4040` sobe um listener HTTP em `POST /mcp`. Sem `token` nada escuta. As requisições precisam de bearer token, e o cabeçalho `Origin` é verificado.

Ele expõe nove ferramentas: `start_session`, `submit_turn`, `history`, `stop_session`, `resume_session`, `delete_session`, `list_sessions`, `compact_session` e `usage`. `tools: "effect"` só vale quando o operador definiu `allow_effect: true`.

Acrescente `certfile` e `keyfile` para servir HTTPS. A lista completa de limites e códigos de status está no [ARCHITECTURE.md](https://github.com/albertosca/mead/blob/main/docs/ARCHITECTURE.md) (em inglês).
