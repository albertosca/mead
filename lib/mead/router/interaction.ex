defmodule Mead.Router.Interaction do
  @moduledoc """
  What the router asks of a person (or of a policy standing in for one) around each tool call.

  A turn that carries `interaction: {module, context}` in its options makes `Mead.Router` call this
  behaviour for every tool the model asks for, in this order: `tool_updated/2` with status
  `:pending`, `request_permission/2`, and, when the answer is `:allow`, `tool_updated/2` with
  `register_call/3` and `:in_progress` (with `cancellable: true`), the tool itself, then `tool_updated/2` with `:completed` or `:failed`. A denied
  call never reaches the hub; the model receives an error result that says why. A tool the model
  named wrongly is reported `:failed` without asking anyone.

  The callbacks run in the process that runs the turn, one call at a time, so `request_permission/2`
  may block for as long as it takes to get an answer. A turn without `:interaction` never touches
  this module.
  """

  @type request :: %{
          tool_call_id: String.t(),
          tool: String.t(),
          server: String.t(),
          class: :read | :effect,
          arguments: term()
        }

  @type update :: %{
          tool_call_id: String.t(),
          title: String.t(),
          status: :pending | :in_progress | :completed | :failed,
          current_step: String.t() | nil,
          progress: float() | nil,
          cancellable: boolean()
        }

  @callback request_permission(context :: term(), request()) ::
              :allow | {:deny, :rejected | :expired}
  @callback tool_updated(context :: term(), update()) :: :ok

  @type choice :: %{
          tool_call_id: String.t(),
          prompt: String.t(),
          options: [%{id: String.t(), label: String.t()}]
        }

  @doc """
  Called with each fragment of text a streaming provider produces while it answers, in order. The
  fragments are a preview of the answer the turn returns; a provider that cannot stream never
  calls it.
  """
  @callback text_delta(context :: term(), text :: String.t()) :: :ok

  @doc """
  Puts a multiple-choice question (the `ask_user` tool) to the person. Returns the `id` of the
  option they picked, `{:error, :expired}` when the time ran out and `{:error, :no_answer}` when
  nobody could answer. Like `request_permission/2` it may block until there is an answer.
  """
  @callback ask_choice(context :: term(), choice()) ::
              {:ok, String.t()} | {:error, :expired | :no_answer}

  @doc """
  Called once an allowed tool call is running in its own process, before the `:in_progress`
  update, so whoever can cancel the call (by killing `pid`) knows which process to kill.
  """
  @callback register_call(context :: term(), tool_call_id :: String.t(), pid :: pid()) :: :ok

  @doc "Whether `value` is a `{module, context}` pair whose module implements this behaviour."
  @spec valid?(term()) :: boolean()
  def valid?({module, _context}) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :request_permission, 2) and
      function_exported?(module, :tool_updated, 2) and
      function_exported?(module, :register_call, 3) and
      function_exported?(module, :ask_choice, 2) and
      function_exported?(module, :text_delta, 2)
  end

  def valid?(_other), do: false
end
