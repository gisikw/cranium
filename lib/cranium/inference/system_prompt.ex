defmodule Cranium.Inference.SystemPrompt do
  @moduledoc """
  System prompt provider.

  Assembles the system prompt from an identity document and (on fresh epochs)
  the handoff from the previous epoch. Caches the identity document on init
  so it's read from disk once, not per pass.

  ## Contribute

  `contribute/2` returns the assembled system prompt string. Options:

  - `:is_fresh` — whether this is the first turn of the epoch. When true,
    appends the previous epoch's handoff as a `<room-handoff>` block.
  - `:identity` — optional identity override (e.g., from transport). When
    provided, replaces the cached identity document for this call only.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return the assembled system prompt for a conversation.

  ## Options

  - `:is_fresh` — boolean, whether this is the first turn (triggers handoff inclusion)
  - `:identity` — optional override string (replaces cached identity for this call)
  """
  @spec contribute(String.t(), keyword()) :: String.t()
  def contribute(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:contribute, conversation_id, opts})
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    {:ok, %{identity: ""}, {:continue, :load_identity}}
  end

  @impl true
  def handle_continue(:load_identity, state) do
    identity = load_identity_from_disk()
    Logger.info("SystemPrompt: identity loaded (#{byte_size(identity)} bytes)")
    {:noreply, %{state | identity: identity}}
  end

  @impl true
  def handle_call({:contribute, conversation_id, opts}, _from, state) do
    is_fresh = Keyword.get(opts, :is_fresh, false)

    identity =
      case Keyword.get(opts, :identity) do
        override when is_binary(override) and override != "" -> override
        _ -> state.identity
      end

    handoff =
      if is_fresh do
        resolve_handoff(conversation_id)
      end

    system_prompt =
      case handoff do
        nil -> identity
        content -> identity <> "\n\n<room-handoff>\n" <> content <> "\n</room-handoff>"
      end

    {:reply, system_prompt, state}
  end

  # --- Private ---

  defp load_identity_from_disk do
    path = Application.get_env(:cranium, :paths)[:identity]

    if path do
      case File.read(path) do
        {:ok, content} ->
          content

        {:error, reason} ->
          Logger.warning("SystemPrompt: failed to load identity",
            path: path,
            reason: reason
          )

          ""
      end
    else
      Logger.warning("SystemPrompt: no identity path configured")
      ""
    end
  end

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
