defmodule Cranium.Transport.HTTPTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cranium.Transport.HTTP
  alias Cranium.Manifest
  alias Cranium.TTS.Cache

  setup :verify_on_exit!

  # Tests use the global Manifest and TTS.Cache started in test_helper.exs.
  # Use unique stream IDs per test for isolation.

  describe "GET /v1/streams/:id/manifest" do
    test "returns 200 with manifest JSON for existing stream" do
      sid = "http-test-#{System.unique_integer([:positive])}"
      :ok = Manifest.init_stream(sid, "conv1")
      :ok = Manifest.add_utterance(sid, 0, "Hello")

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/manifest")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert json["stream_id"] == sid
      assert json["status"] == "streaming"
      assert length(json["segments"]) == 1
      assert hd(json["segments"])["type"] == "utterance"
    end

    test "returns 404 for unknown stream" do
      conn =
        Plug.Test.conn(:get, "/v1/streams/nonexistent/manifest")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "stream not found"
    end
  end

  describe "GET /v1/streams/:id/segments/:n/text" do
    test "returns 200 with text content" do
      sid = "http-text-#{System.unique_integer([:positive])}"
      :ok = Manifest.init_stream(sid, "conv1")
      :ok = Manifest.add_utterance(sid, 0, "Hello world")

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/segments/0/text")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert conn.resp_body == "Hello world"
    end

    test "returns 404 for missing segment" do
      sid = "http-miss-#{System.unique_integer([:positive])}"
      :ok = Manifest.init_stream(sid, "conv1")

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/segments/99/text")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
    end
  end

  describe "GET /v1/streams/:id/segments/:n/audio" do
    test "returns 200 with audio from eager cache" do
      sid = "http-audio-eager-#{System.unique_integer([:positive])}"
      audio = <<0xFF, 0xFB, 0x90, 0x00>>

      :ok = Manifest.init_stream(sid, "conv1")
      :ok = Manifest.add_utterance(sid, 0, "Hello")
      :ok = Cache.put(sid, 0, audio)

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/segments/0/audio")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert conn.resp_body == audio
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["audio/mpeg; charset=utf-8"]
    end

    test "returns 200 with lazily synthesized audio on cache miss" do
      sid = "http-audio-lazy-#{System.unique_integer([:positive])}"
      audio = <<0xFF, 0xFB>>

      :ok = Manifest.init_stream(sid, "conv1")
      :ok = Manifest.add_utterance(sid, 0, "Hello world")

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn "Hello world", [] -> {:ok, audio} end)

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/segments/0/audio")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert conn.resp_body == audio
    end

    test "returns 404 for nonexistent segment" do
      conn =
        Plug.Test.conn(:get, "/v1/streams/nonexistent/segments/0/audio")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
    end

    test "returns 502 when TTS backend fails" do
      sid = "http-audio-fail-#{System.unique_integer([:positive])}"

      :ok = Manifest.init_stream(sid, "conv1")
      :ok = Manifest.add_utterance(sid, 0, "Hello world")

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn "Hello world", [] -> {:error, :connection_refused} end)

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/segments/0/audio")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "TTS synthesis failed"
    end
  end

  describe "manifest JSON shape" do
    test "matches README spec with utterances and cues" do
      sid = "http-shape-#{System.unique_integer([:positive])}"
      :ok = Manifest.init_stream(sid, "conv1")
      :ok = Manifest.add_utterance(sid, 0, "Hello world")
      :ok = Manifest.add_cue(sid, 1, :image, %{"url" => "img.png", "alt" => "test"})
      :ok = Manifest.add_utterance(sid, 2, "After image")
      :ok = Manifest.complete(sid)

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/manifest")
        |> HTTP.call(HTTP.init([]))

      json = Jason.decode!(conn.resp_body)
      assert json["status"] == "complete"
      [utt0, cue1, utt2] = json["segments"]

      assert utt0["renditions"]["text"]["url"] == "/v1/streams/#{sid}/segments/0/text"
      assert utt0["renditions"]["audio"]["url"] == "/v1/streams/#{sid}/segments/0/audio"
      assert cue1["cue_type"] == "image"
      assert utt2["index"] == 2
    end
  end

  describe "catch-all" do
    test "404 on unknown route" do
      conn =
        Plug.Test.conn(:get, "/unknown")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "not found"
    end
  end
end
