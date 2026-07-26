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

  alias Cranium.Muse.Exec

  @binary "muse"

  # Outer bound on a local exec. Muse's own bash timeout defaults to
  # 600_000ms; keeping the port deadline above it means muse's in-band
  # timeout fires first in the normal case and this is the backstop for a
  # muse that is itself wedged.
  @default_exec_timeout_ms 660_000
  @default_exec_kill_grace_ms 500

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
    case exec_start(name, input, working_dir, tool_config) do
      {:ok, pending} -> exec_await(pending)
      {:error, _} = error -> error
    end
  end

  @doc """
  Start an exec without blocking. Returns `{:ok, pending}`; the raw result
  arrives as a `{:muse_exec_result, pending.ref, raw}` message, consumed by
  `exec_await/1` — or by `exec_kill/2` when the caller decides mid-flight
  (cancel) that the exec must die instead. Both map the raw result to the
  same `{:ok, output} | {:error, message}` envelope as `exec/4`.

  Local execs run under `Cranium.Muse.Exec` with a deadline
  (`:muse_exec_timeout_ms`, default #{@default_exec_timeout_ms}ms — just
  above muse's own 600s bash default, so muse's timeout fires first and
  ours is the backstop) and process-group kill semantics. Remote execs run
  the HTTP call in a killable process; the deadline there is the
  endpoint's own `timeout_ms` (see `Cranium.Muse.HTTP`), and kill merely
  abandons the request — the process lives on the remote host.
  """
  @spec exec_start(String.t(), map(), String.t() | nil, map()) ::
          {:ok, Exec.t()} | {:error, term()}
  def exec_start(name, input, working_dir, tool_config \\ %{}) do
    request = build_exec_request(name, input, working_dir, tool_config)

    case Map.get(tool_config, :exec_endpoint) do
      nil -> exec_local_start(request)
      endpoint -> exec_remote_start(endpoint, request)
    end
  end

  @spec exec_await(Exec.t()) :: {:ok, String.t()} | {:error, term()}
  def exec_await(pending) do
    pending |> Exec.await() |> map_exec_result()
  end

  @spec exec_kill(Exec.t(), term()) :: {:ok, String.t()} | {:error, term()}
  def exec_kill(pending, reason) do
    pending |> Exec.kill(reason) |> map_exec_result()
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

  defp exec_local_start(request) do
    grant_args =
      Enum.flat_map(request.rw, &["--rw", &1]) ++
        Enum.flat_map(request.ro, &["--ro", &1])

    args = grant_args ++ ["--exec", Jason.encode!(%{tool: request.tool, input: request.input})]

    # Always cd into working_dir regardless of posture
    opts = [timeout_ms: exec_timeout_ms(), kill_grace_ms: exec_kill_grace_ms()]
    opts = if request.working_dir, do: Keyword.put(opts, :cd, request.working_dir), else: opts
    opts = if request.env == [], do: opts, else: Keyword.put(opts, :env, request.env)

    Exec.start([@binary | args], opts)
  end

  # The endpoint's response body is what `--exec` prints on stdout plus an
  # exit_code field, so success and failure route through the exact same
  # unwrap/error paths as the local transport (HTTP.exec returns the same
  # {:ok, body, exit_code} shape the port runner produces).
  defp exec_remote_start(endpoint, request) do
    Exec.start_fun(fn -> Cranium.Muse.HTTP.exec(endpoint, request) end)
  end

  defp map_exec_result({:ok, output, 0}), do: {:ok, unwrap_exec_output(output)}
  defp map_exec_result({:ok, output, code}), do: {:error, exec_error(code, output)}

  defp map_exec_result({:error, {:timeout, timeout_ms}}),
    do: {:error, "muse exec killed: timeout after #{timeout_ms}ms"}

  defp map_exec_result({:error, {:killed, reason}}),
    do: {:error, "muse exec killed: #{reason}"}

  defp map_exec_result({:error, reason}), do: {:error, reason}

  defp exec_timeout_ms,
    do: Application.get_env(:cranium, :muse_exec_timeout_ms, @default_exec_timeout_ms)

  defp exec_kill_grace_ms,
    do: Application.get_env(:cranium, :muse_exec_kill_grace_ms, @default_exec_kill_grace_ms)

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
