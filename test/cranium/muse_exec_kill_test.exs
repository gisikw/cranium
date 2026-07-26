defmodule Cranium.MuseExecKillTest do
  @moduledoc """
  Kill semantics of `Cranium.Muse.exec` on the local transport: the
  `:muse_exec_timeout_ms` deadline kills a hung muse (children included)
  and surfaces the documented error message, and `exec_kill/2` does the
  same on demand (the agent's cancel path). A fake `muse` script
  prepended to PATH hangs forever, standing in for a wedged exec.

  async: false — mutates the VM-wide PATH and cranium app env.
  """

  use ExUnit.Case, async: false

  alias Cranium.Muse

  setup_all do
    dir = Path.join(System.tmp_dir!(), "muse-hang-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    fake_muse = Path.join(dir, "muse")

    # Record the process group, spawn a grandchild, hang. `$$` is the
    # group leader pid (erts setsids port programs).
    File.write!(fake_muse, """
    #!/bin/sh
    echo $$ > "$MUSE_HANG_PIDFILE"
    sh -c 'sleep 300; echo grandchild-done' &
    sleep 300
    """)

    File.chmod!(fake_muse, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> original_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(dir)
    end)

    %{scratch: dir}
  end

  setup %{scratch: scratch} do
    pidfile = Path.join(scratch, "pgid-#{:erlang.unique_integer([:positive])}")
    System.put_env("MUSE_HANG_PIDFILE", pidfile)

    Application.put_env(:cranium, :muse_exec_timeout_ms, 400)
    Application.put_env(:cranium, :muse_exec_kill_grace_ms, 150)

    on_exit(fn ->
      System.delete_env("MUSE_HANG_PIDFILE")
      Application.delete_env(:cranium, :muse_exec_timeout_ms)
      Application.delete_env(:cranium, :muse_exec_kill_grace_ms)
    end)

    %{pidfile: pidfile}
  end

  defp await_file(path, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case File.read(path) do
      {:ok, content} when content != "" ->
        String.trim(content)

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("file #{path} never appeared")
        else
          Process.sleep(25)
          await_file(path, max(deadline - System.monotonic_time(:millisecond), 0))
        end
    end
  end

  defp assert_group_dies(pgid, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_group_dies(pgid, deadline)
  end

  defp do_assert_group_dies(pgid, deadline) do
    {out, 0} = System.cmd("ps", ["-eo", "pgid="])
    members = out |> String.split("\n", trim: true) |> Enum.count(&(String.trim(&1) == pgid))

    cond do
      members == 0 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        System.cmd("kill", ["-s", "KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
        flunk("process group #{pgid} still has survivors")

      true ->
        Process.sleep(50)
        do_assert_group_dies(pgid, deadline)
    end
  end

  test "a hung exec is killed at the configured deadline with a clear message",
       %{pidfile: pidfile} do
    started = System.monotonic_time(:millisecond)

    assert {:error, "muse exec killed: timeout after 400ms"} =
             Muse.exec("bash", %{"command" => "hang"}, nil, %{posture: :permissive})

    assert System.monotonic_time(:millisecond) - started < 5_000
    assert_group_dies(await_file(pidfile))
  end

  test "exec_kill mid-flight surfaces the cancel message and reaps the group",
       %{pidfile: pidfile} do
    Application.put_env(:cranium, :muse_exec_timeout_ms, 60_000)

    assert {:ok, pending} =
             Muse.exec_start("bash", %{"command" => "hang"}, nil, %{posture: :permissive})

    pgid = await_file(pidfile)

    assert {:error, "muse exec killed: cancelled"} = Muse.exec_kill(pending, :cancelled)
    assert_group_dies(pgid)
  end
end
