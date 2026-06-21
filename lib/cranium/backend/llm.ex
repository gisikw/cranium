defmodule Cranium.Backend.LLM do
  @moduledoc """
  Behaviour for LLM inference backends.

  Implementations manage streaming chat completions. The backend spawns
  a process that sends tagged messages to the caller as SSE events arrive:

  - `{:llm_text, text}` — text content chunk
  - `{:llm_tool_use, %{id: id, name: name, input: input}}` — tool call
  - `{:llm_usage, %{input_tokens: n, output_tokens: n, ...}}` — token counts
  - `{:llm_stop, reason}` — inference complete ("end_turn", "tool_use", etc.)

  The returned pid can be monitored for crash detection.

  ## Tool Loop Management

  Some backends (e.g. Claude Code) manage their own tool execution loop
  internally. The `manages_tool_loop?/0` callback lets the Agent branch
  on this capability without referencing specific implementations.

  - `false` — Agent accumulates tool calls and re-enters inference
  - `true` — Agent receives only text and marker tool calls
  """

  @doc """
  Start a streaming chat completion.

  Returns `{:ok, pid}` where pid is a process that will send SSE events
  as tagged messages to the calling process.

  ## Options

  - `:system` — system prompt string
  - `:tools` — list of tool definitions
  - `:model` — model identifier override
  - `:router_profile` — Tiamat router profile when routing via Tiamat
  - `:max_tokens` — maximum output tokens
  """
  @callback stream_chat(messages :: list(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @doc """
  Whether this backend manages its own tool execution loop.

  When `true`, the Agent will not accumulate tool calls or re-enter
  inference — only marker tool calls will be handled inline.
  """
  @callback manages_tool_loop?() :: boolean()
end
