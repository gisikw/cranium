defmodule Cranium.MuseExecLocalTest do
  @moduledoc """
  Asserts the local shell-out path of `Cranium.Muse.exec/4` — with no
  exec_endpoint configured — invokes the muse binary with exactly the argv,
  cwd, and env additions it always has. A fake `muse` script prepended to
  PATH records its invocation to a file.

  async: false — mutates the VM-wide PATH for the duration of the module.
  """

  use ExUnit.Case, async: false

  alias Cranium.Muse

  setup_all do
    dir = Path.join(System.tmp_dir!(), "muse-fake-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    fake_muse = Path.join(dir, "muse")

    File.write!(fake_muse, """
    #!/bin/sh
    {
      pwd
      echo "DEPTH=${MUSE_ROOM_DEPTH-unset}"
      for a in "$@"; do printf '%s\\n' "$a"; done
    } > "$MUSE_FAKE_OUT"
    printf '{"output": "fake ok"}'
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
    out = Path.join(scratch, "invocation-#{:erlang.unique_integer([:positive])}.txt")
    System.put_env("MUSE_FAKE_OUT", out)

    working_dir = Path.join(scratch, "workdir")
    File.mkdir_p!(working_dir)

    on_exit(fn -> System.delete_env("MUSE_FAKE_OUT") end)

    %{out: out, working_dir: working_dir}
  end

  defp read_invocation(out) do
    [cwd, "DEPTH=" <> depth | argv] = out |> File.read!() |> String.split("\n", trim: true)
    {cwd, depth, argv}
  end

  test "sandbox posture: grants then --exec payload, cwd set, depth env",
       %{out: out, working_dir: working_dir} do
    config = %{posture: :sandbox, rw: ["/extra"], ro: ["/ref"], depth: 1}

    assert {:ok, "fake ok"} = Muse.exec("bash", %{"command" => "ls"}, working_dir, config)

    {cwd, depth, argv} = read_invocation(out)

    payload = Jason.encode!(%{tool: "bash", input: %{"command" => "ls"}})
    assert argv == ["--rw", working_dir, "--rw", "/extra", "--ro", "/ref", "--exec", payload]
    assert Path.expand(cwd) == Path.expand(working_dir)
    assert depth == "1"
  end

  test "permissive posture: bare --exec, still cd'd into working dir",
       %{out: out, working_dir: working_dir} do
    config = %{posture: :permissive, rw: ["/ignored"]}

    assert {:ok, "fake ok"} = Muse.exec("read", %{"path" => "f"}, working_dir, config)

    {cwd, depth, argv} = read_invocation(out)

    payload = Jason.encode!(%{tool: "read", input: %{"path" => "f"}})
    assert argv == ["--exec", payload]
    assert Path.expand(cwd) == Path.expand(working_dir)
    assert depth == "unset"
  end

  test "default tool_config: working dir is the only rw grant, no depth env",
       %{out: out, working_dir: working_dir} do
    assert {:ok, "fake ok"} = Muse.exec("glob", %{}, working_dir)

    {_cwd, depth, argv} = read_invocation(out)

    payload = Jason.encode!(%{tool: "glob", input: %{}})
    assert argv == ["--rw", working_dir, "--exec", payload]
    assert depth == "unset"
  end
end
