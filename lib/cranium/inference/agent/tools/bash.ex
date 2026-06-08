defmodule Cranium.Inference.Agent.Tools.Bash do
  @moduledoc """
  Execute shell commands and return output.
  """

  @behaviour Cranium.Inference.Agent.Tool

  require Logger

  @impl true
  def execute(%{"command" => command}, opts) do
    Logger.info("Bash tool: #{command}")

    cmd_opts = [stderr_to_stdout: true]
    depth = Keyword.get(opts, :depth)
    cmd_opts = if depth, do: Keyword.put(cmd_opts, :env, [{"MUSE_ROOM_DEPTH", to_string(depth)}]), else: cmd_opts

    case System.cmd("sh", ["-c", command], cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "exit code #{code}\n#{output}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_input, _opts), do: {:error, "missing 'command' field"}

  @impl true
  def name, do: "bash"

  @impl true
  def schema do
    %{
      name: "bash",
      description: "Execute a shell command and return its output",
      input_schema: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The shell command to execute"}
        },
        required: ["command"]
      }
    }
  end
end
