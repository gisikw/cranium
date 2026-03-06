defmodule Cranium.Agent.Tools.Bash do
  @moduledoc """
  Execute shell commands and return output.
  """

  @behaviour Cranium.Agent.Tool

  require Logger

  @impl true
  def execute(%{"command" => command}, _opts) do
    Logger.info("Bash tool: #{command}")

    case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
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
