defmodule Cranium.Stage do
  @moduledoc """
  Behaviour for pipeline stages.

  Every stage in the pipeline implements this behaviour. It provides two
  processing modes:

  1. **Complete message** — `process/2` receives a fully-formed input and
     returns a result. Used when the upstream delivers complete data.

  2. **Streaming** — `handle_chunk/3` receives incremental data identified
     by a stream ID. `handle_stream_end/2` is called when the stream
     completes. Stages that support incremental processing can forward
     chunks downstream immediately via `{:forward, data, state}`.
     Stages that need complete input return `{:buffer, state}` and
     process everything in `handle_stream_end/2`.

  ## Stream Caching Contract

  All stages cache streamed input until downstream delivery is confirmed.
  The stage GenServer is responsible for:
  - Accumulating chunks in `state.buffers[stream_id]`
  - Clearing the buffer only after successful downstream delivery
  - Enabling retry from cached data if streaming fails

  ## Implementing a Stage

      defmodule MyStage do
        use GenServer
        @behaviour Cranium.Stage

        @impl Cranium.Stage
        def process(message, context) do
          # Transform the message
          {:ok, transformed}
        end

        # Optional: streaming support
        @impl Cranium.Stage
        def handle_chunk(stream_id, chunk, state) do
          {:buffer, update_buffer(state, stream_id, chunk)}
        end

        @impl Cranium.Stage
        def handle_stream_end(stream_id, state) do
          data = get_buffer(state, stream_id)
          result = process_buffered(data)
          {:ok, result, clear_buffer(state, stream_id)}
        end
      end
  """

  @type stream_id :: String.t()

  @type stream_metadata :: %{
          optional(:conversation_id) => String.t(),
          optional(:epoch_id) => String.t(),
          optional(:mode) => :text | :voice,
          optional(:content_type) => :llm_response | :audio | :text,
          optional(:source) => atom(),
          optional(atom()) => term()
        }

  @doc """
  Process a complete message through this stage.

  `context` carries conversation state, epoch info, and configuration
  needed by the stage to do its work.
  """
  @callback process(message :: term(), context :: map()) ::
              {:ok, result :: term()} | {:error, reason :: term()}

  @doc """
  Called when a new stream begins, before any chunks arrive.

  Creates the buffer, captures metadata about the stream (conversation,
  epoch, mode, content type), and lets the stage prepare for incoming
  data. Without this, stages are blind on the first chunk.

  Return `{:ok, state}` to accept the stream, or `{:error, reason, state}`
  to reject it.
  """
  @callback handle_stream_start(stream_id(), stream_metadata(), state :: term()) ::
              {:ok, new_state :: term()} | {:error, reason :: term(), new_state :: term()}

  @doc """
  Handle an incoming streaming chunk.

  Return `{:buffer, state}` to accumulate, or `{:forward, data, state}`
  to pass transformed data downstream immediately.
  """
  @callback handle_chunk(stream_id(), chunk :: binary(), state :: term()) ::
              {:buffer, new_state :: term()} | {:forward, data :: term(), new_state :: term()}

  @doc """
  Called when a stream completes. Process any buffered data and return
  the final result.
  """
  @callback handle_stream_end(stream_id(), state :: term()) ::
              {:ok, result :: term(), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}

  @optional_callbacks [handle_stream_start: 3, handle_chunk: 3, handle_stream_end: 2]

  @doc """
  Generate a unique stream ID for a new streaming operation.
  """
  @spec new_stream_id() :: stream_id()
  def new_stream_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc """
  Initialize a stream buffer with metadata.

  Call this from `handle_stream_start/3` to prepare for incoming chunks.
  The metadata is stored alongside the chunk list so stages can reference
  it during processing.
  """
  @spec init_stream(map(), stream_id(), stream_metadata()) :: map()
  def init_stream(buffers, stream_id, metadata) do
    Map.put(buffers, stream_id, %{chunks: [], metadata: metadata})
  end

  @doc """
  Helper to update a buffer map with a new chunk.
  Chunks are prepended (reverse on read for efficiency).
  """
  @spec buffer_chunk(map(), stream_id(), binary()) :: map()
  def buffer_chunk(buffers, stream_id, chunk) do
    case Map.get(buffers, stream_id) do
      %{chunks: chunks} = entry ->
        Map.put(buffers, stream_id, %{entry | chunks: [chunk | chunks]})

      _ ->
        # Legacy path: no stream_start was sent, just store raw chunk list
        Map.update(buffers, stream_id, [chunk], &[chunk | &1])
    end
  end

  @doc """
  Read buffered chunks in order and clear the buffer.

  Returns `{data, remaining_buffers}` for legacy (chunk-list) buffers, or
  `{data, metadata, remaining_buffers}` for structured buffers initialized
  via `init_stream/3`.
  """
  @spec flush_buffer(map(), stream_id()) ::
          {binary(), map()} | {binary(), stream_metadata(), map()}
  def flush_buffer(buffers, stream_id) do
    case Map.get(buffers, stream_id) do
      %{chunks: chunks, metadata: metadata} ->
        data = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {data, metadata, Map.delete(buffers, stream_id)}

      chunks when is_list(chunks) ->
        data = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {data, Map.delete(buffers, stream_id)}

      nil ->
        {"", Map.delete(buffers, stream_id)}
    end
  end
end
