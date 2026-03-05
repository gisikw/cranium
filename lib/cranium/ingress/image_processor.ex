defmodule Cranium.Ingress.ImageProcessor do
  @moduledoc """
  Handles image attachments.

  Downloads image content (if URL), stores it locally, and adds an
  attachment reference to the event. The Anthropic API accepts base64
  images in message content, so we preserve the binary data.

  Text-only events pass through unchanged.
  """

  @spec process(map(), map()) :: {:ok, map()} | {:error, term()}
  def process(%{type: :image, image: image} = event, _context) when is_binary(image) do
    attachment = %{
      type: :image,
      data: image,
      media_type: detect_media_type(image)
    }

    {:ok, %{event | type: :text, attachments: [attachment], image: nil}}
  end

  def process(event, _context), do: {:ok, event}

  defp detect_media_type(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: "image/png"
  defp detect_media_type(<<0xFF, 0xD8, _::binary>>), do: "image/jpeg"
  defp detect_media_type(<<0x47, 0x49, 0x46, _::binary>>), do: "image/gif"
  defp detect_media_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp detect_media_type(_), do: "application/octet-stream"
end
