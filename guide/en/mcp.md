# MCP

`mead` is both sides of the Model Context Protocol.

## Hub: give models tools

`config :mead, :mcp, servers: [...]` lists the MCP servers. Each has a transport, `{:stdio, command:, arguments:}` or `{:http, url:, headers:}`, and the tools you allow, each declared as `:read` or `:effect`.

```elixir
config :mead, :mcp,
  servers: [
    # one entry per server: a transport and the tools you allow, each as :read or :effect
  ]
```

A stdio server can also start in a directory of its own and receive variables of its own:

```elixir
bridge: [
  transport:
    {:stdio,
     command: "uv",
     arguments: ["run", "bridge"],
     cwd: "/srv/bridge",
     env: [{"BRIDGE_TOKEN", "..."}]},
  tools: [status: :read]
]
```

* `cwd` must be an absolute path. A directory that does not exist stops that server from connecting, with `{:transport_start_failed, {:cwd_not_found, directory}}` in the log, and the retries above apply.
* `env` is added to the environment mead was started with, and replaces an inherited variable of the same name. A name may not repeat, and a value reaches the server exactly as written, with no shell in between.
* `command` is looked up on the `PATH` of mead, before the directory changes.

* The policy is deny by default. A tool the server offers and the configuration does not list does not exist for the model.
* `:read` tools are always shown. `:effect` tools are shown only when the turn passes `tools: :effect`.
* The class comes from your configuration, never from the server.
* `never_remember: [:status]` beside `tools:` marks a tool the person must confirm on every call. The deck then offers no "always allow" for it and asks even at the `allow_all` policy level. A name that is not listed under `tools:` is refused at boot, so a typo cannot leave a tool unprotected.
* A connection that fails is retried after 1, 2, 5, 15, then 30 seconds, and never crashes the application.

## Server: drive mead from another client

`config :mead, :mcp_server, token: "...", port: 4040` starts an HTTP listener on `POST /mcp`. Without a `token` nothing listens. Requests need a bearer token, and the `Origin` header is checked.

It exposes nine tools: `start_session`, `submit_turn`, `history`, `stop_session`, `resume_session`, `delete_session`, `list_sessions`, `compact_session` and `usage`. `tools: "effect"` is honoured only when the operator set `allow_effect: true`.

`submit_turn` takes an optional `client_turn_id`. Send the same id again after a lost connection: the turn runs once, and the retry waits for it or gets its stored answer. If the session restarts while a keyed turn runs, the call waits for it to come back and answers with the turn's own outcome: its result, or that it was interrupted once its resume budget ran out. A turn submitted without a `client_turn_id` gets a generated one and continues the same way, but a retry without a key starts a new turn. Only when the session does not come back within 5 seconds of a crash does the call fail, with a message saying so; the turn still continues once it does, and submitting again with the same `client_turn_id` returns its outcome.

Add `certfile` and `keyfile` to serve HTTPS. The full list of limits and status codes is in [ARCHITECTURE.md](https://github.com/albertosca/mead/blob/main/docs/ARCHITECTURE.md).

## A browser deck: one origin, through a proxy

mead sends no CORS headers, on `/mcp` and on `/deck/*` alike: a bearer token guards both, and a header that lets a page read their answers would widen what a listed origin can do. A web deck therefore needs one origin, and the way to get it is a small reverse proxy that serves the built app and forwards `/deck/*` to mead, HTTP, server-sent events and WebSocket included. The proxy passes `Origin` and `Authorization` through, so mead still checks both.

```ts
// bun proxy.ts <listen_port> <mead_host:port> <web_build_directory>
const listenPort = Number(Bun.argv[2] ?? 8080);
const upstreamHost = Bun.argv[3] ?? "127.0.0.1:4040";
const staticRoot = Bun.argv[4] ?? "./build/web";

type SocketData = { upstreamUrl: string; upstream?: WebSocket; pending: Array<string | Buffer> };

const server = Bun.serve<SocketData>({
  port: listenPort,
  hostname: "127.0.0.1",
  async fetch(request, serverInstance) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/deck/")) {
      if (request.headers.get("upgrade")?.toLowerCase() === "websocket") {
        const upgraded = serverInstance.upgrade(request, {
          data: { upstreamUrl: `ws://${upstreamHost}${url.pathname}${url.search}`, pending: [] },
        });
        return upgraded ? undefined : new Response("upgrade failed", { status: 400 });
      }
      const forwardedHeaders = new Headers(request.headers);
      for (const hopHeader of ["host", "content-length", "accept-encoding", "connection"]) forwardedHeaders.delete(hopHeader);
      const upstreamResponse = await fetch(`http://${upstreamHost}${url.pathname}${url.search}`, {
        method: request.method,
        headers: forwardedHeaders,
        body: request.method === "GET" || request.method === "HEAD" ? undefined : await request.arrayBuffer(),
      });
      const responseHeaders = new Headers(upstreamResponse.headers);
      for (const hopHeader of ["content-encoding", "content-length", "transfer-encoding", "connection"]) responseHeaders.delete(hopHeader);
      return new Response(upstreamResponse.body, { status: upstreamResponse.status, headers: responseHeaders });
    }
    const relativePath = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = Bun.file(`${staticRoot}${relativePath}`);
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
  },
  websocket: {
    open(clientSocket) {
      const upstream = new WebSocket(clientSocket.data.upstreamUrl);
      clientSocket.data.upstream = upstream;
      upstream.onopen = () => clientSocket.data.pending.splice(0).forEach((frame) => upstream.send(frame));
      upstream.onmessage = (message) => clientSocket.send(message.data as string);
      upstream.onclose = () => clientSocket.close();
    },
    message(clientSocket, frame) {
      const upstream = clientSocket.data.upstream;
      if (upstream && upstream.readyState === WebSocket.OPEN) upstream.send(frame);
      else clientSocket.data.pending.push(frame);
    },
    close(clientSocket) {
      clientSocket.data.upstream?.close();
    },
  },
});
console.log(`proxy on http://127.0.0.1:${server.port} -> ${upstreamHost}, static ${staticRoot}`);
```

* The page then talks to its own origin (`/deck/ticket`, `/deck/socket`, `/deck/events`, `/deck/messages`), so there is nothing cross-origin to allow.
* While the proxy listens on a loopback address, the `Origin` of the page is a loopback one and mead accepts it. Served from any other host name, the page's origin must be listed in `allowed_origins` of `:mcp_server`.
* Checked: the static route and a proxied `POST` with its `Origin` and `Authorization` reach the upstream untouched. The WebSocket and event-stream paths were measured against the real deck on 2026-11-06 and are not covered by a test in this repository.
* Anything that forwards the same paths works as well (nginx, Caddy, a Phoenix endpoint); the point is only that the browser sees one origin.
