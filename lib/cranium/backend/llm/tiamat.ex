defmodule Cranium.Backend.LLM.Tiamat do
  @moduledoc """
  Tiamat router backend placeholder.

  Profiles using `backend: tiamat` resolve to this module and carry a
  `router_profile` string plus backend configuration such as the Tiamat endpoint.
  The streaming `/v1/router/turns` adapter is implemented in the follow-up
  backend ticket; until then this module exists so config/profile routing can be
  validated without selecting a concrete provider model in Cranium.
  """

  @behaviour Cranium.Backend.LLM

  @impl true
  def manages_tool_loop?, do: false

  @impl true
  def stream_chat(_messages, _opts) do
    {:error, :tiamat_backend_not_implemented}
  end
end
