defmodule Cranium.Transport.HTTPTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  import Mox

  alias Cranium.Transport.HTTP
  alias Cranium.Transport.Manifest
  alias Cranium.Media.TTS.Cache

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
      # Cache gets text from segment_ready events, not Manifest
      Cranium.Events.broadcast({:segment_ready, sid, 0, %{type: :utterance, text: "Hello world"}})
      :sys.get_state(Cache)

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
      Cranium.Events.broadcast({:segment_ready, sid, 0, %{type: :utterance, text: "Hello world"}})
      :sys.get_state(Cache)

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
    test "text-only disposition omits audio renditions" do
      sid = "http-shape-text-#{System.unique_integer([:positive])}"
      :ok = Manifest.init_stream(sid, "conv1")
      :ok = Manifest.add_utterance(sid, 0, "Hello world")

      conn =
        Plug.Test.conn(:get, "/v1/streams/#{sid}/manifest")
        |> HTTP.call(HTTP.init([]))

      json = Jason.decode!(conn.resp_body)
      [seg] = json["segments"]

      assert seg["renditions"]["text"]["url"] == "/v1/streams/#{sid}/segments/0/text"
      refute Map.has_key?(seg["renditions"], "audio")
    end

    test "audio+text disposition includes both renditions and cues" do
      sid = "http-shape-both-#{System.unique_integer([:positive])}"
      :ok = Manifest.init_stream(sid, "conv1", disposition: ["audio", "text"])
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

  describe "GET /v1/rooms" do
    setup do
      # Use unique conversation_ids per test to avoid cross-test pollution
      # in the shared Landscape GenServer.
      test_id = System.unique_integer([:positive])
      {:ok, test_id: test_id}
    end

    test "returns 200 with JSON array of rooms", %{test_id: id} do
      cid = "rooms-test-#{id}"

      GenServer.cast(
        Cranium.Inference.Landscape,
        {:summary_updated, cid, "Main room", ~U[2026-03-18 12:00:00Z]}
      )

      :sys.get_state(Cranium.Inference.Landscape)

      conn =
        Plug.Test.conn(:get, "/v1/rooms")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      rooms = Jason.decode!(conn.resp_body)
      assert is_list(rooms)
      room = Enum.find(rooms, &(&1["id"] == cid))
      assert room["name"] == cid
      assert room["description"] == "Main room"
    end

    test "respects excluded_rooms config", %{test_id: id} do
      included = "rooms-incl-#{id}"
      excluded = "rooms-excl-#{id}"
      original_excluded = Application.get_env(:cranium, :excluded_rooms, [])

      Application.put_env(:cranium, :excluded_rooms, [excluded])

      GenServer.cast(
        Cranium.Inference.Landscape,
        {:summary_updated, included, "Main room", ~U[2026-03-18 12:00:00Z]}
      )

      GenServer.cast(
        Cranium.Inference.Landscape,
        {:summary_updated, excluded, "Ops stuff", ~U[2026-03-18 11:00:00Z]}
      )

      :sys.get_state(Cranium.Inference.Landscape)

      conn =
        Plug.Test.conn(:get, "/v1/rooms")
        |> HTTP.call(HTTP.init([]))

      rooms = Jason.decode!(conn.resp_body)
      ids = Enum.map(rooms, & &1["id"])
      assert included in ids
      refute excluded in ids

      Application.put_env(:cranium, :excluded_rooms, original_excluded)
    end

    test "returns 200 with valid JSON when no test rooms exist" do
      conn =
        Plug.Test.conn(:get, "/v1/rooms")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert is_list(Jason.decode!(conn.resp_body))
    end
  end

  describe "!clear command" do
    test "bare !clear returns command response" do
      cid = "clear-bare-#{System.unique_integer([:positive])}"

      conn =
        Plug.Test.conn(:post, "/v1/submit", %{
          "conversation_id" => cid,
          "text" => "!clear"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["command"] == "clear"
    end

    test "!clear with continuation text returns command response" do
      cid = "clear-cont-#{System.unique_integer([:positive])}"

      conn =
        Plug.Test.conn(:post, "/v1/submit", %{
          "conversation_id" => cid,
          "text" => "!clear hey could you do blah blah blah"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["command"] == "clear"
    end

    test "!clear with continuation stores it on the new epoch" do
      cid = "clear-store-#{System.unique_integer([:positive])}"

      # Create an epoch so clear_epoch has something to clear
      {:ok, _epoch_id} = Cranium.Store.create_epoch(cid)

      conn =
        Plug.Test.conn(:post, "/v1/submit", %{
          "conversation_id" => cid,
          "text" => "!clear pick up where we left off"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200

      # The new epoch should have the continuation stored
      {:ok, epoch} = Cranium.Store.get_epoch(cid)
      assert epoch.continuation == "pick up where we left off"
    end

    test "bare !clear does not store continuation" do
      cid = "clear-nocont-#{System.unique_integer([:positive])}"
      {:ok, _epoch_id} = Cranium.Store.create_epoch(cid)

      conn =
        Plug.Test.conn(:post, "/v1/submit", %{
          "conversation_id" => cid,
          "text" => "!clear"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200

      {:ok, epoch} = Cranium.Store.get_epoch(cid)
      assert epoch.continuation == nil
    end
  end

  describe "POST /v1/clear" do
    test "accepts continuation parameter" do
      cid = "api-clear-cont-#{System.unique_integer([:positive])}"
      {:ok, _epoch_id} = Cranium.Store.create_epoch(cid)

      conn =
        Plug.Test.conn(:post, "/v1/clear", %{
          "conversation_id" => cid,
          "continuation" => "resume the migration work"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "cleared"

      {:ok, epoch} = Cranium.Store.get_epoch(cid)
      assert epoch.continuation == "resume the migration work"
    end

    test "works without continuation" do
      cid = "api-clear-bare-#{System.unique_integer([:positive])}"
      {:ok, _epoch_id} = Cranium.Store.create_epoch(cid)

      conn =
        Plug.Test.conn(:post, "/v1/clear", %{
          "conversation_id" => cid
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200

      {:ok, epoch} = Cranium.Store.get_epoch(cid)
      assert epoch.continuation == nil
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

  describe "input protocol" do
    test "POST /v1/input/start returns take_id and stream_id" do
      conn =
        Plug.Test.conn(:post, "/v1/input/start", %{
          "conversation_id" => "conv-input-1",
          "disposition" => ~s(["audio","text"])
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert is_binary(json["take_id"])
      assert is_binary(json["stream_id"])
    end

    test "POST /v1/input/:id/done for unknown take returns 404" do
      conn =
        Plug.Test.conn(:post, "/v1/input/nonexistent/done", %{"last_seq" => 0})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
    end

    test "POST /v1/input/:id/done with missing last_seq returns 400" do
      conn =
        Plug.Test.conn(:post, "/v1/input/some-id/done", %{})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 400
    end
  end
end
