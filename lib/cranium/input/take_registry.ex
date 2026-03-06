defmodule Cranium.Input.TakeRegistry do
  @moduledoc """
  Registry for chunked audio input takes.

  Tracks open takes, buffers numbered chunks, computes missing sequences
  on seal, and assembles the final audio binary when complete.
  """

  use GenServer
  require Logger

  defmodule Take do
    @moduledoc false
    defstruct [
      :take_id,
      :stream_id,
      :conversation_id,
      :disposition,
      :last_seq,
      :completed_at,
      :opened_at,
      chunks: %{},
      status: :open
    ]
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def open(take_id, stream_id, conversation_id, disposition, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:open, take_id, stream_id, conversation_id, disposition})
  end

  def put_chunk(take_id, seq, data, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:put_chunk, take_id, seq, data})
  end

  def seal(take_id, last_seq, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:seal, take_id, last_seq})
  end

  # --- GenServer Implementation ---

  @impl true
  def init(_opts) do
    ttl_ms = Application.get_env(:cranium, :take_ttl_ms, 86_400_000)
    Process.send_after(self(), :cleanup, ttl_ms)
    Logger.info("TakeRegistry started (ttl=#{ttl_ms}ms)")
    {:ok, %{takes: %{}, ttl_ms: ttl_ms}}
  end

  @impl true
  def handle_call({:open, take_id, stream_id, conversation_id, disposition}, _from, state) do
    if Map.has_key?(state.takes, take_id) do
      {:reply, {:error, :conflict}, state}
    else
      take = %Take{
        take_id: take_id,
        stream_id: stream_id,
        conversation_id: conversation_id,
        disposition: disposition,
        opened_at: System.monotonic_time(:millisecond)
      }

      Logger.info("Input start: take=#{take_id} stream=#{stream_id} conversation=#{conversation_id}")
      {:reply, :ok, %{state | takes: Map.put(state.takes, take_id, take)}}
    end
  end

  @impl true
  def handle_call({:put_chunk, take_id, seq, data}, _from, state) do
    case Map.get(state.takes, take_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Take{status: :complete} ->
        {:reply, {:error, :already_complete}, state}

      take ->
        take = %{take | chunks: Map.put(take.chunks, seq, data)}

        case check_completeness(take) do
          {:complete, result} ->
            take = %{take | status: :complete, completed_at: System.monotonic_time(:millisecond)}
            {:reply, {:ok, :complete, result}, %{state | takes: Map.put(state.takes, take_id, take)}}

          :incomplete ->
            {:reply, {:ok, :buffered}, %{state | takes: Map.put(state.takes, take_id, take)}}
        end
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
            {:reply, {:ok, :complete, result}, %{state | takes: Map.put(state.takes, take_id, take)}}

          :incomplete ->
            expected = MapSet.new(0..last_seq)
            received = MapSet.new(Map.keys(take.chunks))
            missing = MapSet.difference(expected, received) |> MapSet.to_list() |> Enum.sort()
            {:reply, {:ok, :incomplete, missing}, %{state | takes: Map.put(state.takes, take_id, take)}}
        end
    end
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

  # --- Private ---

  defp check_completeness(%Take{status: status, last_seq: last_seq, chunks: chunks} = take)
       when status == :sealed and not is_nil(last_seq) do
    expected = MapSet.new(0..last_seq)
    received = MapSet.new(Map.keys(chunks))

    if MapSet.equal?(expected, received) do
      audio = chunks |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
      {:complete, %{audio: audio, stream_id: take.stream_id, conversation_id: take.conversation_id, disposition: take.disposition}}
    else
      :incomplete
    end
  end

  defp check_completeness(_take), do: :incomplete
end
