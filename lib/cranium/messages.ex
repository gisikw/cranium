defmodule Cranium.Messages do

  defmodule PassHeader do
    @moduledoc """
    Routing metadata for a pass, emitted by Transport.

    Carries everything downstream actors need to know about *how* to handle
    the pass (model, disposition, ephemeral flag) without polluting content
    messages. TurnAssembler correlates PassHeaders with content (TextInput
    or transcribed audio) by pass_id.
    """
    @enforce_keys [:pass_id, :conversation_id]
    defstruct [
      :pass_id,
      :conversation_id,
      :stream_id,
      :take_id,
      :system,
      :origin,
      :model,
      :ephemeral,
      :disposition
    ]
  end

  defmodule TextInput do
    @moduledoc "Text content for a pass, correlated to a PassHeader by pass_id."
    @enforce_keys [:pass_id, :text]
    defstruct [:pass_id, :text, :attachments]
  end

  defmodule Segment do
    @enforce_keys [:direction, :audio]
    defstruct [:direction, :audio, :take_id, :seq]
  end

  defmodule Transcription do
    defstruct [:text, :failure, :take_id, :seq]
  end

end
