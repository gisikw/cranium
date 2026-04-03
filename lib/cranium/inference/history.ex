defmodule Cranium.Inference.History do
  @moduledoc """
  Conversation history provider.

  Retrieves and formats conversation history from Store into the Anthropic
  API message format. Appends the current user message as the final entry.

  ## Contribute

  `contribute/2` returns a list of formatted messages. Options:

  - `:epoch_id` — scope history to this epoch
  - `:window` — number of recent messages to include (default 50)
  - `:text` — current user message text (appended as final message)
  - `:attachments` — image attachments for current message
  """

  use GenServer
  require Logger

  @default_window 50

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return formatted conversation history with the current message appended.

  ## Options

  - `:epoch_id` — epoch scope for history query
  - `:window` — max messages to retrieve (default 50)
  - `:text` — current user message text
  - `:attachments` — list of image attachments
  """
  @spec contribute(String.t(), keyword()) :: [map()]
  def contribute(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:contribute, conversation_id, opts})
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:contribute, conversation_id, opts}, _from, state) do
    epoch_id = Keyword.get(opts, :epoch_id)
    window = Keyword.get(opts, :window, @default_window)
    text = Keyword.get(opts, :text, "")
    attachments = Keyword.get(opts, :attachments, [])

    {:ok, history} =
      Cranium.Store.get_messages(conversation_id, limit: window, epoch_id: epoch_id)

    messages =
      history
      |> Enum.map(&format_message/1)
      |> Enum.concat([format_current(text, attachments)])

    {:reply, messages, state}
  end

  # --- Formatting ---

  defp format_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp format_message(msg) do
    %{"role" => "user", "content" => msg[:text] || ""}
  end

  defp format_current(text, attachments)
       when is_list(attachments) and attachments != [] do
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

    content = image_parts ++ [%{"type" => "text", "text" => text}]
    %{"role" => "user", "content" => content}
  end

  defp format_current(text, _attachments), do: %{"role" => "user", "content" => text}
end
