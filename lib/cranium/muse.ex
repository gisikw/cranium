defmodule Cranium.Muse do
  @moduledoc """
  Bridge to the `muse` tool execution kernel.

  At boot, `load_tools!/0` shells out to `muse --tools` and caches the
  advertised tool definitions (translated into Anthropic-shape so they
  slot into the existing ToolRouter pipeline). At invocation time,
  `exec/4` shells out to `muse --exec <json>` with the session's
  working directory — or, when the profile configures an exec endpoint,
  POSTs the same fields to a remote `muse serve` daemon
  (see `Cranium.Muse.HTTP`). Tool definitions are flat and identical
  across hosts, so they are always loaded from the local binary.

  If muse is not on PATH or returns an unexpected payload, this module
  degrades to a no-op: cranium continues to operate without muse tools.
  """

  require Logger

  @binary "muse"

  # Muse tools advertised by the binary but suppressed in cranium. `delegate`
  # requires a Cranium-side model registry that doesn't exist yet; advertising
  # it just invites agents to call a tool that cannot succeed.
  @suppressed_tools ["delegate"]

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
    request = build_exec_request(name, input, working_dir, tool_config)

    case Map.get(tool_config, :exec_endpoint) do
      nil -> exec_local(request)
      endpoint -> exec_remote(endpoint, request)
    end
  end

  @doc false
  # One request shape for both transports, carrying tool/input structurally.
  # Each transport serializes at its own boundary: the local path encodes the
  # {tool, input} payload onto `--exec` argv; the HTTP path sends the fields on
  # the wire for `muse serve` to rebuild. Nothing is pre-serialized into the
  # shared struct, so the two transports cannot silently drift in payload shape.
  def build_exec_request(name, input, working_dir, tool_config) do

    {rw_dirs, ro_dirs} =
      case Map.get(tool_config, :posture, :sandbox) do
        :permissive ->
          {[], []}

        :sandbox ->
          rw_dirs = if working_dir, do: [working_dir], else: []
          {rw_dirs ++ Map.get(tool_config, :rw, []), Map.get(tool_config, :ro, [])}
      end

    env =
      case Map.get(tool_config, :depth) do
        nil -> []
        depth -> [{"MUSE_ROOM_DEPTH", to_string(depth)}]
      end

    %{tool: name, input: input, working_dir: working_dir, rw: rw_dirs, ro: ro_dirs, env: env}
  end

  defp exec_local(request) do
    grant_args =
      Enum.flat_map(request.rw, &["--rw", &1]) ++
        Enum.flat_map(request.ro, &["--ro", &1])

    args = grant_args ++ ["--exec", Jason.encode!(%{tool: request.tool, input: request.input})]

    # Always cd into working_dir regardless of posture
    opts = [stderr_to_stdout: true]
    opts = if request.working_dir, do: Keyword.put(opts, :cd, request.working_dir), else: opts
    opts = if request.env == [], do: opts, else: Keyword.put(opts, :env, request.env)

    case run([@binary | args], opts) do
      {:ok, output} -> {:ok, unwrap_exec_output(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The endpoint's response body is what `--exec` prints on stdout plus an
  # exit_code field, so success and failure route through the exact same
  # unwrap/error paths as the local transport.
  defp exec_remote(endpoint, request) do
    case Cranium.Muse.HTTP.exec(endpoint, request) do
      {:ok, body, 0} -> {:ok, unwrap_exec_output(body)}
      {:ok, body, code} -> {:error, exec_error(code, body)}
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
    |> Enum.reject(&(&1.name in @suppressed_tools))
  end

  defp normalize_tool(%{"name" => name, "description" => desc, "inputSchema" => schema}) do
    %{name: name, description: desc, input_schema: schema}
  end

  defp normalize_tool(other) do
    Logger.warning("muse tool missing expected fields", tool: inspect(other))
    nil
  end
end
