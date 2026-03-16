defmodule Cranium.Backend.LLM.CCStreamParser do
  @moduledoc """
  Pure parser for Claude Code's `--output-format stream-json` output.

  Each line of CC's stream-json output is a JSON object. This module
  parses individual lines into tagged messages matching the LLM behaviour
  contract:

  - `{:llm_text, text}` — text content
  - `{:llm_tool_use, %{id, name, input}}` — MCP marker tool call
  - `{:llm_usage, map()}` — token usage
  - `{:llm_stop, reason}` — inference complete
  - `{:cc_session, session_id}` — CC session ID (first event)

  ## MCP Tool Name Demangling

  Claude Code prefixes MCP tools as `mcp__<server>__<tool>`. With our
  server named `cranium-markers`, `show` becomes `mcp__cranium-markers__show`.
  The parser strips this prefix and only emits `{:llm_tool_use, ...}` for
  recognized marker tools. Native CC tool calls are ignored.

  ## Line Types

  - `{"type":"system","subtype":"init"}` — session init, extract session_id
  - `{"type":"assistant","message":{"content":[...]}}` — content blocks
  - `{"type":"result","subtype":"success"}` — completion with usage
  - Everything else — skipped
  """

  @mcp_prefix "mcp__cranium-markers__"

  @type tagged_message ::
          {:llm_text, String.t()}
          | {:llm_tool_use, map()}
          | {:llm_usage, map()}
          | {:llm_stop, String.t()}
          | {:cc_session, String.t()}

  @doc """
  Parse a single line of stream-json output.

  Returns `{:ok, [tagged_message]}` with zero or more tagged messages,
  or `:skip` for lines that should be ignored.
  """
  @spec parse_line(String.t(), MapSet.t()) :: {:ok, [tagged_message()]} | :skip
  def parse_line(line, marker_tools \\ default_marker_tools()) do
    line = String.trim(line)

    if line == "" do
      :skip
    else
      case Jason.decode(line) do
        {:ok, parsed} -> parse_event(parsed, marker_tools)
        {:error, _} -> :skip
      end
    end
  end

  defp parse_event(%{"type" => "system", "subtype" => "init"} = event, _marker_tools) do
    case event do
      %{"session_id" => session_id} ->
        {:ok, [{:cc_session, session_id}]}

      _ ->
        :skip
    end
  end

  defp parse_event(%{"type" => "assistant", "message" => %{"content" => content}}, marker_tools)
       when is_list(content) do
    messages =
      content
      |> Enum.flat_map(fn block -> parse_content_block(block, marker_tools) end)

    if messages == [], do: :skip, else: {:ok, messages}
  end

  defp parse_event(%{"type" => "result", "subtype" => "success"} = event, _marker_tools) do
    messages = []

    messages =
      case get_in(event, ["result", "usage"]) do
        %{} = usage -> [{:llm_usage, normalize_usage(usage)} | messages]
        _ -> messages
      end

    messages = [{:llm_stop, "end_turn"} | messages]

    {:ok, Enum.reverse(messages)}
  end

  defp parse_event(%{"type" => "result", "subtype" => "error"} = event, _marker_tools) do
    error_msg = get_in(event, ["error", "message"]) || "unknown error"
    {:ok, [{:llm_stop, {:error, error_msg}}]}
  end

  defp parse_event(_event, _marker_tools), do: :skip

  defp parse_content_block(%{"type" => "text", "text" => text}, _marker_tools) do
    if text == "", do: [], else: [{:llm_text, text}]
  end

  defp parse_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}, marker_tools) do
    case demangle_mcp_name(name) do
      {:ok, tool_name} ->
        if MapSet.member?(marker_tools, tool_name) do
          [{:llm_tool_use, %{id: id, name: tool_name, input: input}}]
        else
          # MCP tool we don't recognize — skip
          []
        end

      :not_mcp ->
        # Native CC tool call — skip (CC handles these internally)
        []
    end
  end

  defp parse_content_block(_block, _marker_tools), do: []

  @doc """
  Demangle an MCP-prefixed tool name.

  Returns `{:ok, tool_name}` if the name has the cranium-markers prefix,
  or `:not_mcp` if it doesn't.
  """
  @spec demangle_mcp_name(String.t()) :: {:ok, String.t()} | :not_mcp
  def demangle_mcp_name(name) do
    case String.split(name, @mcp_prefix, parts: 2) do
      ["", tool_name] -> {:ok, tool_name}
      _ -> :not_mcp
    end
  end

  defp normalize_usage(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
      cache_read_input_tokens: usage["cache_read_input_tokens"] || 0
    }
  end

  @doc false
  def default_marker_tools do
    MapSet.new(~w(show show_code play_audio))
  end
end
