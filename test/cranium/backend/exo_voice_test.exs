defmodule Cranium.Backend.ExoVoiceTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.TTS.ExoVoice

  @plug_name CraniumExoVoiceTest

  describe "synthesize/2" do
    test "returns {:ok, audio_binary} on HTTP 200" do
      audio = <<1, 2, 3, 4, 5>>

      Req.Test.stub(@plug_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, audio)
      end)

      assert {:ok, ^audio} = ExoVoice.synthesize("Hello world", plug: {Req.Test, @plug_name})
    end

    test "returns {:error, {:http_error, 503, _}} on non-200" do
      Req.Test.stub(@plug_name, fn conn ->
        Plug.Conn.send_resp(conn, 503, "Service Unavailable")
      end)

      assert {:error, {:http_error, 503, _}} =
               ExoVoice.synthesize("Hello world", plug: {Req.Test, @plug_name})
    end

    test "returns {:error, _} on connection error" do
      Req.Test.stub(@plug_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _} = ExoVoice.synthesize("Hello world", plug: {Req.Test, @plug_name})
    end
  end
end
