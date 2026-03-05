defmodule Cranium.Effects.ConversationSummarizer do
  @moduledoc """
  Generates cross-conversation summaries periodically.

  Every N turns (configured via `:summary_interval`), generates a 2-4
  sentence summary of the conversation's current activity. These summaries
  are used by PromptBuilder to create the cross-conversation landscape —
  giving the agent awareness of what's happening in other conversations.

  ## Generation

  Uses a lightweight prompt that asks for a concise activity summary.
  The summary focuses on what's being worked on and recent decisions,
  not conversation details.
  """

  require Logger

  @summary_prompt """
  Summarize what's currently being worked on in this conversation in 2-4 sentences.
  Focus on the current task, recent decisions, and any notable context.
  Write in present tense. Be concise.
  """

  @spec generate(String.t()) :: :ok | {:error, term()}
  def generate(conversation_id) do
    Logger.info("Generating conversation summary",
      conversation_id: conversation_id,
      stage: :effects
    )

    backend = Application.get_env(:cranium, :backends)[:llm]

    {:ok, history} = Cranium.Store.get_messages(conversation_id, limit: 30)

    messages =
      Enum.map(history, fn msg ->
        %{"role" => to_string(msg[:role] || "user"), "content" => msg[:content] || ""}
      end)

    messages = messages ++ [%{"role" => "user", "content" => @summary_prompt}]

    case backend.stream_chat(messages, system: "", tools: []) do
      {:ok, stream_pid} ->
        case collect_text(stream_pid) do
          {:ok, text} ->
            Cranium.Store.save_summary(conversation_id, text)

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
