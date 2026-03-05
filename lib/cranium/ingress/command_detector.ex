defmodule Cranium.Ingress.CommandDetector do
  @moduledoc """
  Detects control commands in messages.

  Commands are prefixed with `!` and control the pipeline rather than
  being sent to inference:

  - `!clear` — clear session, generate handoff
  - `!cancel` — cancel active inference
  - `!usage` — report context usage stats
  - `!new <name>` — create a new room

  If a command is detected, returns `{:command, command_type, args}`.
  Otherwise returns `{:ok, event}` and the message continues through
  the pipeline to inference.
  """

  @spec process(map(), map()) :: {:ok, map()} | {:command, atom(), map()}
  def process(%{body: "!clear"} = event, _context) do
    {:command, :clear, %{room_id: event.room_id}}
  end

  def process(%{body: "!cancel"} = event, _context) do
    {:command, :cancel, %{room_id: event.room_id}}
  end

  def process(%{body: "!usage"} = event, _context) do
    {:command, :usage, %{room_id: event.room_id}}
  end

  def process(%{body: "!new " <> name} = event, _context) do
    {:command, :new_room, %{room_id: event.room_id, name: String.trim(name)}}
  end

  def process(event, _context) do
    {:ok, normalize(event)}
  end

  defp normalize(event) do
    %{
      text: event[:body] || "",
      attachments: event[:attachments] || [],
      event_id: event.event_id,
      room_id: event.room_id,
      sender: event.sender,
      timestamp: event.timestamp
    }
  end
end
