defmodule Cranium.Macro.Sidecar do
  @moduledoc """
  Async sidecar evaluation for macro condition learning.

  Dispatches condition evaluation to a sidecar model via a Cranium profile,
  tracks in-flight state per macro instance, and stores results
  for consumption on the next turn.

  Follows the same pattern as the agenda plugin's sidecar:
  - Non-blocking dispatch (Task.start)
  - In-flight tracking prevents overlapping evaluations
  - Results consumed on next turn's context build phase
  - Interval gating controls evaluation frequency
  """

  use GenServer
  require Logger

  @table __MODULE__

  # --- Public API ---

  @doc """
  Dispatch async sidecar evaluation for a macro's conditions.

  Guards: not already in flight, interval met, remaining conditions non-empty.
  Returns `:dispatched` or `:skipped` (with reason).
  """
  @spec dispatch(map(), String.t(), map()) :: :dispatched | {:skipped, atom()}
  def dispatch(macro, room_name, context) do
    key = {room_name, macro.name}
    in_flight = get_in_flight(key)

    macro_state = get_macro_state(macro.name, room_name)
    turns_since = turns_since_last_eval(macro_state, context.turn_count)
    interval = macro.sidecar_config.interval

    remaining = remaining_conditions(macro_state, macro.conditions)

    cond do
      in_flight ->
        {:skipped, :in_flight}

      turns_since < interval ->
        {:skipped, :interval_not_met}

      remaining == [] ->
        {:skipped, :no_remaining_conditions}

      true ->
        # Capture lookback before spawning
        lookback = fetch_lookback(context, macro_state)

        # Set in-flight BEFORE spawning task
        set_in_flight(key, true)

        # Capture values for the task closure
        sidecar_config = macro.sidecar_config
        macro_name = macro.name

        Task.start(fn ->
          result = run_eval(remaining, lookback, sidecar_config)

          case result do
            {:ok, indices} ->
              set_result(key, indices)

              Logger.info("Macro.Sidecar: completed for #{macro_name} in #{room_name}, " <>
                "completed indices: #{inspect(indices)}")

            {:error, reason} ->
              set_in_flight(key, false)

              Logger.warning("Macro.Sidecar: failed for #{macro_name} in #{room_name}: " <>
                "#{inspect(reason)}")
          end
        end)

        :dispatched
    end
  end

  @doc """
  Consume pending sidecar results for a macro.

  Returns `{:ok, completed_indices}` if results are available,
  or `:none` if no results pending. Clears the result after consumption.
  """
  @spec consume(String.t(), String.t()) :: {:ok, [integer()]} | :none
  def consume(macro_name, room_name) do
    key = {room_name, macro_name}

    case :ets.lookup(@table, key) do
      [{_, %{result: indices}}] when is_list(indices) ->
        # Clear result, mark not in flight
        :ets.insert(@table, {key, %{in_flight: false, result: nil}})
        {:ok, indices}

      _ ->
        :none
    end
  end

  @doc "Check if a sidecar evaluation is in flight for a macro."
  @spec in_flight?(String.t(), String.t()) :: boolean()
  def in_flight?(macro_name, room_name) do
    get_in_flight({room_name, macro_name})
  end

  @doc "Reset tracking state for a macro (used on deactivation/auto-close)."
  @spec reset(String.t(), String.t()) :: :ok
  def reset(macro_name, room_name) do
    :ets.delete(@table, {room_name, macro_name})
    :ok
  end

  # --- GenServer ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # --- Private: ETS operations ---

  defp get_in_flight(key) do
    case :ets.lookup(@table, key) do
      [{_, %{in_flight: true}}] -> true
      _ -> false
    end
  end

  defp set_in_flight(key, value) do
    case :ets.lookup(@table, key) do
      [{_, existing}] ->
        :ets.insert(@table, {key, %{existing | in_flight: value}})

      [] ->
        :ets.insert(@table, {key, %{in_flight: value, result: nil}})
    end
  end

  defp set_result(key, indices) do
    :ets.insert(@table, {key, %{in_flight: false, result: indices}})
  end

  # --- Private: State helpers ---

  defp get_macro_state(macro_name, room_name) do
    case Cranium.Macro.State.get_state(macro_name, room_name) do
      {:ok, state} -> state
      :error -> %{}
    end
  end

  defp turns_since_last_eval(state, current_turn) do
    last = state["last_eval_turn"] || state["activated_at_turn"] || 0
    current_turn - last
  end

  defp remaining_conditions(state, definition_conditions) do
    condition_states = state["condition_states"] || []

    definition_conditions
    |> Enum.with_index()
    |> Enum.filter(fn {_cond, idx} ->
      case Enum.find(condition_states, &(&1["index"] == idx)) do
        %{"status" => "complete"} -> false
        _ -> true
      end
    end)
    |> Enum.map(fn {cond_def, idx} ->
      cs = Enum.find(condition_states, &(&1["index"] == idx))
      status = if cs, do: cs["status"], else: "pending"
      %{index: idx, description: cond_def.description, section: cond_def[:section], status: status}
    end)
  end

  # --- Private: Lookback ---

  defp fetch_lookback(context, macro_state) do
    last_msg_count = macro_state["last_eval_message_count"] || 0

    case Cranium.Store.get_messages(context.conversation_id, epoch_id: context.epoch_id) do
      {:ok, messages} -> Enum.drop(messages, last_msg_count)
      {:error, _} -> []
    end
  end

  # --- Private: Sidecar evaluation ---

  defp run_eval(remaining, lookback_messages, sidecar_config) do
    conditions_text =
      remaining
      |> Enum.map_join("\n", fn c ->
        status_tag = if c.status == "skipped", do: " [skipped]", else: ""
        "  [#{c.index}] #{c.description}#{status_tag}"
      end)

    lookback_text =
      lookback_messages
      |> Enum.map_join("\n", fn msg ->
        role = msg[:role] || msg["role"] || "unknown"
        content = Cranium.Store.extract_text(msg[:content] || msg["content"])
        "#{role}: #{content}"
      end)

    if lookback_text == "" do
      {:ok, []}
    else
      prompt =
        sidecar_config.prompt
        |> String.replace("%{conditions}", conditions_text)
        |> String.replace("%{lookback}", lookback_text)

      profile = sidecar_config.model || "sidecar"

      case Cranium.Backend.Sidecar.chat(prompt, profile: profile, timeout: 60_000) do
        {:ok, text} ->
          parse_response(text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp parse_response(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, indices} when is_list(indices) ->
        {:ok, Enum.filter(indices, &is_integer/1)}

      {:ok, _} ->
        {:error, :unexpected_format}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end
end
