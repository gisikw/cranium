defmodule Cranium.Inference.SystemPrompt do
  @moduledoc """
  System prompt provider.

  Assembles the system prompt from an identity string and the handoff from
  the previous epoch. Identity is provided per-call by TurnAssembler
  (resolved from the active profile via `Cranium.Config`).

  Caches the resolved handoff per-conversation so the system prompt is
  **stable across all turns** in an epoch.

  Cache lifecycle: on `is_fresh`, any existing cache for that conversation is
  invalidated and re-resolved. On subsequent turns, the cached value is
  returned. A cached `:none` means "looked it up, nothing there" — avoids
  repeated DB/disk reads for conversations with no handoff.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return the assembled system prompt for a conversation.

  ## Options

  - `:is_fresh` — boolean, whether this is the first turn (invalidates + re-resolves handoff cache)
  - `:identity` — optional override string (replaces cached identity for this call)
  - `:tools_prompt` — optional string, tool guidance to inject between identity and handoff
  """
  @spec contribute(String.t(), keyword()) :: String.t()
  def contribute(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:contribute, conversation_id, opts})
  end

  @doc """
  Return both the flattened system prompt and Tiamat-style prompt fragments.

  `pre` contains durable Cranium identity. `post` contains Cranium-owned dynamic
  context that should stay after Tiamat's substrate-specific middle steering.
  """
  @spec fragments(String.t(), keyword()) :: %{system: String.t(), pre: [map()], post: [map()]}
  def fragments(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:fragments, conversation_id, opts})
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    {:ok, %{handoffs: %{}}}
  end

  @impl true
  def handle_call({:contribute, conversation_id, opts}, _from, state) do
    {fragments, state} = build_fragments(conversation_id, opts, state)
    {:reply, fragments.system, state}
  end

  @impl true
  def handle_call({:fragments, conversation_id, opts}, _from, state) do
    {fragments, state} = build_fragments(conversation_id, opts, state)
    {:reply, fragments, state}
  end

  # --- Private ---

  defp build_fragments(conversation_id, opts, state) do
    is_fresh = Keyword.get(opts, :is_fresh, false)
    identity = Keyword.get(opts, :identity) || ""
    tools_prompt = Keyword.get(opts, :tools_prompt)

    # is_fresh means new epoch — invalidate any stale cache before lookup
    handoffs =
      if is_fresh do
        Map.delete(state.handoffs, conversation_id)
      else
        state.handoffs
      end

    {handoff, handoffs} =
      case Map.get(handoffs, conversation_id) do
        nil ->
          content = resolve_handoff(conversation_id)
          cached = content || :none
          {content, Map.put(handoffs, conversation_id, cached)}

        :none ->
          {nil, handoffs}

        cached ->
          {cached, handoffs}
      end

    pre = prompt_fragment_list([{"cranium-identity", identity}])

    post =
      []
      |> maybe_add_fragment("cranium-tools", tools_prompt)
      |> maybe_add_fragment("cranium-handoff", handoff_block(handoff))

    system_prompt =
      (Enum.map(pre, & &1["text"]) ++ Enum.map(post, & &1["text"]))
      |> Enum.join("\n\n")

    {%{system: system_prompt, pre: pre, post: post}, %{state | handoffs: handoffs}}
  end

  defp prompt_fragment_list(fragments) do
    fragments
    |> Enum.reduce([], fn {id, text}, acc -> maybe_add_fragment(acc, id, text) end)
  end

  defp maybe_add_fragment(fragments, _id, text) when not is_binary(text) or text == "" do
    fragments
  end

  defp maybe_add_fragment(fragments, id, text), do: fragments ++ [%{"id" => id, "text" => text}]

  defp handoff_block(nil), do: nil
  defp handoff_block(content), do: "<room-handoff>\n" <> content <> "\n</room-handoff>"

  # --- Private ---

  defp resolve_handoff(conversation_id) do
    case Cranium.Store.get_latest_handoff(conversation_id) do
      {:ok, content} -> content
      :not_found -> resolve_handoff_from_disk(conversation_id)
    end
  end

  defp resolve_handoff_from_disk(conversation_id) do
    base = Application.get_env(:cranium, :paths)[:handoffs]

    if base do
      dir = Path.join(base, conversation_id)

      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort()
          |> List.last()
          |> case do
            nil -> nil
            file -> File.read!(Path.join(dir, file))
          end

        {:error, _} ->
          nil
      end
    end
  end
end
