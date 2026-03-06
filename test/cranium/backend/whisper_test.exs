defmodule Cranium.Backend.WhisperTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.STT.Whisper

  @plug_name CraniumWhisperTest

  describe "transcribe/2" do
    test "returns {:ok, text} on HTTP 200 with text" do
      Req.Test.stub(@plug_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"text" => "hello world"}))
      end)

      assert {:ok, "hello world"} = Whisper.transcribe(<<1, 2, 3>>, plug: {Req.Test, @plug_name})
    end

    test "trims whitespace from transcription" do
      Req.Test.stub(@plug_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"text" => "  hello world  \n"}))
      end)

      assert {:ok, "hello world"} = Whisper.transcribe(<<1, 2, 3>>, plug: {Req.Test, @plug_name})
    end

    test "returns {:error, {:stt_error, reason}} when response contains error field" do
      Req.Test.stub(@plug_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"error" => "unsupported format"}))
      end)

      assert {:error, {:stt_error, "unsupported format"}} =
               Whisper.transcribe(<<1, 2, 3>>, plug: {Req.Test, @plug_name})
    end

    test "returns {:error, {:http_error, 503, _}} on non-200" do
      Req.Test.stub(@plug_name, fn conn ->
        Plug.Conn.send_resp(conn, 503, "Service Unavailable")
      end)

      assert {:error, {:http_error, 503, _}} =
               Whisper.transcribe(<<1, 2, 3>>, plug: {Req.Test, @plug_name})
    end

    test "returns {:error, _} on connection error" do
      Req.Test.stub(@plug_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _} = Whisper.transcribe(<<1, 2, 3>>, plug: {Req.Test, @plug_name})
    end
  end
end
