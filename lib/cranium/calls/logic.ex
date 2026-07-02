defmodule Cranium.Calls.Logic do
  @moduledoc """
  Pure decision functions for the call/respond primitives.

  Private to `Cranium.Calls` — validation, respond routing, and wire
  formatting live here so they can be unit-tested without the GenServer.
  No I/O, no side effects.
  """

  @default_timeout_ms 600_000
  @min_timeout_ms 1_000
  @max_timeout_ms 1_800_000

  @dispositions %{"wait" => :wait, "notify" => :notify, "mute" => :mute}

  @type disposition :: :wait | :notify | :mute

  @type call_params :: %{
          room: String.t(),
          message: String.t(),
          disposition: disposition(),
          timeout_ms: pos_integer() | nil,
          depth: non_neg_integer()
        }

  @doc "Ceiling for `timeout_ms` — exposed so the tool's executor backstop can sit above it."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @doc """
  Validate raw tool input (string keys, model-supplied) into call params.

  `timeout_ms` applies to `wait` only and is silently ignored otherwise;
  for `wait` it defaults to #{@default_timeout_ms} ms and is clamped to
  #{@min_timeout_ms}..#{@max_timeout_ms}.
  """
  @spec validate(map()) :: {:ok, call_params()} | {:error, String.t()}
  def validate(input) when is_map(input) do
    with {:ok, room} <- require_string(input, "room"),
         {:ok, message} <- require_string(input, "message"),
         {:ok, disposition} <- parse_disposition(input) do
      {:ok,
       %{
         room: room,
         message: message,
         disposition: disposition,
         timeout_ms: resolve_timeout(disposition, input["timeout_ms"]),
         depth: normalize_depth(input["depth"])
       }}
    end
  end

  defp require_string(input, key) do
    case input[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing or empty required field: #{key}"}
    end
  end

  defp parse_disposition(input) do
    case Map.fetch(@dispositions, input["disposition"] || "") do
      {:ok, disposition} ->
        {:ok, disposition}

      :error ->
        {:error, "disposition must be one of: wait, notify, mute"}
    end
  end

  defp resolve_timeout(:wait, timeout_ms) when is_integer(timeout_ms),
    do: timeout_ms |> max(@min_timeout_ms) |> min(@max_timeout_ms)

  defp resolve_timeout(:wait, _), do: @default_timeout_ms
  defp resolve_timeout(_disposition, _timeout_ms), do: nil

  defp normalize_depth(depth) when is_integer(depth) and depth >= 0, do: depth
  defp normalize_depth(_), do: 0

  @doc "Whether a target room's saturation fraction is past the pile-on threshold."
  @spec saturated?(number() | nil, number()) :: boolean()
  def saturated?(nil, _threshold), do: false
  def saturated?(saturation, threshold), do: saturation >= threshold

  @doc """
  Route a respond against a call record.

  Returns one of:
  - `{:error, :foreign_correlation_id}` — record is not addressed to this room
  - `:deliver_to_waiter` — a `wait` caller is blocked on this correlation id
  - `:record_only` — `mute` call; record the payload, never deliver
  - `:queue_injection` — deliver as pre-turn injection on the caller's
    next turn (`notify`, or `wait` after timeout / first answer / no-reply)
  """
  @spec respond_route(map(), String.t()) ::
          :deliver_to_waiter | :record_only | :queue_injection | {:error, :foreign_correlation_id}
  def respond_route(%{target_room: target}, room) when target != room,
    do: {:error, :foreign_correlation_id}

  def respond_route(%{disposition: :mute}, _room), do: :record_only
  def respond_route(%{waiter: waiter}, _room) when not is_nil(waiter), do: :deliver_to_waiter
  def respond_route(_call, _room), do: :queue_injection

  @doc """
  The message text delivered into the receiving room.

  Arrives as a normal room message: attributed to the originating room,
  carrying the correlation id, with a note that `respond` is available.
  """
  @spec incoming_call_text(String.t(), String.t(), String.t(), disposition()) :: String.t()
  def incoming_call_text(caller_room, correlation_id, message, disposition) do
    """
    <incoming-call from_room="#{caller_room}" correlation_id="#{correlation_id}" disposition="#{disposition}">
    #{message}
    </incoming-call>

    <system-reminder>This message is a call from room "#{caller_room}". Work normally — your tool calls and reasoning stay in this room. To send a reply back to the caller, use the `respond` tool with correlation_id "#{correlation_id}"; only the respond payload crosses back. If you do not call respond before this turn ends, the caller is told no reply was designated.#{waiting_note(disposition)}</system-reminder>
    """
    |> String.trim_trailing()
  end

  defp waiting_note(:wait), do: " The caller is blocked waiting on your respond."
  defp waiting_note(_), do: ""

  @doc "Pre-turn injection content for a respond payload delivered to the caller."
  @spec injection_content(String.t(), String.t(), String.t()) :: String.t()
  def injection_content(from_room, correlation_id, payload) do
    """
    <system-reminder>Room "#{from_room}" responded to your earlier call (correlation_id: #{correlation_id}):

    <call-response from_room="#{from_room}" correlation_id="#{correlation_id}">
    #{payload}
    </call-response></system-reminder>
    """
    |> String.trim_trailing()
  end

  @doc """
  Append an injection to a room's pending list, enforcing the cap.

  Returns `{list, dropped_count}` — oldest entries drop first when full.
  """
  @spec push_injection([String.t()], String.t(), pos_integer()) ::
          {[String.t()], non_neg_integer()}
  def push_injection(pending, content, cap) do
    pending = pending ++ [content]
    overflow = length(pending) - cap

    if overflow > 0 do
      {Enum.drop(pending, overflow), overflow}
    else
      {pending, 0}
    end
  end
end
