defmodule Cranium.Transport.HTTPTest do
  use ExUnit.Case, async: false

  alias Cranium.Transport.HTTP
  alias Cranium.Manifest

  # Tests use the global Manifest started in test_helper.exs.
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
    test "returns 501 (TTS cache not yet implemented)" do
      conn =
        Plug.Test.conn(:get, "/v1/streams/s1/segments/0/audio")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 501
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
