defmodule Cranium.Muse.ExecTest do
  @moduledoc """
  Unit tests for the killable exec runner: normal exits, deadline kill,
  explicit kill, SIGTERM→SIGKILL escalation, caller-death cleanup — and,
  for every kill path, death of the whole process group (child of child
  included), asserted via a pgid sweep of the process table.

  The scripts write `$$` (the port child's pid, which erts makes a
  process-group leader) to a file so the test can identify the group
  before it is killed.
  """

  use ExUnit.Case, async: true

  alias Cranium.Muse.Exec

  @moduletag :tmp_dir

  # --- helpers ---

  defp pid_file(tmp_dir), do: Path.join(tmp_dir, "pgid-#{System.unique_integer([:positive])}")

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

  defp group_members(pgid) do
    {out, 0} = System.cmd("ps", ["-eo", "pgid="])

    out
    |> String.split("\n", trim: true)
    |> Enum.count(&(String.trim(&1) == pgid))
  end

  defp assert_group_dies(pgid, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_group_dies(pgid, deadline)
  end

  defp do_assert_group_dies(pgid, deadline) do
    cond do
      group_members(pgid) == 0 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        System.cmd("kill", ["-s", "KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
        flunk("process group #{pgid} still has survivors")

      true ->
        Process.sleep(50)
        do_assert_group_dies(pgid, deadline)
    end
  end

  defp wait_until_dead(pid, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_dead(pid, deadline)
  end

  defp do_wait_until_dead(pid, deadline) do
    cond do
      not Process.alive?(pid) -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("#{inspect(pid)} still alive")
      true -> Process.sleep(25) && do_wait_until_dead(pid, deadline)
    end
  end

  # Script that records its pgid, spawns a grandchild (sh -> sleep, so the
  # sleep is a child of a child of the port program), then blocks.
  defp hang_script(pid_file) do
    """
    echo $$ > #{pid_file}
    sh -c 'sleep 300; echo grandchild-done' &
    sleep 300
    """
  end

  # --- normal exits ---

  test "captures stdout and exit status 0" do
    assert {:ok, "hello\n", 0} = Exec.run(["/bin/sh", "-c", "echo hello"])
  end

  test "captures stderr interleaved and nonzero exit status" do
    assert {:ok, output, 7} = Exec.run(["/bin/sh", "-c", "echo oops >&2; exit 7"])
    assert output =~ "oops"
  end

  test "missing executable is an error, not a raise" do
    assert {:error, "executable not found: " <> _} = Exec.run(["definitely-not-a-binary-xyz"])
  end

  test "cd and env options are applied", %{tmp_dir: tmp_dir} do
    assert {:ok, output, 0} =
             Exec.run(["/bin/sh", "-c", "pwd; printf %s $MUSE_EXEC_TEST_VAR"],
               cd: tmp_dir,
               env: [{"MUSE_EXEC_TEST_VAR", "present"}]
             )

    assert output == "#{Path.expand(tmp_dir)}\npresent"
  end

  test "await finds a result re-queued behind the runner's DOWN (agent cancellable pattern)" do
    # Regression: the agent's cancellable receive consumes the result and
    # re-queues it before calling await, putting it BEHIND the runner's
    # DOWN in the mailbox. await must drain for the result on DOWN instead
    # of trusting mailbox order. Live failure Sun Jul 26: every sync tool
    # call returned "muse exec runner exited: :normal".
    {:ok, exec} = Exec.start(["/bin/sh", "-c", "echo hello"])
    %{ref: ref, monitor: monitor} = exec

    result_msg =
      receive do
        {:muse_exec_result, ^ref, _} = msg -> msg
      after
        5_000 -> flunk("runner never sent its result")
      end

    # Wait for the DOWN, put it back, THEN re-queue the result behind it.
    receive do
      {:DOWN, ^monitor, :process, _, _} = down -> send(self(), down)
    after
      5_000 -> flunk("runner never went down")
    end

    send(self(), result_msg)

    assert {:ok, "hello\n", 0} = Exec.await(exec)
  end

  # --- deadline ---

  test "timeout kills the whole process group, grandchild included", %{tmp_dir: tmp_dir} do
    pid_file = pid_file(tmp_dir)

    {:ok, exec} =
      Exec.start(["/bin/sh", "-c", hang_script(pid_file)], timeout_ms: 400, kill_grace_ms: 200)

    pgid = await_file(pid_file)
    assert group_members(pgid) >= 1

    started = System.monotonic_time(:millisecond)
    assert {:error, {:timeout, 400}} = Exec.await(exec)
    assert System.monotonic_time(:millisecond) - started < 5_000

    assert_group_dies(pgid)
  end

  test "a TERM-immune child is escalated to SIGKILL", %{tmp_dir: tmp_dir} do
    pid_file = pid_file(tmp_dir)
    script = "trap '' TERM; echo $$ > #{pid_file}; while :; do sleep 1; done"

    {:ok, exec} = Exec.start(["/bin/sh", "-c", script], timeout_ms: 300, kill_grace_ms: 150)

    pgid = await_file(pid_file)
    assert {:error, {:timeout, 300}} = Exec.await(exec)
    assert_group_dies(pgid)
  end

  # --- explicit kill (cancel path) ---

  test "kill/2 mid-exec returns the kill reason and reaps the group", %{tmp_dir: tmp_dir} do
    pid_file = pid_file(tmp_dir)

    {:ok, exec} =
      Exec.start(["/bin/sh", "-c", hang_script(pid_file)], timeout_ms: 60_000, kill_grace_ms: 200)

    pgid = await_file(pid_file)

    assert {:error, {:killed, :cancelled}} = Exec.kill(exec, :cancelled)
    assert_group_dies(pgid)
  end

  test "kill/2 racing normal completion returns the real result" do
    {:ok, exec} = Exec.start(["/bin/sh", "-c", "echo done"])
    wait_until_dead(exec.pid)
    assert {:ok, "done\n", 0} = Exec.kill(exec, :cancelled)
  end

  # --- caller lifetime coupling (async task cancel path) ---

  test "caller death kills the group", %{tmp_dir: tmp_dir} do
    pid_file = pid_file(tmp_dir)
    test = self()

    caller =
      spawn(fn ->
        {:ok, exec} = Exec.start(["/bin/sh", "-c", hang_script(pid_file)], timeout_ms: 60_000)
        send(test, {:started, exec})
        Exec.await(exec)
      end)

    assert_receive {:started, _exec}, 5_000
    pgid = await_file(pid_file)
    assert group_members(pgid) >= 1

    Process.exit(caller, :kill)
    assert_group_dies(pgid)
  end

  # --- fun runner (remote transport shape) ---

  test "start_fun returns the fun's value through the same contract" do
    {:ok, exec} = Exec.start_fun(fn -> {:ok, "body", 0} end)
    assert {:ok, "body", 0} = Exec.await(exec)
  end

  test "start_fun exceptions become error results, not caller crashes" do
    {:ok, exec} = Exec.start_fun(fn -> raise "boom" end)
    assert {:error, "boom"} = Exec.await(exec)
  end

  test "kill/2 on a fun exec abandons it without killing the caller" do
    test = self()

    {:ok, exec} =
      Exec.start_fun(fn ->
        send(test, :fun_running)
        Process.sleep(60_000)
      end)

    assert_receive :fun_running, 5_000
    assert {:error, {:killed, :cancelled}} = Exec.kill(exec, :cancelled)
    refute Process.alive?(exec.pid)
  end
end
