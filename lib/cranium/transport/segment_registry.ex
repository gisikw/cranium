defmodule Cranium.Transport.SegmentRegistry do
  @moduledoc """
  Registry for chunked audio input segments.

  Tracks open takes, buffers numbered chunks, computes missing sequences
  on seal, and assembles the final audio binary when complete.

  Segment arrival tracking is a Transport concern — the "missing chunks"
  HTTP response is protocol-level bookkeeping.
  """

  use GenServer
  require Logger

  alias Cranium.Messages.Transcription

  defmodule Take do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :take_id, String.t()
      field :stream_id, String.t()
      field :conversation_id, String.t()
      field :disposition, [String.t()]
      field :origin, String.t() | nil
      field :last_seq, non_neg_integer() | nil
      field :completed_at, integer() | nil
      field :opened_at, integer() | nil
      field :chunks, map(), default: %{}
      field :status, :open | :sealed | :complete, default: :open
    end
  end

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec open(String.t(), String.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, :conflict}
  def open(take_id, stream_id, conversation_id, disposition, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    origin = Keyword.get(opts, :origin)
    GenServer.call(name, {:open, take_id, stream_id, conversation_id, disposition, origin})
  end

  @spec put_chunk(String.t(), non_neg_integer(), binary(), keyword()) ::
          {:ok, :buffered} | {:ok, :complete, map()} | {:error, atom()}
  def put_chunk(take_id, seq, data, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:put_chunk, take_id, seq, data})
  end

  @spec seal(String.t(), non_neg_integer(), keyword()) ::
          {:ok, :complete, map()} | {:ok, :incomplete, [non_neg_integer()]} | {:error, atom()}
  def seal(take_id, last_seq, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:seal, take_id, last_seq})
  end

  # --- GenServer Implementation ---

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe()
    ttl_ms = Application.get_env(:cranium, :take_ttl_ms, 86_400_000)
    Process.send_after(self(), :cleanup, ttl_ms)
    Logger.info("SegmentRegistry started (ttl=#{ttl_ms}ms)")
    {:ok, %{takes: %{}, ttl_ms: ttl_ms}}
  end

  @impl true
  def handle_call({:open, take_id, stream_id, conversation_id, disposition, origin}, _from, state) do
    if Map.has_key?(state.takes, take_id) do
      {:reply, {:error, :conflict}, state}
    else
      take = %Take{
        take_id: take_id,
        stream_id: stream_id,
        conversation_id: conversation_id,
        disposition: disposition,
        origin: origin,
        opened_at: System.monotonic_time(:millisecond)
      }

      Logger.info(
        "Input start: take=#{take_id} stream=#{stream_id} conversation=#{conversation_id}"
      )

      {:reply, :ok, %{state | takes: Map.put(state.takes, take_id, take)}}
    end
  end

  @impl true
  def handle_call({:put_chunk, take_id, seq, data}, _from, state) do
    case do_put_chunk(state, take_id, seq, data) do
      {:ok, state, {:complete, result}} ->
        {:reply, {:ok, :complete, result}, state}

      {:ok, state} ->
        {:reply, {:ok, :buffered}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:seal, take_id, last_seq}, _from, state) do
    case Map.get(state.takes, take_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      take ->
        take = %{take | status: :sealed, last_seq: last_seq}

        case check_completeness(take) do
          {:complete, result} ->
            take = %{take | status: :complete, completed_at: System.monotonic_time(:millisecond)}

            {:reply, {:ok, :complete, result},
             %{state | takes: Map.put(state.takes, take_id, take)}}

          :incomplete ->
            expected = MapSet.new(0..last_seq)
            received = MapSet.new(Map.keys(take.chunks))
            missing = MapSet.difference(expected, received) |> MapSet.to_list() |> Enum.sort()

            {:reply, {:ok, :incomplete, missing},
             %{state | takes: Map.put(state.takes, take_id, take)}}
        end
    end
  end

  # Chunked transcription results: keep chunk tracking in sync for the
  # /v1/input/:id/done missing-chunk response.
  @impl true
  def handle_info(
        {:transcription_complete, %Transcription{take_id: take_id, seq: seq, text: text}},
        state
      )
      when not is_nil(seq) do
    state =
      case do_put_chunk(state, take_id, seq, text) do
        {:ok, new_state} -> new_state
        {:error, _reason} -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    takes =
      state.takes
      |> Enum.reject(fn {_id, take} ->
        cond do
          take.status == :complete and now - take.completed_at >= state.ttl_ms -> true
          take.status in [:open, :sealed] and now - take.opened_at >= state.ttl_ms -> true
          true -> false
        end
      end)
      |> Map.new()

    Process.send_after(self(), :cleanup, state.ttl_ms)
    {:noreply, %{state | takes: takes}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp do_put_chunk(state, take_id, seq, data) do
    case Map.get(state.takes, take_id) do
      nil ->
        {:error, :not_found}

      %Take{status: :complete} ->
        {:error, :already_complete}

      take ->
        take = %{take | chunks: Map.put(take.chunks, seq, data)}

        case check_completeness(take) do
          {:complete, result} ->
            take = %{take | status: :complete, completed_at: System.monotonic_time(:millisecond)}
            {:ok, %{state | takes: Map.put(state.takes, take_id, take)}, {:complete, result}}

          :incomplete ->
            {:ok, %{state | takes: Map.put(state.takes, take_id, take)}}
        end
    end
  end

  defp check_completeness(%Take{status: status, last_seq: last_seq, chunks: chunks} = take)
       when status == :sealed and not is_nil(last_seq) do
    expected = MapSet.new(0..last_seq)
    received = MapSet.new(Map.keys(chunks))

    if MapSet.equal?(expected, received) do
      data = chunks |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.join()
      key = take.disposition |> List.first("text") |> String.to_atom()

      {:complete,
       %{
         key => data,
         stream_id: take.stream_id,
         conversation_id: take.conversation_id,
         disposition: take.disposition,
         origin: take.origin
       }}
    else
      :incomplete
    end
  end

  defp check_completeness(_take), do: :incomplete
end
