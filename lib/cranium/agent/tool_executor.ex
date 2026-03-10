defmodule Cranium.Agent.ToolExecutor do
  @moduledoc """
  Executes real tool calls and returns results.

  This is where tool calls become side effects. The executor receives
  a tool name and input, runs the tool, and returns a result that gets
  appended to the conversation as a tool_result message.

  ## Safety

  Tool execution happens in a sandboxed context:
  - Working directory is scoped to the session's project dir
  - Execution has a configurable timeout
  - Results are truncated if they exceed a size limit

  ## Future

  This module will grow to support:
  - File read/write tools
  - Search tools (grep, glob)
  - Code execution (sandboxed)
  - External API calls
  - Skill invocation
  """

  require Logger

  @result_max_size 50_000
  @default_timeout 30_000

  @spec execute(module(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def execute(module, input, opts \\ []) do
    timeout =
      cond do
        Keyword.has_key?(opts, :timeout) -> Keyword.get(opts, :timeout)
        function_exported?(module, :timeout, 0) -> module.timeout()
        true -> @default_timeout
      end

    label = if function_exported?(module, :name, 0), do: module.name(), else: inspect(module)
    Logger.info("Executing tool: #{label}", stage: :agent)

    task =
      Task.async(fn ->
        do_execute(module, input, opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :tool_timeout}
    end
  end

  defp do_execute(module, input, opts) do
    module.execute(input, opts)
  end

  @doc false
  def truncate_result(result) when byte_size(result) > @result_max_size do
    String.slice(result, 0, @result_max_size) <> "\n... (truncated)"
  end

  def truncate_result(result), do: result
end
