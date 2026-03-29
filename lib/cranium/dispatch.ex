defmodule Cranium.Dispatch do
  @moduledoc """
  Per-pass routing annotation stamped at ingest.

  A Dispatch is created when a user message enters the pipeline and carried
  unchanged through the pass. Providers receive the dispatch and use it to
  determine what kind of contribution to make and to key their caches.

  ## Fields

  - `conversation_id` — which conversation this pass belongs to
  - `harness` — inference backend (`:claude_code`, `:api`, `:ollama`)
  - `model` — specific model identifier (e.g., `:"claude-sonnet-4-6"`)
  - `renditions` — output renditions the client wants (`[:text]`, `[:audio, :text]`)
  - `ephemeral` — if true, nothing persists to Store (fire and forget)
  """

  use TypedStruct

  typedstruct do
    field :conversation_id, String.t()
    field :harness, :claude_code | :api | :ollama | nil
    field :model, atom() | String.t() | nil
    field :renditions, [:text | :audio], default: [:text]
    field :ephemeral, boolean(), default: false
  end

  @doc """
  Build a Dispatch from a submit request's parameters.

  Applies defaults from conversation config where per-request values
  are not provided.
  """
  @spec from_submit(map()) :: t()
  def from_submit(params) do
    %__MODULE__{
      conversation_id: params[:conversation_id] || params["conversation_id"] || "default",
      harness: resolve_harness(params[:harness] || params["harness"]),
      model: params[:model] || params["model"],
      renditions: resolve_renditions(params[:disposition] || params["disposition"]),
      ephemeral: params[:ephemeral] == true || params["ephemeral"] == true
    }
  end

  defp resolve_harness(nil), do: nil
  defp resolve_harness(h) when is_atom(h), do: h

  defp resolve_harness(h) when is_binary(h) do
    case h do
      "claude_code" -> :claude_code
      "api" -> :api
      "ollama" -> :ollama
      _ -> nil
    end
  end

  defp resolve_renditions(nil), do: [:text]
  defp resolve_renditions(list) when is_list(list), do: Enum.map(list, &to_rendition/1)
  defp resolve_renditions(_), do: [:text]

  defp to_rendition("audio"), do: :audio
  defp to_rendition("text"), do: :text
  defp to_rendition(:audio), do: :audio
  defp to_rendition(:text), do: :text
  defp to_rendition(_), do: :text
end
