defmodule Cranium.Transport.AudioTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Mox

  alias Cranium.Transport.HTTP

  setup :set_mox_global
  setup :verify_on_exit!

  # --- POST /v1/audio/speech ---

  describe "POST /v1/audio/speech" do
    test "synthesizes audio and returns raw bytes" do
      audio_bytes = <<0xFF, 0xFB, 0x90, 0x00>>

      expect(Cranium.Backend.TTS.Mock, :synthesize, fn text, opts ->
        assert text == "Hello world"
        assert Keyword.get(opts, :format) == "mp3"
        {:ok, audio_bytes}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test",
          "input" => "Hello world"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert {"content-type", "audio/mpeg; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body == audio_bytes
    end

    test "uses profile audio config for voice and speed" do
      expect(Cranium.Backend.TTS.Mock, :synthesize, fn _text, opts ->
        assert Keyword.get(opts, :voice) == "af_heart"
        assert Keyword.get(opts, :speed) == 0.9
        assert Keyword.get(opts, :format) == "wav"
        assert Keyword.get(opts, :url) == "http://localhost:8800/v1/audio/speech"
        {:ok, "audio"}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test-audio",
          "input" => "Hello"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert {"content-type", "audio/wav; charset=utf-8"} in conn.resp_headers
    end

    test "per-request params override profile config" do
      expect(Cranium.Backend.TTS.Mock, :synthesize, fn _text, opts ->
        assert Keyword.get(opts, :voice) == "af_sky"
        assert Keyword.get(opts, :speed) == 1.2
        assert Keyword.get(opts, :format) == "opus"
        {:ok, "audio"}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test-audio",
          "input" => "Hello",
          "voice" => "af_sky",
          "speed" => 1.2,
          "response_format" => "opus"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert {"content-type", "audio/opus; charset=utf-8"} in conn.resp_headers
    end

    test "returns 400 when input is missing" do
      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 400
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "missing required field: input"
    end

    test "returns 400 when input is empty" do
      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test",
          "input" => ""
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 400
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "missing required field: input"
    end

    test "returns 400 when input exceeds max length" do
      long_input = String.duplicate("a", 4097)

      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test",
          "input" => long_input
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 400
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "exceeds maximum length"
    end

    test "returns 404 for unknown model" do
      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "nonexistent",
          "input" => "Hello"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "not found"
    end

    test "returns 502 when TTS backend fails" do
      expect(Cranium.Backend.TTS.Mock, :synthesize, fn _text, _opts ->
        {:error, {:http_error, 500, "internal error"}}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test",
          "input" => "Hello"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 502
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "TTS synthesis failed"
    end

    test "profile without audio config uses defaults" do
      expect(Cranium.Backend.TTS.Mock, :synthesize, fn _text, opts ->
        # No voice/speed/url overrides from profile
        refute Keyword.has_key?(opts, :voice)
        refute Keyword.has_key?(opts, :speed)
        refute Keyword.has_key?(opts, :url)
        assert Keyword.get(opts, :format) == "mp3"
        {:ok, "audio"}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/speech", %{
          "model" => "test",
          "input" => "Hello"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
    end
  end

  # --- POST /v1/audio/transcriptions ---

  describe "POST /v1/audio/transcriptions" do
    test "transcribes audio and returns JSON" do
      expect(Cranium.Backend.STT.Mock, :transcribe, fn audio, _opts ->
        assert byte_size(audio) > 0
        {:ok, "Hello world"}
      end)

      audio_content = "fake audio content"

      conn =
        Plug.Test.conn(:post, "/v1/audio/transcriptions", %{
          "model" => "test",
          "file" => %Plug.Upload{
            path: write_tmp_file(audio_content),
            filename: "audio.mp3",
            content_type: "audio/mpeg"
          }
        })
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert json["text"] == "Hello world"
    end

    test "uses profile audio config for language and URL" do
      expect(Cranium.Backend.STT.Mock, :transcribe, fn _audio, opts ->
        assert Keyword.get(opts, :language) == "en"
        assert Keyword.get(opts, :url) == "http://localhost:8801/v1/audio/transcriptions"
        {:ok, "Transcribed text"}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/transcriptions", %{
          "model" => "test-audio",
          "file" => %Plug.Upload{
            path: write_tmp_file("audio"),
            filename: "audio.mp3",
            content_type: "audio/mpeg"
          }
        })
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
    end

    test "per-request language overrides profile config" do
      expect(Cranium.Backend.STT.Mock, :transcribe, fn _audio, opts ->
        assert Keyword.get(opts, :language) == "fr"
        {:ok, "Bonjour"}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/transcriptions", %{
          "model" => "test-audio",
          "language" => "fr",
          "file" => %Plug.Upload{
            path: write_tmp_file("audio"),
            filename: "audio.mp3",
            content_type: "audio/mpeg"
          }
        })
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert json["text"] == "Bonjour"
    end

    test "returns 400 when file is missing" do
      conn =
        Plug.Test.conn(:post, "/v1/audio/transcriptions", %{
          "model" => "test"
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 400
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "missing required field: file"
    end

    test "returns 404 for unknown model" do
      conn =
        Plug.Test.conn(:post, "/v1/audio/transcriptions", %{
          "model" => "nonexistent",
          "file" => %Plug.Upload{
            path: write_tmp_file("audio"),
            filename: "audio.mp3",
            content_type: "audio/mpeg"
          }
        })
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "not found"
    end

    test "returns 502 when STT backend fails" do
      expect(Cranium.Backend.STT.Mock, :transcribe, fn _audio, _opts ->
        {:error, {:http_error, 500, "internal error"}}
      end)

      conn =
        Plug.Test.conn(:post, "/v1/audio/transcriptions", %{
          "model" => "test",
          "file" => %Plug.Upload{
            path: write_tmp_file("audio"),
            filename: "audio.mp3",
            content_type: "audio/mpeg"
          }
        })
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 502
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "transcription failed"
    end
  end

  # --- Profile audio config resolution ---

  describe "profile audio config" do
    test "resolve_profile includes audio fields" do
      {:ok, profile} = Cranium.Config.resolve_profile("test-audio")
      assert profile.voice == "af_heart"
      assert profile.speed == 0.9
      assert profile.response_format == "wav"
      assert profile.tts_url == "http://localhost:8800/v1/audio/speech"
      assert profile.stt_url == "http://localhost:8801/v1/audio/transcriptions"
      assert profile.stt_language == "en"
    end

    test "profile without audio config has nil audio fields" do
      {:ok, profile} = Cranium.Config.resolve_profile("test")
      assert profile.voice == nil
      assert profile.speed == nil
      assert profile.response_format == nil
      assert profile.tts_url == nil
      assert profile.stt_url == nil
      assert profile.stt_language == nil
    end
  end

  # --- Helpers ---

  defp write_tmp_file(content) do
    path = Path.join(System.tmp_dir!(), "cranium_test_#{:rand.uniform(999_999)}")
    File.write!(path, content)
    path
  end
end
