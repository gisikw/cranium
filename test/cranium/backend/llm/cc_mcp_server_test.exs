defmodule Cranium.Backend.LLM.CCMcpServerTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.CCMcpServer

  describe "marker_tools/0" do
    test "returns the four marker and meta-tool names" do
      assert CCMcpServer.marker_tools() == ~w(show show_code play_audio clear_context)
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
    end
  end

  describe "server_script_path/0" do
    test "returns a path ending in marker_server.sh" do
      path = CCMcpServer.server_script_path()
      assert String.ends_with?(path, "priv/mcp/marker_server.sh")
    end
  end

  describe "marker_server.sh integration" do
    # Disabled: depends on File.cwd!() resolving priv/mcp/ which breaks
    # when workingDirectory != project checkout. Tracked in cv2-5761.
    @tag :skip
    test "responds to initialize, tools/list, and tools/call" do
      script = CCMcpServer.server_script_path()
      assert File.exists?(script), "marker_server.sh not found at #{script}"

      init_request = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}})
      list_request = Jason.encode!(%{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}})

      call_request =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: %{name: "show", arguments: %{url: "test.png"}}
        })

      notification = Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"})

      # Pipe input via printf since System.cmd doesn't support stdin
      escaped =
        Enum.map_join(
          [init_request, notification, list_request, call_request],
          "\\n",
          &String.replace(&1, "\"", "\\\"")
        )

      {output, 0} =
        System.cmd("sh", ["-c", "printf '#{escaped}\\n' | bash #{script}"],
          stderr_to_stdout: true
        )

      lines = String.split(String.trim(output), "\n")

      assert length(lines) == 3,
             "Expected 3 responses (notification skipped), got #{length(lines)}: #{inspect(lines)}"

      {:ok, init_resp} = Jason.decode(Enum.at(lines, 0))
      assert init_resp["id"] == 1
      assert init_resp["result"]["protocolVersion"] == "2024-11-05"
      assert init_resp["result"]["serverInfo"]["name"] == "cranium-markers"

      {:ok, list_resp} = Jason.decode(Enum.at(lines, 1))
      assert list_resp["id"] == 2
      tools = list_resp["result"]["tools"]
      assert length(tools) == 4
      tool_names = Enum.map(tools, & &1["name"])
      assert "show" in tool_names
      assert "show_code" in tool_names
      assert "play_audio" in tool_names
      assert "clear_context" in tool_names

      {:ok, call_resp} = Jason.decode(Enum.at(lines, 2))
      assert call_resp["id"] == 3
      [content_block] = call_resp["result"]["content"]
      assert content_block["type"] == "text"
      assert {:ok, %{"success" => true}} = Jason.decode(content_block["text"])
    end
  end
end
