defmodule Cranium.Calls do
  @moduledoc """
  Inter-agent call/respond exchange (crn-7762).

  First-class primitives for cross-room agent communication, replacing
  the deprecated `--room` dispatch workaround. One agent `call`s another
  room with a disposition (`wait` / `notify` / `mute`); the receiving
  agent's turn runs normally and may `respond` to designate which part
  of its work crosses back to the caller. Only the respond payload is
  delivered — never the receiver's full turn output.

  ## Correlation state

  This actor owns all correlation state, in memory only. Delivery
  guarantee is "it landed in the room queue" — no durability, no retry.
  If a dispatch needs those, it belongs in a workflow poking a room,
  not here. Records are swept 24h after creation.

  ## Turn boundaries

  Delivered calls are normal passes: Delivery stamps a stream_id, and
  this actor watches global `{:pass_complete, _, stream_id, _}` events
  for the receiver's turn boundary. A `wait` caller whose receiver turn
  ends without a respond gets `no_reply_designated` — never a
  full-transcript fallback.

  ## Deadlock backstop

  A `wait` chain A→B→A jams until the caller's timeout fires (degrading
  the call to notify semantics). That is the v1 backstop — there is no
  cycle detection.
  """

  use GenServer
  require Logger

  alias Cranium.Calls.Logic

  @default_saturation_threshold 0.9
  @record_ttl_ms :timer.hours(24)
  @sweep_interval_ms :timer.hours(1)
  @injection_cap 50

  defmodule State do
    @moduledoc false
    defstruct calls: %{}, by_stream: %{}, injections: %{}
  end

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Place a call from `caller_room` to another room.

  `input` is the raw tool input (string keys): `room`, `message`,
  `disposition`, optional `timeout_ms`, optional `depth`.

  Returns `{:ok, result_map}` where the map always carries
  `:correlation_id` plus a `:status` of `:responded`, `:sent`,
  `:no_reply_designated`, `:timed_out`, or `:receiver_saturated` —
  or `{:error, reason_string}`.

  Blocks for `wait` dispositions; the internal timer guarantees a reply.
  """
  @spec place(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def place(caller_room, input) do
    GenServer.call(__MODULE__, {:place, caller_room, input}, :infinity)
  end

  @doc """
  Designate a respond payload for an incoming call.

  Returns `{:ok, :delivered | :recorded}` or
  `{:error, :unknown_correlation_id | :foreign_correlation_id}`.
  """
  @spec respond(String.t(), String.t(), String.t()) ::
          {:ok, :delivered | :recorded} | {:error, atom()}
  def respond(responder_room, correlation_id, payload) do
    GenServer.call(__MODULE__, {:respond, responder_room, correlation_id, payload})
  end

  @doc """
  Drain pending respond payloads addressed to a room.

  Called by TurnAssembler during context assembly; returns injection
  content strings in delivery order and clears them.
  """
  @spec drain_injections(String.t()) :: [String.t()]
  def drain_injections(room_id) do
    GenServer.call(__MODULE__, {:drain_injections, room_id})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe()
    schedule_sweep()
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:place, caller_room, input}, from, state) do
    with {:ok, params} <- Logic.validate(input),
         :ok <- check_target(caller_room, params.room),
         {:ok, target_ctx} <- lookup_target(params.room) do
      correlation_id = new_correlation_id()
      saturation = target_ctx.saturation || 0.0

      if Logic.saturated?(saturation, saturation_threshold()) do
        Logger.info("Calls: rejecting call to saturated room",
          conversation_id: caller_room,
          target_room: params.room,
          saturation: saturation
        )

        {:reply,
         {:ok,
          %{
            status: :receiver_saturated,
            correlation_id: correlation_id,
            saturation: saturation
          }}, state}
      else
        place_call(state, from, caller_room, params, correlation_id, target_ctx)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:respond, room, correlation_id, payload}, _from, state) do
    case Map.fetch(state.calls, correlation_id) do
      :error ->
        {:reply, {:error, :unknown_correlation_id}, state}

      {:ok, call} ->
        case Logic.respond_route(call, room) do
          {:error, _} = err ->
            {:reply, err, state}

          :deliver_to_waiter ->
            cancel_timer(call)

            GenServer.reply(
              call.waiter,
              {:ok, %{status: :responded, correlation_id: correlation_id, payload: payload}}
            )

            call = %{
              call
              | status: :responded,
                waiter: nil,
                timer_ref: nil,
                responses: call.responses ++ [payload]
            }

            {:reply, {:ok, :delivered}, put_call(state, call)}

          :queue_injection ->
            call = %{call | responses: call.responses ++ [payload]}
            content = Logic.injection_content(call.target_room, correlation_id, payload)
            state = queue_injection(put_call(state, call), call.caller_room, content)
            {:reply, {:ok, :recorded}, state}

          :record_only ->
            call = %{call | responses: call.responses ++ [payload]}
            {:reply, {:ok, :recorded}, put_call(state, call)}
        end
    end
  end

  @impl true
  def handle_call({:drain_injections, room_id}, _from, state) do
    {pending, injections} = Map.pop(state.injections, room_id, [])
    {:reply, pending, %{state | injections: injections}}
  end

  # Test support: synchronous flush ensures all prior messages are processed
  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  # --- Receiver turn boundary ---

  @impl true
  def handle_info({:pass_complete, _cid, stream_id, _payload}, state) do
    case Map.pop(state.by_stream, stream_id) do
      {nil, _} ->
        {:noreply, state}

      {correlation_id, by_stream} ->
        state = %{state | by_stream: by_stream}

        case Map.fetch(state.calls, correlation_id) do
          {:ok, %{waiter: waiter} = call} when not is_nil(waiter) ->
            cancel_timer(call)

            GenServer.reply(
              waiter,
              {:ok, %{status: :no_reply_designated, correlation_id: correlation_id}}
            )

            call = %{call | status: :no_reply_designated, waiter: nil, timer_ref: nil}
            {:noreply, put_call(state, call)}

          _ ->
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:call_timeout, correlation_id}, state) do
    case Map.fetch(state.calls, correlation_id) do
      {:ok, %{waiter: waiter} = call} when not is_nil(waiter) ->
        GenServer.reply(
          waiter,
          {:ok, %{status: :timed_out, correlation_id: correlation_id}}
        )

        # Degrade to notify semantics: any eventual respond arrives as
        # pre-turn injection on the caller's next turn.
        call = %{call | status: :timed_out, waiter: nil, timer_ref: nil}
        {:noreply, put_call(state, call)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @record_ttl_ms

    {dead, calls} =
      Map.split_with(state.calls, fn {_id, call} ->
        call.inserted_at < cutoff and is_nil(call.waiter)
      end)

    if map_size(dead) > 0 do
      Logger.info("Calls: swept #{map_size(dead)} expired correlation records")
    end

    dead_ids = Map.keys(dead) |> MapSet.new()

    by_stream =
      state.by_stream
      |> Enum.reject(fn {_stream_id, corr_id} -> MapSet.member?(dead_ids, corr_id) end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | calls: calls, by_stream: by_stream}}
  end

  # Registry topics are shared buses — catch-all is load-bearing.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp place_call(state, from, caller_room, params, correlation_id, target_ctx) do
    request = %{
      target_room: params.room,
      text:
        Logic.incoming_call_text(caller_room, correlation_id, params.message, params.disposition),
      origin: "call:" <> caller_room,
      profile: target_ctx[:profile],
      depth: params.depth + 1
    }

    case delivery_module().deliver(request) do
      {:ok, stream_id} ->
        Logger.info("Calls: placed #{params.disposition} call",
          conversation_id: caller_room,
          target_room: params.room,
          correlation_id: correlation_id,
          stream_id: stream_id
        )

        call = %{
          correlation_id: correlation_id,
          caller_room: caller_room,
          target_room: params.room,
          disposition: params.disposition,
          status: :pending,
          stream_id: stream_id,
          responses: [],
          waiter: nil,
          timer_ref: nil,
          inserted_at: System.monotonic_time(:millisecond)
        }

        state = %{state | by_stream: Map.put(state.by_stream, stream_id, correlation_id)}

        case params.disposition do
          :wait ->
            timer_ref =
              Process.send_after(self(), {:call_timeout, correlation_id}, params.timeout_ms)

            call = %{call | waiter: from, timer_ref: timer_ref}
            {:noreply, put_call(state, call)}

          _ ->
            {:reply, {:ok, %{status: :sent, correlation_id: correlation_id}},
             put_call(state, call)}
        end

      {:error, reason} ->
        {:reply, {:error, "delivery failed: #{reason}"}, state}
    end
  end

  defp check_target(caller_room, caller_room),
    do: {:error, "cannot call your own room"}

  defp check_target(_caller_room, _target_room), do: :ok

  defp lookup_target(room) do
    case Cranium.Store.get_injection_context(room) do
      {:ok, ctx} -> {:ok, ctx}
      :not_found -> {:error, "unknown room: #{room}"}
    end
  end

  defp put_call(state, call),
    do: %{state | calls: Map.put(state.calls, call.correlation_id, call)}

  defp queue_injection(state, room, content) do
    pending = Map.get(state.injections, room, [])
    {pending, dropped} = Logic.push_injection(pending, content, @injection_cap)

    if dropped > 0 do
      Logger.warning(
        "Calls: dropped #{dropped} oldest pending injections (cap #{@injection_cap})",
        conversation_id: room
      )
    end

    %{state | injections: Map.put(state.injections, room, pending)}
  end

  defp cancel_timer(%{timer_ref: nil}), do: :ok
  defp cancel_timer(%{timer_ref: ref}), do: Process.cancel_timer(ref)

  defp new_correlation_id, do: "call_" <> Ecto.UUID.generate()

  defp delivery_module,
    do: Application.get_env(:cranium, :call_delivery, Cranium.Calls.Delivery)

  defp saturation_threshold,
    do: Application.get_env(:cranium, :call_saturation_threshold, @default_saturation_threshold)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
