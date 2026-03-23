defmodule Cranium.Context.HistoryManager do
  @moduledoc """
  Retrieves and formats conversation history from Store.

  Loads the conversation history and formats it as a list of messages
  suitable for the LLM API. The current user message is appended as
  the final entry.

  ## History Windowing

  For long conversations, only the most recent N messages are included
  (configurable). Older messages are summarized by the
  ConversationSummarizer and available via the cross-conversation
  landscape.

  ## Message Format

  Output messages follow the Anthropic API format:

      [
        %{role: "user", content: "..."},
        %{role: "assistant", content: "..."},
        ...
        %{role: "user", content: "current message"}
      ]
  """

  @default_window 50

  @spec process(map(), map()) :: {:ok, map()}
  def process(message, context) do
    conversation_id = message.conversation_id
    window = Map.get(context, :history_window, @default_window)
    epoch_id = Map.get(context, :epoch_id)

    {:ok, history} =
      Cranium.Store.get_messages(conversation_id, limit: window, epoch_id: epoch_id)

    api_messages =
      history
      |> Enum.map(&format_message/1)
      |> Enum.concat([format_current(message)])

    {:ok, Map.put(message, :messages, api_messages)}
  end

  defp format_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp format_message(msg) do
    %{"role" => "user", "content" => msg[:text] || ""}
  end

  defp format_current(message) do
    content = build_content(message)
    %{"role" => "user", "content" => content}
  end

  defp build_content(%{text: text, attachments: attachments})
       when is_list(attachments) and attachments != [] do
    # Multi-part content for messages with images
    image_parts =
      attachments
      |> Enum.filter(&(&1.type == :image))
      |> Enum.map(fn att ->
        %{
          "type" => "image",
          "source" => %{
            "type" => "base64",
            "media_type" => att.media_type,
            "data" => Base.encode64(att.data)
          }
        }
      end)

    text_part = [%{"type" => "text", "text" => text}]
    image_parts ++ text_part
  end

  defp build_content(%{text: text}), do: text
  defp build_content(_), do: ""
end
