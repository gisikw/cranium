defmodule Cranium.Backend.LLM.ClaudeCode do
  @moduledoc """
  Claude Code CLI backend.

  Runs `claude -p` as a subprocess via `Port.open/2`, streaming its
  `--output-format stream-json` output through `CCStreamParser` and
  sending tagged messages to the caller.

  ## Modes

  - **Resume mode**: When `opts[:cc_session_id]` is present, resumes an
    existing CC session. The user text is piped via stdin, system prompt
    via `--append-system-prompt-file`, and MCP markers via `--mcp-config`.

  - **One-shot mode**: When no session ID, runs a fresh disposable session.
    All messages are concatenated into a single prompt. No MCP, no resume.
    Used for Effects (handoffs, summaries).
  """

  @behaviour Cranium.Backend.LLM

  require Logger

  alias Cranium.Backend.LLM.{CCStreamParser, CCMcpServer}

  @impl true
  def manages_tool_loop?, do: true

  @impl true
  def stream_chat(messages, opts) do
    caller = self()

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        try do
          result = do_stream(caller, messages, opts)
          Logger.debug("CC backend do_stream returned: #{inspect(result)}")
          result
        rescue
          e ->
            Logger.error("CC backend crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
            send(caller, {:llm_stop, {:error, {:crash, Exception.message(e)}}})
        after
          kill_port_process_group()
          cleanup_temp_files(Process.get(:temp_files, []))
        end
      end)

    {:ok, pid}
  end

  defp do_stream(caller, messages, opts) do
    cc_session_id = Keyword.get(opts, :cc_session_id)
    system = Keyword.get(opts, :system)
    working_dir = Keyword.get(opts, :working_dir)

    {cmd, temp_files} =
      if cc_session_id do
        build_resume_cmd(messages, system, cc_session_id, opts)
      else
        build_oneshot_cmd(messages, system, opts)
      end

    Process.put(:temp_files, temp_files)

    mode = if cc_session_id, do: "resume", else: "oneshot"
    Logger.info("CC backend: mode=#{mode}",
      working_dir: working_dir,
      session_id: cc_session_id
    )

    Logger.debug("CC backend command: #{cmd}")

    # Unset ANTHROPIC_API_KEY so CC uses its subscription login instead
    # of falling through to direct API mode. Merge nix devShell env if
    # the working dir has a flake.nix (cached, ~0ms after first resolve).
    nix_env = Cranium.NixEnv.env_for(working_dir)

    env = [{~c"ANTHROPIC_API_KEY", false} | nix_env]

    port_opts = [
      :binary,
      :exit_status,
      {:args, ["-c", cmd]},
      {:env, env}
    ]

    port_opts =
      if working_dir && File.dir?(working_dir) do
        [{:cd, String.to_charlist(working_dir)} | port_opts]
      else
        Logger.warning("CC backend: working_dir missing or not a directory",
          working_dir: working_dir
        )
        port_opts
      end

    port = Port.open({:spawn_executable, sh_path()}, port_opts)

    # Track the port's OS PID for process group cleanup on cancel
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          Process.put(:port_os_pid, pid)
          pid
        _ ->
          nil
      end

    Logger.info("CC backend port opened",
      os_pid: os_pid,
      port: inspect(port)
    )

    marker_tools = CCStreamParser.default_marker_tools()
    receive_port_output(port, caller, marker_tools, "")
  end

  defp receive_port_output(port, caller, marker_tools, buffer) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data
        {lines, rest} = split_lines(buffer)

        Enum.each(lines, fn line ->
          case CCStreamParser.parse_line(line, marker_tools) do
            {:ok, messages} ->
              Enum.each(messages, fn msg -> send(caller, msg) end)

            :skip ->
              :ok
          end
        end)

        receive_port_output(port, caller, marker_tools, rest)

      {^port, {:exit_status, 0}} ->
        # Process any remaining buffer
        remaining = String.trim(buffer)

        if remaining != "" do
          Logger.debug("CC backend flushing remaining buffer (#{byte_size(remaining)} bytes)")

          case CCStreamParser.parse_line(buffer, marker_tools) do
            {:ok, messages} -> Enum.each(messages, fn msg -> send(caller, msg) end)
            :skip -> :ok
          end
        end

        Logger.info("CC backend exited cleanly (status 0)")
        :ok

      {^port, {:exit_status, status}} ->
        Logger.error("Claude Code exited with status #{status}",
          buffer_size: byte_size(buffer),
          buffer_tail: String.slice(buffer, -500, 500)
        )
        send(caller, {:llm_stop, {:error, {:exit_status, status}}})

      {:EXIT, from, reason} ->
        Logger.warning("CC backend received exit signal",
          from: inspect(from),
          from_self: from == self(),
          from_port: (match?({:EXIT, ^port, _}, {:EXIT, from, reason})),
          reason: inspect(reason),
          buffer_size: byte_size(buffer)
        )
        Port.close(port)
        :ok
    after
      300_000 ->
        Port.close(port)
        send(caller, {:llm_stop, {:error, :timeout}})
    end
  end

  defp build_resume_cmd(messages, system, session_id, opts) do
    temp_files = []

    # Write system prompt to temp file
    {system_file, temp_files} =
      if system && system != "" do
        path = write_temp_file("cranium_system_", system)
        {path, [path | temp_files]}
      else
        {nil, temp_files}
      end

    # Write MCP config
    {mcp_file, temp_files} =
      case CCMcpServer.write_config() do
        {:ok, path} -> {path, [path | temp_files]}
        {:error, _} -> {nil, temp_files}
      end

    # Extract user text from messages (last user message)
    user_text = extract_user_text(messages)

    # Build command with heredoc stdin
    args = [
      claude_path(),
      "-p",
      "--resume", session_id,
      "--output-format", "stream-json",
      "--verbose"
    ]

    args = args ++ permission_args(opts)
    args = if system_file, do: args ++ ["--append-system-prompt-file", system_file], else: args
    args = if mcp_file, do: args ++ ["--mcp-config", mcp_file], else: args

    escaped_text = escape_heredoc(user_text)
    cmd = "cat <<'CRANIUM_EOF' | #{Enum.map_join(args, " ", &shell_escape/1)}\n#{escaped_text}\nCRANIUM_EOF"

    {cmd, temp_files}
  end

  defp build_oneshot_cmd(messages, system, opts) do
    temp_files = []

    # Write system prompt to temp file
    {system_file, temp_files} =
      if system && system != "" do
        path = write_temp_file("cranium_system_", system)
        {path, [path | temp_files]}
      else
        {nil, temp_files}
      end

    # Concatenate all messages into a single prompt
    prompt = messages_to_prompt(messages)

    args = [
      claude_path(),
      "-p",
      "--output-format", "stream-json",
      "--verbose"
    ]

    args = args ++ permission_args(opts)
    args = if system_file, do: args ++ ["--append-system-prompt-file", system_file], else: args

    args =
      case Keyword.get(opts, :plugin_dir) do
        nil -> args
        dir -> args ++ ["--plugin-dir", dir]
      end

    escaped_prompt = escape_heredoc(prompt)
    cmd = "cat <<'CRANIUM_EOF' | #{Enum.map_join(args, " ", &shell_escape/1)}\n#{escaped_prompt}\nCRANIUM_EOF"

    {cmd, temp_files}
  end

  defp extract_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} when is_binary(content) -> content
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp messages_to_prompt(messages) do
    messages
    |> Enum.map(fn
      %{role: role, content: content} -> "#{role}: #{content}"
      %{"role" => role, "content" => content} -> "#{role}: #{content}"
      other when is_binary(other) -> other
    end)
    |> Enum.join("\n\n")
  end

  defp permission_args(opts) do
    if Keyword.get(opts, :bypass_permissions, true) do
      ["--permission-mode", "bypassPermissions"]
    else
      []
    end
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [single] -> {[], single}
      parts ->
        {lines, [rest]} = Enum.split(parts, -1)
        {lines, rest}
    end
  end

  defp write_temp_file(prefix, content) do
    path = Path.join(System.tmp_dir!(), prefix <> random_hex(8))
    File.write!(path, content)
    path
  end

  defp kill_port_process_group do
    case Process.get(:port_os_pid) do
      nil ->
        :ok

      os_pid ->
        # Send SIGTERM to the shell's process group. The heredoc pipe
        # (cat <<EOF | claude -p) creates children under sh; killing just
        # the shell may leave them orphaned. Negative PID targets the
        # entire process group. Any tool subprocesses CC spawned in
        # different process groups will finish naturally — that's
        # preferable to killing them mid-operation.
        System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp cleanup_temp_files(paths) do
    Enum.each(paths, fn path ->
      File.rm(path)
    end)
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end

  defp shell_escape(arg) do
    if String.contains?(arg, [" ", "'", "\"", "\\", "$", "`"]) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end

  defp escape_heredoc(text) do
    # Replace any occurrence of CRANIUM_EOF on its own line to prevent
    # premature heredoc termination
    String.replace(text, ~r/^CRANIUM_EOF$/m, "CRANIUM_EO\\F")
  end

  defp claude_path do
    Application.get_env(:cranium, :backends)[:claude_code_path] || "claude"
  end

  defp sh_path do
    System.find_executable("sh") || "/bin/sh"
  end
end
