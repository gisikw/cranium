defmodule Cranium.Agent.Tools.Subagent do
  @moduledoc """
  Delegate tasks to a Claude Code subagent.

  Spawns `claude -p` with the exocortex subagent prompt, full permissions,
  and no session persistence. Use for research, file operations, code
  exploration — anything that benefits from autonomous tool use.
  """

  @behaviour Cranium.Agent.Tool

  require Logger

  @subagent_prompt_file "/home/dev/Projects/exocortex/notes/SUBAGENT.md"

  @impl true
  def execute(%{"prompt" => prompt}, _opts) do
    Logger.info("Subagent invoked", prompt_preview: String.slice(prompt, 0, 120))

    args = [
      "-p",
      "--output-format=json",
      "--append-system-prompt-file=#{@subagent_prompt_file}",
      "--dangerously-skip-permissions",
      "--no-session-persistence",
      prompt
    ]

    case System.cmd("claude", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, extract_result(output)}
      {output, code} -> {:ok, "exit code #{code}\n#{output}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_input, _opts), do: {:error, "missing 'prompt' field"}

  defp extract_result(output) do
    case Jason.decode(output) do
      {:ok, %{"result" => result}} -> result
      _ -> output
    end
  end

  @impl true
  def name, do: "subagent"

  def timeout, do: 300_000

  @impl true
  def schema do
    %{
      name: "subagent",
      description:
        "Delegate a task to a Claude Code subagent. The subagent has full filesystem " <>
          "and development tool access. Use for research, code exploration, file operations, " <>
          "and multi-step tasks that benefit from autonomous execution.",
      input_schema: %{
        type: "object",
        properties: %{
          prompt: %{
            type: "string",
            description:
              "The task for the subagent. Be specific and include all necessary context."
          }
        },
        required: ["prompt"]
      }
    }
  end
end
