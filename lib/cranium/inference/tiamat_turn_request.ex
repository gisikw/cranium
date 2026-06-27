defmodule Cranium.Inference.TiamatTurnRequest do
  @moduledoc """
  Assembles native Tiamat turn API requests from Cranium state.

  This module is deliberately pure-ish and backend-adapter-facing. It does not
  replace `TurnAssembler`; it gives the Tiamat backend path a stable request
  shape built from Cranium's native transcript rows rather than legacy provider
  chat messages.
  """

  alias Cranium.Inference.Agent.ToolRouter
  alias Cranium.Inference.NativeHistory

  @schema "tiamat.turn.request.v1"

  @doc """
  Build a Tiamat `/v1/router/turns` request.

  Required options:
  - `:conversation_id`
  - `:epoch_id`
  - `:router_profile`

  Common options:
  - `:system_prompt` — binary prompt text, used as one `pre` fragment
  - `:system_prompt_pre` / `:system_prompt_post` — prompt fragments
  - `:tools_disabled` — omit tools when true
  - `:request_id` — generated when omitted
  - `:session_key` — defaults to `cranium:<conversation_id>:<epoch_id>`
  - `:append_current_user` — persist current user content before history build
  - `:current_user_text` / `:current_user_content` — content for append
  - `:origin` — provenance/origin for appended current user row
  """
  @spec assemble(keyword() | map()) :: map()
  def assemble(opts) do
    opts = Map.new(opts)

    conversation_id = fetch!(opts, :conversation_id)
    epoch_id = fetch!(opts, :epoch_id)
    router_profile = fetch!(opts, :router_profile)

    maybe_append_current_user(conversation_id, epoch_id, opts)

    %{
      "schema" => @schema,
      "request_id" => Map.get(opts, :request_id) || Ecto.UUID.generate(),
      "session_key" => Map.get(opts, :session_key) || session_key(conversation_id, epoch_id),
      "router_profile" => router_profile,
      "system_prompt" => system_prompt(opts),
      "messages" => native_messages(conversation_id, epoch_id),
      "tools" => tools(conversation_id, opts)
    }
  end

  @spec session_key(String.t(), String.t()) :: String.t()
  def session_key(conversation_id, epoch_id), do: "cranium:#{conversation_id}:#{epoch_id}"

  defp maybe_append_current_user(conversation_id, epoch_id, %{append_current_user: true} = opts) do
    content =
      Map.get(opts, :current_user_content) ||
        current_text_content(Map.get(opts, :current_user_text, ""))

    Cranium.Store.append_message(conversation_id, epoch_id, %{
      role: :user,
      content: content,
      origin: Map.get(opts, :origin),
      parent_id: current_parent_id(conversation_id, epoch_id, opts),
      provenance: Map.get(opts, :current_user_provenance)
    })
  end

  defp maybe_append_current_user(_conversation_id, _epoch_id, _opts), do: :ok

  defp current_text_content(text) when is_binary(text) do
    if String.trim(text) == "" do
      []
    else
      [%{"type" => "text", "text" => text}]
    end
  end

  defp current_text_content(_), do: []

  defp current_parent_id(conversation_id, epoch_id, %{current_user_parent_id: :last_message}) do
    case Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id) do
      {:ok, []} -> nil
      {:ok, messages} -> messages |> List.last() |> Map.get(:id)
      _ -> nil
    end
  end

  defp current_parent_id(_conversation_id, _epoch_id, opts),
    do: Map.get(opts, :current_user_parent_id)

  defp native_messages(conversation_id, epoch_id) do
    conversation_id
    |> NativeHistory.contribute(epoch_id: epoch_id)
    |> Enum.map(&stringify_message/1)
    |> Enum.reject(&(Map.get(&1, "content") == []))
  end

  defp stringify_message(message) do
    %{
      "id" => message.id,
      "parent_id" => message.parent_id,
      "created_at" => message.created_at,
      "role" => message.role,
      "content" => message.content |> Enum.map(&native_content_block/1) |> Enum.reject(&is_nil/1),
      "provenance" => message.provenance
    }
  end

  defp native_content_block(%{"type" => "text", "text" => text})
       when is_binary(text) do
    if String.trim(text) == "", do: nil, else: %{"type" => "text", "text" => text}
  end

  defp native_content_block(%{"type" => "text"}), do: nil

  defp native_content_block(%{"type" => "image", "source" => %{"type" => "base64"} = source}) do
    %{
      "type" => "image",
      "image_media_type" => Map.get(source, "media_type"),
      "image_data" => Map.get(source, "data")
    }
  end

  defp native_content_block(%{"type" => "image", "source" => %{"type" => "url"} = source}) do
    %{
      "type" => "image",
      "image_media_type" => Map.get(source, "media_type"),
      "image_url" => Map.get(source, "url")
    }
  end

  defp native_content_block(block), do: block

  defp system_prompt(opts) do
    %{
      "pre" =>
        prompt_fragments(Map.get(opts, :system_prompt_pre),
          fallback_system_prompt: Map.get(opts, :system_prompt)
        ),
      "post" => prompt_fragments(Map.get(opts, :system_prompt_post))
    }
  end

  defp prompt_fragments(nil, fallback_system_prompt: prompt)
       when is_binary(prompt) and prompt != "" do
    [%{"id" => "cranium-system", "text" => prompt}]
  end

  defp prompt_fragments(nil, _fallback), do: []

  defp prompt_fragments(prompt, _fallback) when is_binary(prompt) and prompt != "" do
    [%{"id" => "cranium-system", "text" => prompt}]
  end

  defp prompt_fragments(fragments, _fallback) when is_list(fragments),
    do: Enum.map(fragments, &prompt_fragment/1)

  defp prompt_fragments(_, _), do: []

  defp prompt_fragments(nil), do: []

  defp prompt_fragments(prompt) when is_binary(prompt) and prompt != "" do
    [%{"id" => "cranium-system", "text" => prompt}]
  end

  defp prompt_fragments(fragments) when is_list(fragments),
    do: Enum.map(fragments, &prompt_fragment/1)

  defp prompt_fragments(_), do: []

  defp prompt_fragment(%{"id" => id, "text" => text}), do: %{"id" => id, "text" => text}
  defp prompt_fragment(%{id: id, text: text}), do: %{"id" => id, "text" => text}
  defp prompt_fragment(text) when is_binary(text), do: %{"id" => "fragment", "text" => text}

  defp tools(_conversation_id, %{tools_disabled: true}), do: []

  defp tools(conversation_id, _opts),
    do: ToolRouter.tool_definitions(conversation_id) |> Enum.map(&stringify_tool/1)

  defp stringify_tool(tool) when is_map(tool) do
    tool
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> stringify_nested_schema("input_schema")
  end

  defp stringify_nested_schema(%{"input_schema" => schema} = tool, "input_schema")
       when is_map(schema) do
    Map.put(tool, "input_schema", stringify_schema(schema))
  end

  defp stringify_nested_schema(tool, _), do: tool

  defp stringify_schema(schema) when is_map(schema) do
    Map.new(schema, fn {key, value} -> {to_string(key), stringify_schema(value)} end)
  end

  defp stringify_schema(list) when is_list(list), do: Enum.map(list, &stringify_schema/1)
  defp stringify_schema(value), do: value

  defp fetch!(opts, key) do
    Map.get(opts, key) || raise ArgumentError, "missing required option #{inspect(key)}"
  end
end
