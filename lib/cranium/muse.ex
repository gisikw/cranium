defmodule Cranium.Muse do
  @moduledoc """
  Bridge to the `muse` tool execution kernel.

  At boot, `load_tools!/0` shells out to `muse --tools` and caches the
  advertised tool definitions (translated into Anthropic-shape so they
  slot into the existing ToolRouter pipeline). At invocation time,
  `exec/3` shells out to `muse --exec <json>` with the session's
  working directory.

  If muse is not on PATH or returns an unexpected payload, this module
  degrades to a no-op: cranium continues to operate without muse tools.
  """

  require Logger

  @binary "muse"

  @spec load_tools!() :: :ok
  def load_tools! do
    tools =
      case run([@binary, "--read-only", "--tools"]) do
        {:ok, output} ->
          case Jason.decode(output) do
            {:ok, raw} when is_list(raw) ->
              normalize_tools(raw)

            {:ok, other} ->
              Logger.warning("muse --tools: unexpected JSON shape", shape: inspect(other))
              []

            {:error, reason} ->
              Logger.warning("muse --tools: JSON decode failed",
                reason: inspect(reason),
                output: String.slice(output, 0..200)
              )

              []
          end

        {:error, reason} ->
          Logger.warning("muse --tools: failed to run", reason: inspect(reason))
          []
      end

    Application.put_env(:cranium, :muse_tools, tools)
    Logger.info("Loaded #{length(tools)} tools from muse")
    :ok
  end

  @spec tool_definitions() :: list(map())
  def tool_definitions do
    Application.get_env(:cranium, :muse_tools, [])
  end

  @spec tool_names() :: list(String.t())
  def tool_names do
    tool_definitions() |> Enum.map(& &1.name)
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in tool_names()

  @spec exec(String.t(), map(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def exec(name, input, working_dir) do
    payload = Jason.encode!(%{tool: name, input: input})

    opts = [stderr_to_stdout: true]
    opts = if working_dir, do: Keyword.put(opts, :cd, working_dir), else: opts

    case run([@binary, "--read-only", "--exec", payload], opts) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run([cmd | args], opts \\ [stderr_to_stdout: true]) do
    case System.cmd(cmd, args, opts) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "exit=#{code}: #{String.slice(output, 0..500)}"}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp normalize_tools(raw) do
    raw
    |> Enum.map(&normalize_tool/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tool(%{"name" => name, "description" => desc, "inputSchema" => schema}) do
    %{name: name, description: desc, input_schema: schema}
  end

  defp normalize_tool(other) do
    Logger.warning("muse tool missing expected fields", tool: inspect(other))
    nil
  end
end
