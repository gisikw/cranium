defmodule Cranium.Agent.MarkerEmitter do
  @moduledoc """
  Handles SCTE-style marker tool calls.

  When the model calls tools like `show`, `show_code`, or `play_audio`,
  these are display triggers — not real operations. The MarkerEmitter:

  1. Returns fake success (`{"success": true}`) to the model so it
     continues generating naturally
  2. Emits a marker into the output stream at the exact position the
     model intended

  The model's natural sense of timing is the timing data. No post-hoc
  alignment needed.

  ## Marker Format

  Markers are maps with a `:type` and tool-specific payload:

      %{type: :marker, marker: :show, payload: %{url: "image.png"}}
      %{type: :marker, marker: :show_code, payload: %{language: "elixir", code: "..."}}
      %{type: :marker, marker: :play_audio, payload: %{url: "clip.mp3"}}

  Transports decide how to render these (inline image, code block,
  audio player, etc).
  """

  @fake_success ~s({"success": true})

  @doc """
  Handle a marker tool call.

  Returns the fake success response (to be sent back to the model as
  a tool_result) and the marker to be emitted into the output stream.
  """
  @spec handle(atom(), map()) :: {String.t(), map()}
  def handle(marker_type, input) do
    marker = %{
      type: :marker,
      marker: marker_type,
      payload: input
    }

    {@fake_success, marker}
  end
end
