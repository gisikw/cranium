defmodule Cranium.TTS.Cache do
  @moduledoc """
  In-memory TTS audio cache keyed by `{stream_id, segment_index}`.

  Sits between the Synthesizer (which produces audio) and the HTTP transport
  (which serves it). Two paths to audio:

  - **Eager warming**: Egress marks a segment as `:warming` via `mark_warming/3`,
    then a Task synthesizes and calls `put/4`. The cache entry transitions from
    `:warming` → audio binary.
  - **Lazy synthesis**: `get/3` finds no cached entry and no warming marker,
    pulls text from the local text cache (populated via segment_ready events),
    synthesizes on the caller's process, and returns the audio.

  When `get/3` finds a `:warming` marker, it polls until audio arrives or a
  timeout expires, avoiding duplicate TTS requests.

  Entries persist until the cleanup timer fires — multiple readers can safely
  fetch the same segment without racing. When a stream completes,
  `schedule_cleanup/2` sets a timer to sweep all entries after a configurable
  delay (default 5 min).
  """

  use GenServer

  require Logger

  @cleanup_delay :timer.minutes(5)
  @warming_poll_interval 200
  @warming_timeout 120_000

  use TypedStruct

  typedstruct do
    field :entries, map(), default: %{}
    field :text_cache, map(), default: %{}
    field :cleanup_timers, map(), default: %{}
  end

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get audio for a segment. Checks cache first (evicting on hit), waits if
  warming is in progress, falls back to lazy synthesis if no warm was started.

  Returns `{:ok, audio_binary}` or `{:error, reason}`.
  """
  @spec get(String.t(), non_neg_integer(), atom()) :: {:ok, binary()} | {:error, term()}
  def get(stream_id, index, name \\ __MODULE__) do
    case GenServer.call(name, {:get, stream_id, index}) do
      {:ok, audio} -> {:ok, audio}
      :warming -> await_warm(stream_id, index, name)
      :not_found -> synthesize_lazy(stream_id, index, name)
    end
  end

  @doc """
  Mark a segment as warming (synthesis in progress). Prevents duplicate
  TTS requests when the client polls before the warm completes.
  """
  @spec mark_warming(String.t(), non_neg_integer(), atom()) :: :ok
  def mark_warming(stream_id, index, name \\ __MODULE__) do
    GenServer.call(name, {:put, stream_id, index, :warming})
  end

  @doc """
  Pre-cache audio for a segment (eager warming complete).
  """
  @spec put(String.t(), non_neg_integer(), binary() | :error, atom()) :: :ok
  def put(stream_id, index, audio, name \\ __MODULE__) do
    GenServer.call(name, {:put, stream_id, index, audio})
  end

  @doc """
  Schedule cleanup of all entries for a stream after the cleanup delay.
  Call this when the stream completes.
  """
  @spec schedule_cleanup(String.t(), atom()) :: :ok
  def schedule_cleanup(stream_id, name \\ __MODULE__) do
    GenServer.cast(name, {:schedule_cleanup, stream_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    delay = Keyword.get(opts, :cleanup_delay, @cleanup_delay)
    Registry.register(Cranium.StreamRegistry, {:global}, [])
    Logger.info("TTS cache started")
    {:ok, %__MODULE__{} |> Map.put(:cleanup_delay, delay)}
  end

  @impl true
  def handle_call({:get, stream_id, index}, _from, state) do
    key = {stream_id, index}

    case Map.fetch(state.entries, key) do
      {:ok, :warming} ->
        {:reply, :warming, state}

      {:ok, :error} ->
        entries = Map.delete(state.entries, key)
        {:reply, :not_found, %{state | entries: entries}}

      {:ok, audio} ->
        {:reply, {:ok, audio}, state}

      :error ->
        {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call({:get_text, stream_id, index}, _from, state) do
    reply =
      case Map.fetch(state.text_cache, {stream_id, index}) do
        {:ok, text} -> {:ok, text}
        :error -> :not_found
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:put, stream_id, index, audio}, _from, state) do
    key = {stream_id, index}
    entries = Map.put(state.entries, key, audio)
    {:reply, :ok, %{state | entries: entries}}
  end

  @impl true
  def handle_cast({:schedule_cleanup, stream_id}, state) do
    state = cancel_timer(state, stream_id)
    delay = Map.get(state, :cleanup_delay, @cleanup_delay)
    ref = Process.send_after(self(), {:cleanup, stream_id}, delay)
    timers = Map.put(state.cleanup_timers, stream_id, ref)
    {:noreply, %{state | cleanup_timers: timers}}
  end

  @impl true
  def handle_info({:segment_ready, stream_id, index, %{type: :utterance, text: text}}, state) do
    text_cache = Map.put(state.text_cache, {stream_id, index}, text)
    {:noreply, %{state | text_cache: text_cache}}
  end

  @impl true
  def handle_info({:cleanup, stream_id}, state) do
    {evicted, remaining} =
      Enum.split_with(state.entries, fn {{sid, _}, _} -> sid == stream_id end)

    text_remaining =
      state.text_cache
      |> Enum.reject(fn {{sid, _}, _} -> sid == stream_id end)
      |> Map.new()

    timers = Map.delete(state.cleanup_timers, stream_id)

    if length(evicted) > 0 do
      Logger.info(
        "TTS cache: evicted #{length(evicted)} unconsumed entries for stream #{stream_id}"
      )
    end

    {:noreply, %{state | entries: Map.new(remaining), text_cache: text_remaining, cleanup_timers: timers}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp await_warm(stream_id, index, name) do
    await_warm(stream_id, index, name, 0)
  end

  defp await_warm(stream_id, index, _name, elapsed) when elapsed >= @warming_timeout do
    Logger.error("TTS cache: warming timeout for stream=#{stream_id} segment=#{index}")
    {:error, :warming_timeout}
  end

  defp await_warm(stream_id, index, name, elapsed) do
    Process.sleep(@warming_poll_interval)

    case GenServer.call(name, {:get, stream_id, index}) do
      {:ok, audio} -> {:ok, audio}
      :warming -> await_warm(stream_id, index, name, elapsed + @warming_poll_interval)
      :not_found -> {:error, :warming_failed}
    end
  end

  defp cancel_timer(state, stream_id) do
    case Map.fetch(state.cleanup_timers, stream_id) do
      {:ok, ref} ->
        Process.cancel_timer(ref)
        %{state | cleanup_timers: Map.delete(state.cleanup_timers, stream_id)}

      :error ->
        state
    end
  end

  defp synthesize_lazy(stream_id, index, name) do
    case GenServer.call(name, {:get_text, stream_id, index}) do
      {:ok, text} ->
        backend = Application.get_env(:cranium, :backends)[:tts] || Cranium.Backend.TTS.ExoVoice
        backend.synthesize(text, [])

      :not_found ->
        {:error, :segment_not_found}
    end
  end
end
