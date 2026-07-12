defmodule Cranium.Muse.HTTPTest do
  @moduledoc """
  Remote exec through `Cranium.Muse.exec/4` against a stub HTTP server
  (Req.Test plug — the same stubbing mechanism the other Req clients use).

  Covers the wire mapping (request fields mirror the CLI argv construction),
  auth, timeout/unreachable degradation, and response unwrapping parity with
  the local CLI path.
  """

  use ExUnit.Case, async: true

  alias Cranium.Muse

  @plug_name CraniumMuseHTTPTest
  @working_dir "/Users/kevin/Projects/app"

  defp endpoint(overrides) do
    Map.merge(
      %{
        url: "http://obrien.test:7777",
        token_env: nil,
        token_file: nil,
        projects_dir: "/Users/kevin/Projects",
        timeout_ms: nil,
        plug: {Req.Test, @plug_name}
      },
      overrides
    )
  end

  defp put_token_env(value) do
    var = "MUSE_EXEC_TOKEN_#{:erlang.unique_integer([:positive])}"
    System.put_env(var, value)
    on_exit(fn -> System.delete_env(var) end)
    var
  end

  defp tool_config(endpoint_overrides, config_overrides \\ %{}) do
    Map.merge(%{exec_endpoint: endpoint(endpoint_overrides)}, config_overrides)
  end

  defp ok_body(output), do: Jason.encode!(%{"output" => output, "exit_code" => 0})

  defp capture_request do
    parent = self()

    Req.Test.stub(@plug_name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:request, conn.method, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(raw)}
      )

      Plug.Conn.send_resp(conn, 200, ok_body("done"))
    end)
  end

  describe "request mapping (mirrors CLI argv one-for-one)" do
    test "POSTs payload, working dir, grants, and env to /exec with bearer auth" do
      var = put_token_env("sekrit")
      capture_request()

      config =
        tool_config(%{token_env: var}, %{
          posture: :sandbox,
          rw: ["/Users/kevin/extra-rw"],
          ro: ["/Users/kevin/reference"],
          depth: 2
        })

      input = %{"command" => "swift build"}

      assert {:ok, "done"} = Muse.exec("bash", input, @working_dir, config)

      assert_received {:request, "POST", "/exec", ["Bearer sekrit"], body}

      # tool/input ride structurally; serve rebuilds the --exec payload itself.
      # No pre-encoded `payload` string — the fields match serve's handleExec
      # decoder (DisallowUnknownFields), so a shape drift fails this assertion.
      assert body["tool"] == "bash"
      assert body["input"] == input
      refute Map.has_key?(body, "payload")

      # The directory serve cd's into rides as `cwd`, matching serveExecRequest.
      assert body["cwd"] == @working_dir
      refute Map.has_key?(body, "working_dir")

      # Sandbox posture: working_dir is the first rw grant, then profile rw
      assert body["rw"] == [@working_dir, "/Users/kevin/extra-rw"]
      assert body["ro"] == ["/Users/kevin/reference"]

      # Depth maps to the same env addition the CLI would set
      assert body["env"] == %{"MUSE_ROOM_DEPTH" => "2"}

      # A client deadline also bounds serve's subprocess (default here).
      assert body["timeout_ms"] == 600_000
    end

    test "permissive posture sends no grants, exactly like the CLI omits them" do
      var = put_token_env("sekrit")
      capture_request()

      config = tool_config(%{token_env: var}, %{posture: :permissive, rw: ["/ignored"]})

      assert {:ok, "done"} = Muse.exec("bash", %{}, @working_dir, config)

      assert_received {:request, "POST", "/exec", _auth, body}
      assert body["rw"] == []
      assert body["ro"] == []
      # cd applies regardless of posture, so the dir still rides along as cwd
      assert body["cwd"] == @working_dir
    end

    test "no depth means no env additions" do
      var = put_token_env("sekrit")
      capture_request()

      assert {:ok, "done"} = Muse.exec("read", %{"path" => "x"}, @working_dir, tool_config(%{token_env: var}))

      assert_received {:request, _, _, _, body}
      assert body["env"] == %{}
    end
  end

  describe "response unwrapping (shared with the CLI path)" do
    test "unwraps a content envelope identically to unwrap_exec_output" do
      var = put_token_env("sekrit")

      envelope = %{
        "type" => "content",
        "content" => [%{"type" => "text", "text" => "built"}]
      }

      Req.Test.stub(@plug_name, fn conn ->
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"output" => envelope, "exit_code" => 0}))
      end)

      assert {:ok, unwrapped} = Muse.exec("bash", %{}, @working_dir, tool_config(%{token_env: var}))

      # Byte-for-byte the same treatment the local path applies to stdout
      assert unwrapped == Muse.unwrap_exec_output(Jason.encode!(%{"output" => envelope}))
      assert Jason.decode!(unwrapped) == envelope
    end

    test "string output comes back as-is without JSON quoting" do
      var = put_token_env("sekrit")

      Req.Test.stub(@plug_name, fn conn ->
        Plug.Conn.send_resp(conn, 200, ok_body("plain text result"))
      end)

      assert {:ok, "plain text result"} =
               Muse.exec("bash", %{}, @working_dir, tool_config(%{token_env: var}))
    end

    test "nonzero exit code surfaces the error field, like CLI stderr/exit" do
      var = put_token_env("sekrit")

      Req.Test.stub(@plug_name, fn conn ->
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"error" => "sandbox denied", "exit_code" => 1}))
      end)

      assert {:error, "sandbox denied"} =
               Muse.exec("bash", %{}, @working_dir, tool_config(%{token_env: var}))
    end

    test "nonzero exit code without an error field falls back to exit=N slice" do
      var = put_token_env("sekrit")

      Req.Test.stub(@plug_name, fn conn ->
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"output" => "partial", "exit_code" => 3}))
      end)

      assert {:error, "exit=3: " <> _} =
               Muse.exec("bash", %{}, @working_dir, tool_config(%{token_env: var}))
    end
  end

  describe "degradation (session must survive, like a missing muse binary)" do
    test "401 returns a tool error" do
      var = put_token_env("wrong-token")

      Req.Test.stub(@plug_name, fn conn ->
        Plug.Conn.send_resp(conn, 401, "unauthorized")
      end)

      assert {:error, message} = Muse.exec("bash", %{}, @working_dir, tool_config(%{token_env: var}))
      assert message =~ "401"
    end

    test "timeout returns a tool error naming the ceiling" do
      var = put_token_env("sekrit")

      Req.Test.stub(@plug_name, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, message} =
               Muse.exec("bash", %{}, @working_dir, tool_config(%{token_env: var, timeout_ms: 120_000}))

      assert message =~ "timed out after 120000ms"
    end

    test "unreachable endpoint returns a tool error instead of raising" do
      var = put_token_env("sekrit")

      Req.Test.stub(@plug_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, message} = Muse.exec("bash", %{}, @working_dir, tool_config(%{token_env: var}))
      assert message =~ "unreachable"
    end

    test "missing token degrades without attempting a request" do
      # No stub registered: any HTTP attempt would fail the test loudly.
      config = tool_config(%{token_env: "MUSE_EXEC_TOKEN_DEFINITELY_UNSET"})

      assert {:error, message} = Muse.exec("bash", %{}, @working_dir, config)
      assert message =~ "token unavailable"
    end
  end

  describe "token indirection" do
    test "reads token from a file, trimming trailing newline" do
      path =
        Path.join(
          System.tmp_dir!(),
          "muse-token-#{:erlang.unique_integer([:positive])}"
        )

      File.write!(path, "file-sekrit\n")
      on_exit(fn -> File.rm(path) end)

      parent = self()

      Req.Test.stub(@plug_name, fn conn ->
        send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.send_resp(conn, 200, ok_body("ok"))
      end)

      assert {:ok, "ok"} =
               Muse.exec("bash", %{}, @working_dir, tool_config(%{token_file: path}))

      assert_received {:auth, ["Bearer file-sekrit"]}
    end

    test "unreadable token file degrades to a tool error" do
      config = tool_config(%{token_file: "/nonexistent/muse-token"})

      assert {:error, message} = Muse.exec("bash", %{}, @working_dir, config)
      assert message =~ "token unavailable"
    end
  end
end
