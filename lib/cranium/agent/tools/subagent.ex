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
    preview = String.slice(prompt, 0, 200) |> String.replace("\n", " ")
    Logger.info("Subagent: #{preview}")

    args = [
      "-p",
      "--output-format=json",
      "--append-system-prompt-file=#{@subagent_prompt_file}",
      "--dangerously-skip-permissions",
      prompt
    ]

    Logger.info("Subagent args: #{inspect(args)}")

    # Use a wrapper to close stdin immediately, preventing claude from
    # blocking on interactive prompts. The exec replaces the shell process
    # so we still get the real exit code.
    wrapper = "exec claude #{Enum.map_join(args, " ", &shell_escape/1)} </dev/null"

    case System.cmd("sh", ["-c", wrapper], stderr_to_stdout: true, env: [{"CLAUDECODE", nil}, {"ANTHROPIC_API_KEY", nil}]) do
      {output, 0} ->
        Logger.info("Subagent completed", exit_code: 0, output_bytes: byte_size(output))
        {:ok, extract_result(output)}

      {output, code} ->
        Logger.warning("Subagent failed",
          exit_code: code,
          output_bytes: byte_size(output),
          output_preview: String.slice(output, 0, 500)
        )

        {:ok, "exit code #{code}\n#{output}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_input, _opts), do: {:error, "missing 'prompt' field"}

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

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
