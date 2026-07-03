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
      case run([@binary, "--tools"]) do
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

  @spec load_tools_prompt!() :: :ok
  def load_tools_prompt! do
    content =
      case run([@binary, "--tools-prompt"]) do
        {:ok, output} when output != "" ->
          Logger.info("Loaded tools prompt from muse", size: byte_size(output))
          output

        {:ok, _} ->
          nil

        {:error, reason} ->
          Logger.info("muse --tools-prompt: not available", reason: inspect(reason))
          nil
      end

    Application.put_env(:cranium, :muse_tools_prompt, content)
    :ok
  end

  @spec tools_prompt() :: String.t() | nil
  def tools_prompt do
    Application.get_env(:cranium, :muse_tools_prompt)
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

  @spec exec(String.t(), map(), String.t() | nil, map()) :: {:ok, String.t()} | {:error, term()}
  def exec(name, input, working_dir, tool_config \\ %{}) do
    payload = Jason.encode!(%{tool: name, input: input})
    posture = Map.get(tool_config, :posture, :sandbox)

    args =
      case posture do
        :permissive ->
          ["--exec", payload]

        :sandbox ->
          rw_dirs = if working_dir, do: [working_dir], else: []
          rw_dirs = rw_dirs ++ Map.get(tool_config, :rw, [])
          ro_dirs = Map.get(tool_config, :ro, [])

          grant_args =
            Enum.flat_map(rw_dirs, &["--rw", &1]) ++
              Enum.flat_map(ro_dirs, &["--ro", &1])

          grant_args ++ ["--exec", payload]
      end

    # Always cd into working_dir regardless of posture
    opts = [stderr_to_stdout: true]
    opts = if working_dir, do: Keyword.put(opts, :cd, working_dir), else: opts

    depth = Map.get(tool_config, :depth)

    opts =
      if depth, do: Keyword.put(opts, :env, [{"MUSE_ROOM_DEPTH", to_string(depth)}]), else: opts

    case run([@binary | args], opts) do
      {:ok, output} -> {:ok, unwrap_exec_output(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Unwrap muse's ExecResult wrapper (`{"output": <value>}`) so tool output
  lands top-level in the tool_result, per the cross-repo envelope
  convention (top-level `"type": "content"` discriminant). Without this,
  content envelopes stored as `{"output": {...}}` never match the
  discriminant and grotto refs are never resolved.

  String outputs are returned as-is; structured outputs are re-encoded
  as JSON. Anything that isn't an ExecResult passes through verbatim.
  """
  @spec unwrap_exec_output(String.t()) :: String.t()
  def unwrap_exec_output(output) do
    case Jason.decode(output) do
      {:ok, %{"output" => value}} when is_binary(value) -> value
      {:ok, %{"output" => value}} -> Jason.encode!(value)
      _ -> output
    end
  end

  defp run([cmd | args], opts \\ [stderr_to_stdout: true]) do
    case System.cmd(cmd, args, opts) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, exec_error(code, output)}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  # On failure muse prints an ExecResult with an "error" field and exits
  # nonzero; surface that message as plain text rather than the JSON wrapper.
  defp exec_error(code, output) do
    case Jason.decode(output) do
      {:ok, %{"error" => error}} when is_binary(error) and error != "" -> error
      _ -> "exit=#{code}: #{String.slice(output, 0..500)}"
    end
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
