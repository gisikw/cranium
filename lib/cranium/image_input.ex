defmodule Cranium.ImageInput do
  @moduledoc """
  Utilities for canonical image input blocks.

  Cranium's internal model-facing message format is Anthropic-shaped content
  blocks. Image-capable profiles receive image blocks. Profiles that cannot
  receive an image, or image payloads Cranium cannot parse safely, receive a
  position-preserving text placeholder instead.
  """

  @supported_media_types ~w(image/jpeg image/png image/webp image/gif)

  @type profile :: map() | struct() | nil

  @doc "True when a resolved profile/profile struct declares image input support."
  @spec profile_supports_image_input?(profile()) :: boolean()
  def profile_supports_image_input?(profile) do
    capabilities = get_field(profile, :capabilities) || %{}

    get_field(capabilities, :image_input) == true or
      get_field(profile, :image_input) == true or
      get_field(profile, :vision) == true
  end

  @doc "Translate an OpenAI Chat Completions content part into internal blocks."
  @spec openai_chat_part_to_internal(map(), profile()) :: [map()]
  def openai_chat_part_to_internal(%{"type" => "text", "text" => text}, _profile)
      when is_binary(text) do
    [%{"type" => "text", "text" => text}]
  end

  def openai_chat_part_to_internal(%{"type" => "image_url", "image_url" => image_url}, profile) do
    url =
      case image_url do
        %{"url" => url} -> url
        %{url: url} -> url
        url when is_binary(url) -> url
        _ -> nil
      end

    detail =
      case image_url do
        %{"detail" => detail} -> detail
        %{detail: detail} -> detail
        _ -> nil
      end

    image_url_to_internal(url, profile, detail: detail, source: "openai image_url")
  end

  def openai_chat_part_to_internal(%{type: "text", text: text}, profile),
    do: openai_chat_part_to_internal(%{"type" => "text", "text" => text}, profile)

  def openai_chat_part_to_internal(%{type: "image_url", image_url: image_url}, profile),
    do: openai_chat_part_to_internal(%{"type" => "image_url", "image_url" => image_url}, profile)

  def openai_chat_part_to_internal(_part, _profile), do: []

  @doc "Translate an internal image block into an OpenAI Chat Completions image_url part."
  @spec internal_image_to_openai_chat_part(map()) :: map() | nil
  def internal_image_to_openai_chat_part(block) do
    with %{} = source <- get_field(block, :source),
         url when is_binary(url) <- image_source_to_url(source) do
      detail = get_field(block, :detail) || get_field(source, :detail)
      image_url = if detail, do: %{"url" => url, "detail" => detail}, else: %{"url" => url}
      %{"type" => "image_url", "image_url" => image_url}
    else
      _ -> nil
    end
  end

  @doc "Translate an internal image block into an OpenAI Responses input_image part."
  @spec internal_image_to_responses_part(map()) :: map() | nil
  def internal_image_to_responses_part(block) do
    with %{} = source <- get_field(block, :source),
         url when is_binary(url) <- image_source_to_url(source) do
      part = %{"type" => "input_image", "image_url" => url}

      case get_field(block, :detail) || get_field(source, :detail) do
        nil -> part
        detail -> Map.put(part, "detail", detail)
      end
    else
      _ -> nil
    end
  end

  @doc "Build a model-visible placeholder for an omitted image."
  @spec placeholder(String.t(), keyword()) :: map()
  def placeholder(reason, opts \\ []) do
    details =
      [
        optional_detail("media_type", Keyword.get(opts, :media_type)),
        optional_detail("filename", Keyword.get(opts, :filename)),
        optional_detail("source", Keyword.get(opts, :source))
      ]
      |> Enum.reject(&is_nil/1)

    suffix = if details == [], do: "", else: " " <> Enum.join(details, " ")

    %{
      "type" => "text",
      "text" => "[Image omitted: #{reason}.#{suffix}]"
    }
  end

  @doc "Returns true for internal image content blocks."
  def image_block?(%{"type" => "image"}), do: true
  def image_block?(%{type: "image"}), do: true
  def image_block?(_), do: false

  defp image_url_to_internal(nil, _profile, opts) do
    [placeholder("malformed image payload", source: Keyword.get(opts, :source))]
  end

  defp image_url_to_internal(url, profile, opts) when is_binary(url) do
    if profile_supports_image_input?(profile) do
      parse_image_url(url, opts)
    else
      [
        placeholder("selected profile does not support image input",
          source: Keyword.get(opts, :source)
        )
      ]
    end
  end

  defp parse_image_url("data:" <> _ = data_url, opts) do
    case Regex.run(~r/^data:([^;,]+);base64,(.*)$/s, data_url) do
      [_, media_type, data] ->
        cond do
          media_type not in @supported_media_types ->
            [
              placeholder("unsupported media type",
                media_type: media_type,
                source: Keyword.get(opts, :source)
              )
            ]

          true ->
            case Base.decode64(data) do
              {:ok, _bytes} ->
                [
                  %{
                    "type" => "image",
                    "source" => %{
                      "type" => "base64",
                      "media_type" => media_type,
                      "data" => data
                    }
                  }
                ]

              :error ->
                [
                  placeholder("malformed image payload",
                    media_type: media_type,
                    source: Keyword.get(opts, :source)
                  )
                ]
            end
        end

      _ ->
        [placeholder("malformed image data URL", source: Keyword.get(opts, :source))]
    end
  end

  defp parse_image_url("http://" <> _ = url, opts), do: remote_image_block(url, opts)
  defp parse_image_url("https://" <> _ = url, opts), do: remote_image_block(url, opts)

  defp parse_image_url(_url, opts) do
    [placeholder("malformed image URL", source: Keyword.get(opts, :source))]
  end

  defp remote_image_block(url, opts) do
    block = %{"type" => "image", "source" => %{"type" => "url", "url" => url}}

    case Keyword.get(opts, :detail) do
      nil -> [block]
      detail -> [Map.put(block, "detail", detail)]
    end
  end

  defp image_source_to_url(source) do
    case get_field(source, :type) do
      "base64" ->
        media_type = get_field(source, :media_type)
        data = get_field(source, :data)

        if is_binary(media_type) and is_binary(data) do
          "data:#{media_type};base64,#{data}"
        end

      "url" ->
        get_field(source, :url)

      _ ->
        nil
    end
  end

  defp optional_detail(_key, nil), do: nil
  defp optional_detail(_key, ""), do: nil
  defp optional_detail(key, value), do: "#{key}=#{safe_detail(value)}"

  defp safe_detail(value) do
    value
    |> to_string()
    |> String.replace(~r/[\]\[\n\r]/, " ")
    |> String.slice(0, 120)
  end

  defp get_field(nil, _field), do: nil

  defp get_field(map, field) when is_map(map),
    do: Map.get(map, field) || Map.get(map, to_string(field))
end
