defmodule Cranium.Inference.Agent.Tools.Respond do
  @moduledoc """
  Designate the reply payload for an incoming call (crn-7762).

  Receiver-side subset selection: the turn runs normally — tool calls,
  scratch work, everything — and `respond` marks which part is the
  actual payload for the caller. Nothing else crosses the wire.
  """

  @behaviour Cranium.Inference.Agent.Tool

  require Logger

  @impl true
  def execute(input, opts) do
    room = Keyword.get(opts, :conversation_id)
    correlation_id = input["correlation_id"]
    payload = input["payload"]

    cond do
      is_nil(room) ->
        {:ok, encode_error("respond unavailable: no room in tool context")}

      not (is_binary(correlation_id) and correlation_id != "") ->
        {:ok, encode_error("missing or empty required field: correlation_id")}

      not (is_binary(payload) and payload != "") ->
        {:ok, encode_error("missing or empty required field: payload")}

      true ->
        Logger.info("Respond tool: #{correlation_id}", conversation_id: room)

        case respond(room, correlation_id, payload) do
          {:ok, delivery} ->
            {:ok, Jason.encode!(%{status: delivery, correlation_id: correlation_id})}

          {:error, :unknown_correlation_id} ->
            {:ok, encode_error("unknown correlation_id: #{correlation_id}")}

          {:error, :foreign_correlation_id} ->
            {:ok, encode_error("correlation_id #{correlation_id} is not addressed to this room")}

          {:error, reason} ->
            {:ok, encode_error(inspect(reason))}
        end
    end
  end

  defp respond(room, correlation_id, payload) do
    Cranium.Calls.respond(room, correlation_id, payload)
  catch
    :exit, reason -> {:error, "call exchange unavailable: #{inspect(reason)}"}
  end

  defp encode_error(reason), do: Jason.encode!(%{error: to_string(reason)})

  @impl true
  def name, do: "respond"

  @impl true
  def schema do
    %{
      name: "respond",
      description:
        "Designate the reply payload for an incoming call (see <incoming-call> blocks " <>
          "in this room). Only the payload crosses back to the calling room — your " <>
          "other output, tool calls, and reasoning stay here. Multiple responds with " <>
          "the same correlation_id append and are delivered in order. Only valid for " <>
          "correlation ids addressed to this room.",
      input_schema: %{
        type: "object",
        properties: %{
          correlation_id: %{
            type: "string",
            description: "The correlation_id of the incoming call this answers."
          },
          payload: %{
            type: "string",
            description: "What the caller receives. Nothing else crosses the wire."
          }
        },
        required: ["correlation_id", "payload"]
      }
    }
  end
end
