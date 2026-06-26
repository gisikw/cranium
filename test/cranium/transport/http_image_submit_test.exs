defmodule Cranium.Transport.HTTPImageSubmitTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Cranium.Messages.TextInput
  alias Cranium.Transport.HTTP

  test "multipart image submit broadcasts text input with image attachment" do
    Cranium.Events.subscribe()

    tmp = Path.join(System.tmp_dir!(), "cranium-image-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, <<137, 80, 78, 71>>)

    upload = %Plug.Upload{
      path: tmp,
      filename: "sample.png",
      content_type: "image/png"
    }

    conn =
      Plug.Test.conn(:post, "/v1/submit", %{
        "conversation_id" => "http-image-#{System.unique_integer([:positive])}",
        "text" => "look",
        "image" => upload,
        "profile" => "test"
      })
      |> HTTP.call(HTTP.init([]))

    assert conn.status == 202

    assert_receive {:text_input, %TextInput{text: "look", attachments: [attachment]}}, 1_000
    assert attachment.type == :image
    assert attachment.media_type == "image/png"
    assert attachment.filename == "sample.png"
    assert attachment.data == <<137, 80, 78, 71>>

    File.rm(tmp)
  end
end
