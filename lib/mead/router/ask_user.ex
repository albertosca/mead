defmodule Mead.Router.AskUser do
  @moduledoc """
  The built-in `ask_user` tool: lets the model put a short multiple-choice question to the person
  and use the answer.

  It is offered only to a turn that has an interaction and at least one other tool (see
  `Mead.Router`), is answered by the router itself and never reaches `Mead.MCP.Hub`. Its name has
  no `__`, which is what an MCP tool always has in the model's view (`server__tool`), so a server
  cannot shadow it. The policy never gates it: it changes nothing outside the conversation.
  """

  @name "ask_user"
  @maximum_prompt_characters 500
  @maximum_label_characters 80
  @maximum_identifier_characters 128

  @spec name() :: String.t()
  def name, do: @name

  @spec tool() :: %{name: String.t(), description: String.t(), input_schema: map()}
  def tool do
    %{
      name: @name,
      description:
        "Ask the person a short multiple-choice question when you need a decision only they can make. " <>
          "Give 2 to 6 options; the answer comes back as the label of the chosen option. " <>
          "Set allow_free_text to true when the options may not cover what the person wants to say; " <>
          "the answer may then be their own words.",
      input_schema: %{
        "type" => "object",
        "required" => ["prompt", "options"],
        "properties" => %{
          "prompt" => %{"type" => "string", "maxLength" => @maximum_prompt_characters},
          "options" => %{
            "type" => "array",
            "minItems" => 2,
            "maxItems" => 6,
            "items" => %{
              "type" => "object",
              "required" => ["id", "label"],
              "properties" => %{
                "id" => %{"type" => "string"},
                "label" => %{"type" => "string", "maxLength" => @maximum_label_characters}
              }
            }
          },
          "allow_free_text" => %{"type" => "boolean"}
        }
      }
    }
  end

  @doc "Checks the arguments the model gave; extra fields are ignored."
  @spec validate(term()) ::
          {:ok,
           %{
             prompt: String.t(),
             options: [%{id: String.t(), label: String.t()}],
             allow_free_text: boolean()
           }}
          | {:error, String.t()}
  def validate(%{"prompt" => prompt, "options" => options} = input) do
    with :ok <- check_prompt(prompt),
         {:ok, options} <- check_options(options),
         {:ok, allow_free_text} <- check_free_text(Map.get(input, "allow_free_text", false)) do
      {:ok, %{prompt: prompt, options: options, allow_free_text: allow_free_text}}
    end
  end

  def validate(_input), do: {:error, "prompt and options are required"}

  defp check_prompt(prompt) when is_binary(prompt) do
    if String.valid?(prompt) and String.trim(prompt) != "" and
         String.length(prompt) <= @maximum_prompt_characters,
       do: :ok,
       else: {:error, "prompt must be a text of 1 to #{@maximum_prompt_characters} characters"}
  end

  defp check_prompt(_prompt),
    do: {:error, "prompt must be a text of 1 to #{@maximum_prompt_characters} characters"}

  defp check_free_text(value) when is_boolean(value), do: {:ok, value}
  defp check_free_text(_value), do: {:error, "allow_free_text must be true or false"}

  defp check_options(options) when is_list(options) and length(options) in 2..6 do
    parsed = Enum.map(options, &parse_option/1)

    cond do
      Enum.any?(parsed, &(&1 == :error)) ->
        {:error,
         "each option needs a non-empty id and a label of 1 to #{@maximum_label_characters} characters"}

      parsed |> Enum.map(& &1.id) |> Enum.uniq() |> length() != length(parsed) ->
        {:error, "option ids must be unique"}

      true ->
        {:ok, parsed}
    end
  end

  defp check_options(_options), do: {:error, "options must be a list of 2 to 6 choices"}

  defp parse_option(%{"id" => id, "label" => label}) when is_binary(id) and is_binary(label) do
    if valid_text?(id, @maximum_identifier_characters) and
         valid_text?(label, @maximum_label_characters),
       do: %{id: id, label: label},
       else: :error
  end

  defp parse_option(_option), do: :error

  defp valid_text?(text, maximum),
    do: String.valid?(text) and String.trim(text) != "" and String.length(text) <= maximum
end
