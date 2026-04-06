defmodule Cranium.Inference.Agent.Tool do
  @moduledoc """
  Behaviour for tool modules.

  Tools implement `execute/2` which receives the tool input and options,
  and returns a result string or error. Optionally implement `name/0`
  for human-readable logging.
  """

  @callback execute(input :: map(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback name() :: String.t()
  @callback schema() :: map()
  @optional_callbacks [name: 0]
end
