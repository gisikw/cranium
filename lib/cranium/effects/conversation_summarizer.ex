defmodule Cranium.Effects.ConversationSummarizer do
  @moduledoc """
  Generates cross-conversation summaries periodically.

  Every N turns (configured via `:summary_interval`), generates a 2-4
  sentence summary of the conversation's current activity. These summaries
  are used by the Landscape module to create cross-conversation awareness.

  ## Generation

  Invokes a `/summarize` skill via `--plugin-dir` to control summarization
  behavior. The skill instructs the model to produce clean, factual
  summaries without reproducing verbatim text that could trigger prompt
  injection detection in receiving sessions.
  """

  require Logger

  @spec generate(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def generate(conversation_id, cc_session_id) do
    case cc_session_id do
      nil ->
        Logger.warning("No CC session ID — skipping summary generation",
          conversation_id: conversation_id,
          stage: :effects
        )

        {:error, :no_session}

      _ ->
        Logger.info("Generating conversation summary",
          conversation_id: conversation_id,
          stage: :effects
        )

        backend = Application.get_env(:cranium, :backends)[:llm]

        # Resume the existing session (forked, read-only) so the model already
        # has full conversation context. Just invoke the /summarize skill.
        messages = [%{"role" => "user", "content" => "/summarize"}]

        projects_dir = Application.get_env(:cranium, :paths)[:projects] || "~/Projects"
        working_dir = Cranium.Context.Router.resolve_project_dir(conversation_id, projects_dir)

        opts = [
          cc_session_id: cc_session_id,
          no_session_persistence: true,
          fork_session: true,
          tools: "",
          plugin_dir: Path.dirname(skills_dir()),
          working_dir: working_dir
        ]

        case backend.stream_chat(messages, opts) do
          {:ok, stream_pid} ->
            case collect_text(stream_pid) do
              {:ok, text} ->
                Cranium.Store.save_summary(conversation_id, text)
                write_to_hoard(conversation_id, text)

              {:error, reason} ->
                Logger.error("Summary generation failed: #{inspect(reason)}",
                  conversation_id: conversation_id
                )

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Summary LLM call failed: #{inspect(reason)}",
              conversation_id: conversation_id
            )

            {:error, reason}
        end
    end
  end

  defp skills_dir do
    Application.get_env(:cranium, :paths)[:skills]
  end

  defp write_to_hoard(conversation_id, text) do
    dir = Application.get_env(:cranium, :paths)[:summaries]
    if dir do
      now = System.system_time(:second)
      payload = %{
        "room_name" => conversation_id,
        "summary" => text,
        "last_message_ts" => now,
        "last_summary_ts" => now
      }

      path = Path.join(dir, "#{conversation_id}.json")

      case File.write(path, Jason.encode!(payload, pretty: true)) do
        :ok ->
          Logger.info("Summary written to hoard", conversation_id: conversation_id)

        {:error, reason} ->
          Logger.warning("Failed to write summary to hoard",
            conversation_id: conversation_id,
            reason: inspect(reason)
          )
      end
    end
  end

  defp collect_text(stream_pid) do
    ref = Process.monitor(stream_pid)
    do_collect(ref, "")
  end

  defp do_collect(ref, acc) do
    receive do
      {:llm_text, text} ->
        do_collect(ref, acc <> text)

      {:llm_stop, _} ->
        Process.demonitor(ref, [:flush])
        {:ok, acc}

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, {:stream_died, reason}}
    after
      60_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end
end
