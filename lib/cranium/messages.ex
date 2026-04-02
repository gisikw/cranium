defmodule Cranium.Messages do
  
  defmodule Segment do
    @enforce_keys [:direction, :audio, :conversation_id]
    defstruct [:direction, :audio, :conversation_id, :legacy_metadata]
  end

  defmodule Transcription do
    @enforce_keys [:conversation_id]
    defstruct [:text, :failure, :conversation_id, :legacy_metadata]
  end

end
