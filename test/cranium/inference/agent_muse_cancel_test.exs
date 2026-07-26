defmodule Cranium.Inference.AgentMuseCancelTest do
  @moduledoc """
  End-to-end cancel semantics for in-flight muse execs, through the Agent.

  A fake `muse` on PATH hangs forever (recording its process group), a
  mocked LLM issues a tool call routed to it, and the test cancels the
  agent mid-exec. Both execution paths are covered:

  - sync: the agent process itself awaits the exec — the cancel cast must
    interrupt that wait, kill the muse process group, and still land the
    kill message in the turn's tool_result (cancelled-turn persistence).
  - async (`cranium_async_mode: single_pass`): cancel_async_tasks kills
    the task process — the exec runner must notice and reap the group.

  async: false — mutates the VM-wide PATH, app env, and global Mox.
  """

  use CraniumTest.DataCase, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup_all do
    dir = Path.join(System.tmp_dir!(), "muse-agent-hang-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    fake_muse = Path.join(dir, "muse")

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
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)

    pidfile = Path.join(scratch, "pgid-#{:erlang.unique_integer([:positive])}")
    System.put_env("MUSE_HANG_PIDFILE", pidfile)

    tools_before = Application.get_env(:cranium, :muse_tools, [])

    Application.put_env(:cranium, :muse_tools, [
      %{name: "hang", description: "hangs forever", input_schema: %{"type" => "object"}}
    ])

    Application.put_env(:cranium, :muse_exec_timeout_ms, 60_000)
    Application.put_env(:cranium, :muse_exec_kill_grace_ms, 150)

    on_exit(fn ->
      System.delete_env("MUSE_HANG_PIDFILE")
      Application.put_env(:cranium, :muse_tools, tools_before)
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
          flunk("file #{path} never appeared — muse exec never started")
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

  defp start_agent do
    {:ok, pid} = Cranium.Inference.Agent.start_link(conversation_id: "test-agent-muse-cancel")
    pid
  end

  test "cancel mid sync muse exec kills the process group and preserves the turn",
       %{pidfile: pidfile} do
    Cranium.Backend.LLM.Mock
    |> expect(:stream_chat, fn _messages, _opts ->
      caller = self()

      pid =
        spawn(fn ->
          send(caller, {:llm_text, "Running the tool"})
          send(caller, {:llm_tool_use, %{id: "tc_hang", name: "hang", input: %{}}})
          send(caller, {:llm_stop, "tool_use"})
        end)

      {:ok, pid}
    end)
    # Tool execution finishes (killed) before the queued cancel is seen, so
    # the loop re-enters inference once; the cancel lands in that pass.
    |> expect(:stream_chat, fn _messages, _opts ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, pid}
    end)

    agent = start_agent()
    context = %{messages: [%{role: "user", content: "go"}], stream_id: "s-muse-sync-cancel"}
    task = Task.async(fn -> Cranium.Inference.Agent.infer(agent, context) end)

    pgid = await_file(pidfile)
    cancelled_at = System.monotonic_time(:millisecond)
    GenServer.cast(agent, :cancel)

    assert {:error, :cancelled, partial} = Task.await(task, 10_000)
    assert System.monotonic_time(:millisecond) - cancelled_at < 5_000

    assert_group_dies(pgid)

    # The killed exec's tool_result made it into the persisted turn.
    assert Enum.any?(partial.intermediate_messages, fn
             %{role: "user", content: [%{type: "tool_result", content: content}]} ->
               content =~ "muse exec killed: cancelled"

             _ ->
               false
           end)
  end

  test "cancel mid async muse exec kills the task's process group",
       %{pidfile: pidfile} do
    Cranium.Backend.LLM.Mock
    |> expect(:stream_chat, fn _messages, _opts ->
      caller = self()

      pid =
        spawn(fn ->
          send(
            caller,
            {:llm_tool_use,
             %{id: "tc_hang", name: "hang", input: %{"cranium_async_mode" => "single_pass"}}}
          )

          send(caller, {:llm_stop, "tool_use"})
        end)

      {:ok, pid}
    end)
    # The async ack re-enters inference immediately; this pass ends the
    # turn so the agent parks in wait_for_async_then_continue.
    |> expect(:stream_chat, fn _messages, _opts ->
      caller = self()
      pid = spawn(fn -> send(caller, {:llm_stop, "end_turn"}) end)
      {:ok, pid}
    end)

    agent = start_agent()
    context = %{messages: [%{role: "user", content: "go"}], stream_id: "s-muse-async-cancel"}
    task = Task.async(fn -> Cranium.Inference.Agent.infer(agent, context) end)

    pgid = await_file(pidfile)
    cancelled_at = System.monotonic_time(:millisecond)
    GenServer.cast(agent, :cancel)

    assert {:error, :cancelled, _partial} = Task.await(task, 10_000)
    assert System.monotonic_time(:millisecond) - cancelled_at < 5_000

    assert_group_dies(pgid)
  end
end
