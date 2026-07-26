defmodule Cranium.Muse.Exec do
  @moduledoc """
  Killable runner for muse invocations.

  `System.cmd/3` is synchronous and unbounded: no deadline, no kill path.
  A muse exec that hangs (network, interactive prompt, runaway child)
  blocks its caller forever and leaves the OS process tree running. This
  module replaces it for exec-time invocations with a port-based runner
  that adds:

  - **Deadline** — every exec gets a `:timeout_ms`; on expiry the process
    tree is killed and the caller gets `{:error, {:timeout, ms}}`.
  - **Kill semantics** — the erts port machinery starts port programs in
    their own session (`setsid()`), so the spawned binary is its own
    process-group leader and a negative-pid `kill(1)` reaps the entire
    tree, grandchildren included. Kill escalates SIGTERM → `:kill_grace_ms`
    → SIGKILL. Do not wrap the binary in util-linux `setsid`: the child is
    already a group leader, so `setsid` would fork and make the group id
    untrackable from the port's os_pid.
  - **Caller lifetime coupling** — the runner monitors the caller; if the
    caller dies mid-exec (e.g. an async tool task is brutally killed on
    cancel), the runner kills the process tree before exiting. Nothing
    survives its caller.
  - **Cancellable await** — `start/2` returns a handle whose result
    arrives as a `{:muse_exec_result, ref, raw}` message, so a caller can
    wait in a selective receive that also matches its own cancel signal
    and then `kill/2` the exec promptly instead of awaiting it.

  Raw results (mapped to the exec envelope by `Cranium.Muse`):
  `{:ok, output, exit_status}`, `{:error, {:timeout, ms}}`,
  `{:error, {:killed, reason}}`, or `{:error, message}` for spawn
  failures. `start_fun/1` runs an arbitrary function (the remote HTTP
  transport) under the same handle/message contract; its kill is a brutal
  process kill since there is no local OS process to reap.
  """

  require Logger

  use TypedStruct

  typedstruct do
    field :kind, :port | :fun
    field :pid, pid()
    field :monitor, reference()
    field :ref, reference()
  end

  @default_timeout_ms 660_000
  @default_kill_grace_ms 500

  @doc "Blocking convenience: `start/2` + `await/1`."
  @spec run([String.t()], keyword()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def run(argv, opts \\ []) do
    case start(argv, opts) do
      {:ok, exec} -> await(exec)
      {:error, _} = error -> error
    end
  end

  @doc """
  Spawn `argv` under a monitored runner process. Options: `:cd`, `:env`
  (list of `{name, value}` strings), `:timeout_ms`, `:kill_grace_ms`.
  """
  @spec start([String.t()], keyword()) :: {:ok, t()} | {:error, String.t()}
  def start([cmd | args], opts \\ []) do
    case System.find_executable(cmd) do
      nil ->
        {:error, "executable not found: #{cmd}"}

      path ->
        caller = self()
        ref = make_ref()
        pid = spawn(fn -> run_port(caller, ref, path, args, opts) end)
        {:ok, %__MODULE__{kind: :port, pid: pid, monitor: Process.monitor(pid), ref: ref}}
    end
  end

  @doc """
  Run `fun` in a spawned process under the same handle/message contract as
  `start/2`. The runner is linked to the caller so caller death tears the
  work down; `fun` exceptions are caught and returned as `{:error, message}`,
  so the link only ever propagates caller-side exits.
  """
  @spec start_fun((-> term())) :: {:ok, t()}
  def start_fun(fun) when is_function(fun, 0) do
    caller = self()
    ref = make_ref()
    # Propagate the caller chain (as Task does) so process-owned test
    # stubs — e.g. Req.Test plugs on the HTTP transport — resolve here.
    callers = [caller | Process.get(:"$callers", [])]

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", callers)

        result =
          try do
            fun.()
          rescue
            e -> {:error, Exception.message(e)}
          catch
            kind, reason -> {:error, "muse exec runner #{kind}: #{inspect(reason)}"}
          end

        send(caller, {:muse_exec_result, ref, result})
      end)

    {:ok, %__MODULE__{kind: :fun, pid: pid, monitor: Process.monitor(pid), ref: ref}}
  end

  @doc "Block until the exec finishes and return its raw result."
  @spec await(t()) :: term()
  def await(%__MODULE__{ref: ref, monitor: monitor} = exec) do
    receive do
      {:muse_exec_result, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        maybe_unlink(exec)
        result

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, "muse exec runner exited: #{inspect(reason)}"}
    end
  end

  @doc """
  Kill an in-flight exec and consume its result message. Port execs get the
  SIGTERM → grace → SIGKILL group-kill; fun execs are brutally killed
  (unlinked first so the exit does not cascade to the caller). Returns the
  terminal raw result — `{:error, {:killed, reason}}`, or the real result
  if the exec finished before the kill landed.
  """
  @spec kill(t(), term()) :: term()
  def kill(exec, reason \\ :killed)

  def kill(%__MODULE__{kind: :port} = exec, reason) do
    send(exec.pid, {:kill, reason})
    await(exec)
  end

  def kill(%__MODULE__{kind: :fun, ref: ref, monitor: monitor} = exec, reason) do
    Process.unlink(exec.pid)
    Process.exit(exec.pid, :kill)

    receive do
      {:muse_exec_result, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, _down_reason} ->
        {:error, {:killed, reason}}
    end
  end

  defp maybe_unlink(%__MODULE__{kind: :fun, pid: pid}), do: Process.unlink(pid)
  defp maybe_unlink(_), do: true

  # --- Port runner process ---

  defp run_port(caller, ref, path, args, opts) do
    caller_monitor = Process.monitor(caller)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    kill_grace_ms = Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms)

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]
      |> maybe_put_opt(:cd, opts[:cd])
      |> maybe_put_opt(:env, port_env(opts[:env]))

    case open_port(path, port_opts) do
      {:ok, port} ->
        ctx = %{
          caller: caller,
          ref: ref,
          caller_monitor: caller_monitor,
          port: port,
          os_pid: port_os_pid(port),
          timeout_ms: timeout_ms,
          kill_grace_ms: kill_grace_ms
        }

        Process.send_after(self(), :deadline, timeout_ms)
        collect(ctx, [])

      {:error, message} ->
        send(caller, {:muse_exec_result, ref, {:error, message}})
    end
  end

  defp open_port(path, port_opts) do
    {:ok, Port.open({:spawn_executable, path}, port_opts)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  defp collect(ctx, acc) do
    %{port: port, caller_monitor: caller_monitor} = ctx

    receive do
      {^port, {:data, data}} ->
        collect(ctx, [data | acc])

      {^port, {:exit_status, status}} ->
        reply(ctx, {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), status})

      :deadline ->
        kill_tree(ctx)
        reply(ctx, {:error, {:timeout, ctx.timeout_ms}})

      {:kill, reason} ->
        kill_tree(ctx)
        reply(ctx, {:error, {:killed, reason}})

      {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
        # Caller is gone (e.g. async tool task killed on cancel) — nobody
        # to reply to, but the OS process tree must still die.
        kill_tree(ctx)
    end
  end

  defp reply(ctx, result) do
    send(ctx.caller, {:muse_exec_result, ctx.ref, result})
  end

  defp kill_tree(%{os_pid: nil} = ctx), do: close_port(ctx.port)

  defp kill_tree(ctx) do
    signal_group(ctx.os_pid, "TERM")

    unless reaped?(ctx.port, ctx.kill_grace_ms) do
      signal_group(ctx.os_pid, "KILL")
      reaped?(ctx.port, ctx.kill_grace_ms) || close_port(ctx.port)
    end
  end

  # Wait for the port's exit_status, discarding trailing output. The
  # deadline is absolute so data spam from a dying child can't extend it.
  defp reaped?(port, grace_ms) do
    wait_exit(port, System.monotonic_time(:millisecond) + grace_ms)
  end

  defp wait_exit(port, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _status}} -> true
      {^port, {:data, _data}} -> wait_exit(port, deadline)
    after
      timeout -> false
    end
  end

  # A negative pid signals the whole process group (the port child is its
  # own group leader — see moduledoc). Fall back to the direct pid if the
  # group signal fails.
  defp signal_group(os_pid, signal) do
    case System.cmd("kill", ["-s", signal, "--", "-#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> System.cmd("kill", ["-s", signal, to_string(os_pid)], stderr_to_stdout: true)
    end
  rescue
    e ->
      Logger.warning("muse exec: kill(1) unavailable, process tree may survive",
        os_pid: os_pid,
        error: Exception.message(e)
      )

      :ok
  end

  defp close_port(port) do
    Port.close(port)
    true
  rescue
    ArgumentError -> true
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: opts ++ [{key, value}]

  defp port_env(nil), do: nil
  defp port_env([]), do: nil

  defp port_env(env) do
    Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
  end
end
