defmodule Cranium.Inference.ContentBlocks do
  @moduledoc """
  Normalizes user text and media attachments into provider-neutral content blocks.
  """

  @doc "Build user content blocks from text plus optional attachments."
  @spec user_content(String.t() | nil, list()) :: [map()]
  def user_content(text, attachments \\ []) do
    blocks = image_blocks(attachments) ++ text_blocks(text)

    if blocks == [], do: [%{"type" => "text", "text" => ""}], else: blocks
  end

  @doc "Return true when attachments contains at least one usable image."
  @spec has_images?(list()) :: boolean()
  def has_images?(attachments) when is_list(attachments) do
    Enum.any?(
      attachments,
      &(attachment_type(&1) == :image and attachment_data(&1) not in [nil, ""])
    )
  end

  def has_images?(_), do: false

  defp image_blocks(attachments) when is_list(attachments) do
    attachments
    |> Enum.filter(&(attachment_type(&1) == :image))
    |> Enum.flat_map(fn attachment ->
      case attachment_data(attachment) do
        data when is_binary(data) and data != "" ->
          [
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => attachment_media_type(attachment) || "image/png",
                "data" => Base.encode64(data)
              }
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp image_blocks(_), do: []

  defp text_blocks(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      []
    else
      [%{"type" => "text", "text" => text}]
    end
  end

  defp text_blocks(_), do: []

  defp attachment_type(attachment), do: value(attachment, :type, "type")
  defp attachment_data(attachment), do: value(attachment, :data, "data")
  defp attachment_media_type(attachment), do: value(attachment, :media_type, "media_type")

  defp value(map, atom_key, string_key) when is_map(map) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp value(_other, _atom_key, _string_key), do: nil
end
