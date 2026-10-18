defmodule Mead.Router.Classifier do
  @moduledoc """
  Decides whether a turn is routine enough for the local model or needs the cloud.

  The decision is a pure function of the input and the history, so it is deterministic and
  testable without a network. Local is chosen only when the input positively looks routine; any
  doubt goes to the cloud, where the quality is. The rules are applied in this order:

    1. an input that is not a string, or not valid UTF-8, is `:cloud`, because it cannot be judged;
    2. an input longer than 280 characters is `:cloud`;
    3. a history of more than 20 turns is `:cloud`, because the context is heavy;
    4. an input that asks for reasoning or writing is `:cloud`;
    5. an input that asks for triage or formatting is `:local`;
    6. anything else is `:cloud`.
  """

  alias Mead.Session.Turn

  @maximum_local_length 280
  @maximum_local_history 20

  @reasoning_pattern ~r/\b(explain|analy[sz]e|compare|design|plan|summari[sz]e|write|draft|why|reason|step by step|explique|analise|compare|planeje|resuma|escreva|por qu[eê])\b/iu
  @triage_pattern ~r/\b(status|list|format|categori[sz]e|classify|triage|parse|check|count|liste|formate|categorize|classifique|conte|confira)\b/iu

  @doc "Returns the route the heuristic picks for `input` given the turns recorded so far."
  @spec classify([Turn.t()], term()) :: :local | :cloud
  def classify(history, input) when is_binary(input) do
    cond do
      not String.valid?(input) -> :cloud
      String.length(input) > @maximum_local_length -> :cloud
      length(history) > @maximum_local_history -> :cloud
      Regex.match?(@reasoning_pattern, input) -> :cloud
      Regex.match?(@triage_pattern, input) -> :local
      true -> :cloud
    end
  end

  def classify(_history, _input), do: :cloud
end
