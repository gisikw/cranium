defmodule Cranium.Backend.LLM.CCMcpServerTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.CCMcpServer

  describe "marker_tools/0" do
    test "returns the three marker tool names" do
      assert CCMcpServer.marker_tools() == ~w(show show_code play_audio)
    end
  end

  describe "write_config/0" do
    test "writes valid MCP config JSON" do
      {:ok, path} = CCMcpServer.write_config()
      on_exit(fn -> File.rm(path) end)

      assert File.exists?(path)

      {:ok, content} = File.read(path)
      {:ok, config} = Jason.decode(content)

      assert %{"mcpServers" => %{"cranium-markers" => server}} = config
      assert Map.has_key?(server, "command")
      assert Map.has_key?(server, "args")
      assert is_list(server["args"])
      assert length(server["args"]) == 1
    end
  end

  describe "server_script_path/0" do
    test "returns a path ending in marker_server.py" do
      path = CCMcpServer.server_script_path()
      assert String.ends_with?(path, "priv/mcp/marker_server.py")
    end
  end

  describe "marker_server.py integration" do
    @describetag :python3
    test "responds to initialize and tools/list" do
      python = System.find_executable("python3") || System.find_executable("python")

      if python == nil do
        IO.puts("Skipping: python3 not found")
      else
        script = CCMcpServer.server_script_path()
        assert File.exists?(script), "marker_server.py not found at #{script}"

        init_request = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}})
        list_request = Jason.encode!(%{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}})
        input = "#{init_request}\n#{list_request}\n"

        {output, 0} = System.cmd(python, [script], input: input, stderr_to_stdout: true)

        lines = String.split(String.trim(output), "\n")
        assert length(lines) == 2

        {:ok, init_resp} = Jason.decode(Enum.at(lines, 0))
        assert init_resp["id"] == 1
        assert init_resp["result"]["protocolVersion"]

        {:ok, list_resp} = Jason.decode(Enum.at(lines, 1))
        assert list_resp["id"] == 2
        tools = list_resp["result"]["tools"]
        assert length(tools) == 3
        tool_names = Enum.map(tools, & &1["name"])
        assert "show" in tool_names
        assert "show_code" in tool_names
        assert "play_audio" in tool_names
      end
    end
  end
end
