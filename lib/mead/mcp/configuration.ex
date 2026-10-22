defmodule Mead.MCP.Configuration do
  @moduledoc """
  Validates and normalizes the MCP servers configured under `config :mead, :mcp, servers: [...]`.

      config :mead, :mcp,
        servers: [
          filesystem: [
            transport: {:stdio, command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/data"]},
            tools: [read_text_file: :read, write_file: :effect]
          ],
          remote: [
            transport: {:http, url: "https://example.com/mcp", headers: [{"authorization", "Bearer ..."}]},
            tools: [search: :read]
          ]
        ]

  The class of a tool (`:read` or `:effect`) is declared here and nowhere else; the hub never
  trusts what a server says about itself. A tool the server offers that is not listed here does
  not exist for the model. A server name may hold letters, digits, and hyphens but no underscore,
  so the first `__` of `server__tool` always splits the model-facing name.

  Validation is strict on purpose: an unknown option is almost always a typo, and a typo in a
  permission list silently denies or, worse, mis-grants. Reasons name keys, never values, so a
  header carrying a credential cannot reach a log through an error.

  A listed tool must also be one the model can be shown: `server__tool` may hold letters, digits,
  underscores, and hyphens, and be at most 64 characters. A name outside that would be hidden
  without a word, so it is refused here.
  """

  alias Mead.MCP.Policy

  @type transport ::
          {:stdio, command: String.t(), arguments: [String.t()]}
          | {:http, url: String.t(), headers: [{String.t(), String.t()}]}

  @type server :: %{
          name: atom(),
          transport: transport(),
          tools: %{String.t() => :read | :effect}
        }

  @server_name ~r/\A[a-zA-Z0-9-]+\z/
  @classes [:read, :effect]

  @spec validate(term()) :: {:ok, [server()]} | {:error, term()}
  def validate(servers) when is_list(servers) do
    with :ok <- check_keyword(servers),
         :ok <- check_unique(servers) do
      normalize_all(servers)
    end
  end

  def validate(_other), do: {:error, :servers_not_a_keyword_list}

  defp check_keyword(servers) do
    if Keyword.keyword?(servers), do: :ok, else: {:error, :servers_not_a_keyword_list}
  end

  defp check_unique(servers) do
    names = Keyword.keys(servers)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [duplicate | _rest] -> {:error, {:duplicate_server, duplicate}}
    end
  end

  defp normalize_all(servers) do
    servers
    |> Enum.reduce_while({:ok, []}, fn {name, definition}, {:ok, normalized} ->
      case normalize(name, definition) do
        {:ok, server} -> {:cont, {:ok, [server | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(name, definition) do
    with :ok <- check_name(name),
         {:ok, definition} <- check_definition(name, definition),
         {:ok, transport} <- check_transport(name, Keyword.get(definition, :transport)),
         {:ok, tools} <- check_tools(name, Keyword.get(definition, :tools, [])) do
      {:ok, %{name: name, transport: transport, tools: tools}}
    end
  end

  defp check_name(name) do
    if Regex.match?(@server_name, Atom.to_string(name)),
      do: :ok,
      else: {:error, {:invalid_server_name, name}}
  end

  defp check_definition(name, definition) do
    if is_list(definition) and Keyword.keyword?(definition) do
      case Keyword.keys(definition) -- [:transport, :tools] do
        [] -> {:ok, definition}
        unknown -> {:error, {:invalid_server, name, {:unknown_options, Enum.uniq(unknown)}}}
      end
    else
      {:error, {:invalid_server, name, :definition_not_a_keyword_list}}
    end
  end

  defp check_transport(name, {:stdio, options}) when is_list(options) do
    with {:ok, options} <-
           validate_options(name, options, command: nil, arguments: []),
         :ok <- check_command(name, options[:command]),
         :ok <- check_arguments(name, options[:arguments]) do
      {:ok, {:stdio, command: options[:command], arguments: options[:arguments]}}
    end
  end

  defp check_transport(name, {:http, options}) when is_list(options) do
    with {:ok, options} <- validate_options(name, options, url: nil, headers: []),
         :ok <- check_url(name, options[:url]),
         :ok <- check_headers(name, options[:headers]) do
      {:ok, {:http, url: options[:url], headers: options[:headers]}}
    end
  end

  defp check_transport(name, {kind, options}) when is_atom(kind) and is_list(options),
    do: {:error, {:invalid_server, name, {:unknown_transport, kind}}}

  defp check_transport(name, _missing_or_malformed),
    do: {:error, {:invalid_server, name, :missing_transport}}

  defp validate_options(name, options, defaults) do
    if Keyword.keyword?(options) do
      case Keyword.validate(options, defaults) do
        {:ok, validated} ->
          {:ok, validated}

        {:error, unknown} ->
          {:error, {:invalid_server, name, {:unknown_transport_options, Enum.sort(unknown)}}}
      end
    else
      {:error, {:invalid_server, name, :missing_transport}}
    end
  end

  defp check_command(_name, command) when is_binary(command) and command != "", do: :ok
  defp check_command(name, _invalid), do: {:error, {:invalid_server, name, :invalid_command}}

  defp check_arguments(name, arguments) do
    if is_list(arguments) and Enum.all?(arguments, &is_binary/1),
      do: :ok,
      else: {:error, {:invalid_server, name, :invalid_arguments}}
  end

  defp check_url(name, url) do
    if is_binary(url) and String.starts_with?(url, ["http://", "https://"]),
      do: :ok,
      else: {:error, {:invalid_server, name, :invalid_url}}
  end

  defp check_headers(name, headers) do
    valid? =
      is_list(headers) and
        Enum.all?(headers, fn
          {header_name, header_value} -> is_binary(header_name) and is_binary(header_value)
          _other -> false
        end)

    if valid?, do: :ok, else: {:error, {:invalid_server, name, :invalid_headers}}
  end

  defp check_tools(name, tools) do
    if is_list(tools) and Keyword.keyword?(tools) do
      tools
      |> Enum.reduce_while({:ok, %{}}, fn {tool, class}, {:ok, normalized} ->
        cond do
          class not in @classes ->
            {:halt, {:error, {:invalid_server, name, {:invalid_tool_class, tool}}}}

          not Policy.model_name_valid?(name, Atom.to_string(tool)) ->
            {:halt, {:error, {:invalid_server, name, {:invalid_tool_name, tool}}}}

          Map.has_key?(normalized, Atom.to_string(tool)) ->
            {:halt, {:error, {:invalid_server, name, {:duplicate_tool, tool}}}}

          true ->
            {:cont, {:ok, Map.put(normalized, Atom.to_string(tool), class)}}
        end
      end)
    else
      {:error, {:invalid_server, name, :invalid_tools}}
    end
  end
end
