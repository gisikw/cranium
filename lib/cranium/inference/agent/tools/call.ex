defmodule Cranium.Inference.Agent.Tools.Call do
  @moduledoc """
  Send a message to another room's agent (crn-7762).

  Thin tool wrapper over `Cranium.Calls.place/2`. Disposition decides
  the shape: `wait` blocks for the receiver's respond payload, `notify`
  returns immediately with the response injected pre-turn later, `mute`
  is fire-and-forget. Replaces the deprecated `--room` dispatch
  workaround.
  """

  @behaviour Cranium.Inference.Agent.Tool

  require Logger

  @impl true
  def execute(input, opts) do
    case Keyword.get(opts, :conversation_id) do
      nil ->
        {:ok, encode_error("call unavailable: no originating room in tool context")}

      caller_room ->
        input = Map.put(input, "depth", Keyword.get(opts, :depth))

        Logger.info("Call tool: #{input["disposition"]} -> #{input["room"]}",
          conversation_id: caller_room
        )

        case place(caller_room, input) do
          {:ok, result} -> {:ok, Jason.encode!(result)}
          {:error, reason} -> {:ok, encode_error(reason)}
        end
    end
  end

  # The Calls exchange replies via its internal timer for wait calls, so
  # :infinity here is safe; catch exit so a dead exchange surfaces as a
  # tool error instead of killing the executor task.
  defp place(caller_room, input) do
    Cranium.Calls.place(caller_room, input)
  catch
    :exit, reason -> {:error, "call exchange unavailable: #{inspect(reason)}"}
  end

  defp encode_error(reason), do: Jason.encode!(%{error: to_string(reason)})

  @impl true
  def name, do: "call"

  # ToolExecutor backstop only — the real wait timer lives in Cranium.Calls
  # and is clamped to Logic.max_timeout_ms.
  @spec timeout() :: pos_integer()
  def timeout, do: Cranium.Calls.Logic.max_timeout_ms() + 15_000

  @impl true
  def schema do
    %{
      name: "call",
      description:
        "Send a message to another room's agent. The receiving agent works in its own " <>
          "room and uses its `respond` tool to designate what crosses back — you never " <>
          "receive its full turn output. Disposition decides the shape: `wait` blocks " <>
          "until the receiver responds or its turn ends (no respond => " <>
          "no_reply_designated; timeout => timed_out, with any eventual response " <>
          "injected before a later turn); `notify` returns immediately and the response " <>
          "arrives as pre-turn context on your next turn, tagged with the correlation " <>
          "id; `mute` is fire-and-forget (a response is recorded but never delivered — " <>
          "use when you cannot afford a reply, e.g. near context exhaustion). Calls to " <>
          "a critically saturated room return receiver_saturated without delivering.",
      input_schema: %{
        type: "object",
        properties: %{
          room: %{
            type: "string",
            description: "Target room (conversation) name. Must be an existing room."
          },
          message: %{
            type: "string",
            description:
              "What the receiving agent sees. Be specific — include the context it " <>
                "needs and what kind of respond payload you want back."
          },
          disposition: %{
            type: "string",
            enum: ["wait", "notify", "mute"],
            description: "wait = block for the respond; notify = async; mute = fire-and-forget."
          },
          timeout_ms: %{
            type: "integer",
            description:
              "wait only — how long to block before degrading to notify semantics. " <>
                "Default 600000 (10 min), max 1800000 (30 min)."
          }
        },
        required: ["room", "message", "disposition"]
      }
    }
  end
end
