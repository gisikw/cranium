defmodule Cranium.Backend.LLM.CCMcpServer do
  @moduledoc """
  MCP configuration generator for the Claude Code backend.

  Generates the `--mcp-config` JSON file that tells Claude Code about
  the cranium-markers MCP server (show, show_code, play_audio tools).
  """

  @marker_tools ~w(show show_code play_audio)

  @doc "List of marker tool names exposed via MCP."
  @spec marker_tools() :: [String.t()]
  def marker_tools, do: @marker_tools

  @doc """
  Write an MCP config JSON file to a temp path.

  Returns `{:ok, path}` on success.
  """
  @spec write_config() :: {:ok, String.t()} | {:error, term()}
  def write_config do
    config = %{
      "mcpServers" => %{
        "cranium-markers" => %{
          "command" => server_script_path(),
          "args" => []
        }
      }
    }

    path = Path.join(System.tmp_dir!(), "cranium_mcp_#{random_hex(8)}.json")

    case File.write(path, Jason.encode!(config)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Absolute path to the marker_server.sh script."
  @spec server_script_path() :: String.t()
  def server_script_path do
    # app_dir points to _build which may not have priv copied;
    # fall back to source tree
    build_path = Application.app_dir(:cranium, "priv/mcp/marker_server.sh")

    if File.exists?(build_path) do
      build_path
    else
      Path.join([File.cwd!(), "priv", "mcp", "marker_server.sh"])
    end
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end
end
