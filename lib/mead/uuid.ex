defmodule Mead.UUID do
  @moduledoc """
  Generates random (version 4) UUID strings without any dependency.
  """

  @doc """
  Returns a lowercase UUID v4 string such as `"3f2b8c1e-9d4a-4b7e-8a15-6c0d2e9f4a31"`.
  """
  @spec generate() :: String.t()
  def generate do
    <<time_low::32, time_middle::16, _version::4, time_high::12, _variant::2, clock_and_node::62>> =
      :crypto.strong_rand_bytes(16)

    <<time_low::32, time_middle::16, 4::4, time_high::12, 2::2, clock_and_node::62>>
    |> Base.encode16(case: :lower)
    |> format()
  end

  defp format(
         <<first::binary-8, second::binary-4, third::binary-4, fourth::binary-4,
           fifth::binary-12>>
       ) do
    Enum.join([first, second, third, fourth, fifth], "-")
  end
end
