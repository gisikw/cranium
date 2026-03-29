defmodule Cranium.Backend.SSE do
  @moduledoc """
  Stateful SSE (Server-Sent Events) parser.

  Handles data arriving in arbitrary chunks — partial lines, multiple events
  in one chunk, etc. Feed it bytes via `parse/2`, get back parsed events.

  ## Usage

      state = SSE.new()
      {events, state} = SSE.parse(state, chunk1)
      {events, state} = SSE.parse(state, chunk2)

  Each event is a map with `:event` (type string) and `:data` (raw string).
  """

  use TypedStruct

  typedstruct do
    field :buffer, String.t(), default: ""
  end

  @type event :: %{event: String.t(), data: String.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Parse a chunk of SSE data. Returns `{events, updated_state}`.

  Events are complete event blocks (terminated by a blank line).
  Partial data is held in the buffer until the next chunk arrives.
  """
  @spec parse(t(), binary()) :: {[event()], t()}
  def parse(%__MODULE__{buffer: buffer} = state, chunk) do
    data = buffer <> chunk

    # SSE events are separated by double newlines
    case String.split(data, "\n\n") do
      # Only one segment means no complete event yet
      [incomplete] ->
        {[], %{state | buffer: incomplete}}

      segments ->
        # Last segment is either "" (data ended with \n\n) or incomplete
        {complete, [remaining]} = Enum.split(segments, -1)

        events =
          complete
          |> Enum.map(&parse_event/1)
          |> Enum.reject(&is_nil/1)

        {events, %{state | buffer: remaining}}
    end
  end

  defp parse_event(block) do
    lines = String.split(block, "\n")

    result =
      Enum.reduce(lines, %{event: nil, data: []}, fn line, acc ->
        cond do
          String.starts_with?(line, "event: ") ->
            %{acc | event: String.trim_leading(line, "event: ")}

          String.starts_with?(line, "data: ") ->
            %{acc | data: [String.trim_leading(line, "data: ") | acc.data]}

          # Ignore comments, empty lines, unknown fields
          true ->
            acc
        end
      end)

    case result do
      %{data: []} ->
        nil

      %{event: event_type, data: data_parts} ->
        %{
          event: event_type,
          data: data_parts |> Enum.reverse() |> Enum.join("\n")
        }
    end
  end
end
