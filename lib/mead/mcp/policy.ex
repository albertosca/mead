defmodule Mead.MCP.Policy do
  @moduledoc """
  Decides which tools the model sees and whether a named call may run. Pure: it reads no process
  and asks no server.

  The inputs are the catalog entries (what the connected servers offer), the normalized servers
  of `Mead.MCP.Configuration` (what the operator allowed, with a class per tool), and the options
  of the turn. A tool is visible only if the server offers it, the configuration lists it, and its
  class is allowed for this turn: `:read` always, `:effect` only with `tools: :effect`. Any other
  value of `tools:` is the default, because an unclear request must not widen access.

  What a server says about itself, such as an annotation that a tool is read-only, is never
  consulted. The model sees `server__tool`; the first `__` splits it, which is unambiguous because
  a configured server name has no underscore.
  """

  @separator "__"
  @model_name ~r/\A[a-zA-Z0-9_-]{1,64}\z/

  @type class :: :read | :effect

  @spec visible_tools([map()], [map()], keyword()) :: [map()]
  def visible_tools(entries, servers, options) do
    allowed = allowed_classes(options)

    for entry <- entries,
        class = class_of(servers, entry.server, entry.name),
        class in allowed,
        name = model_name(entry.server, entry.name),
        Regex.match?(@model_name, name) do
      %{
        name: name,
        description: entry.description,
        input_schema: entry.input_schema,
        server: entry.server,
        tool: entry.name,
        class: class
      }
    end
  end

  @spec authorize(term(), [map()], [map()], keyword()) ::
          {:ok, %{server: atom(), tool: String.t(), class: class()}}
          | {:error, :unknown_tool | :not_allowed}
  def authorize(model_name, entries, servers, options) when is_binary(model_name) do
    with true <- Regex.match?(@model_name, model_name),
         [server_part, tool] <- String.split(model_name, @separator, parts: 2),
         %{name: server_name} = server <-
           Enum.find(servers, &(Atom.to_string(&1.name) == server_part)),
         class when class != nil <- Map.get(server.tools, tool),
         true <- Enum.any?(entries, &(&1.server == server_name and &1.name == tool)) do
      if class in allowed_classes(options) do
        {:ok, %{server: server_name, tool: tool, class: class}}
      else
        {:error, :not_allowed}
      end
    else
      _not_shown -> {:error, :unknown_tool}
    end
  end

  def authorize(_model_name, _entries, _servers, _options), do: {:error, :unknown_tool}

  defp allowed_classes(options) do
    case Keyword.get(options, :tools) do
      :effect -> [:read, :effect]
      _default -> [:read]
    end
  end

  defp class_of(servers, server_name, tool) do
    case Enum.find(servers, &(&1.name == server_name)) do
      nil -> nil
      server -> Map.get(server.tools, tool)
    end
  end

  defp model_name(server_name, tool), do: Atom.to_string(server_name) <> @separator <> tool
end
