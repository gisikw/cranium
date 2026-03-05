defmodule Cranium.Agent.MarkerEmitterTest do
  use ExUnit.Case, async: true

  alias Cranium.Agent.MarkerEmitter

  describe "handle/2" do
    test "returns fake success and marker for :show" do
      {response, marker} = MarkerEmitter.handle(:show, %{url: "image.png"})

      assert response == ~s({"success": true})
      assert marker.type == :marker
      assert marker.marker == :show
      assert marker.payload == %{url: "image.png"}
    end

    test "returns fake success and marker for :show_code" do
      {response, marker} =
        MarkerEmitter.handle(:show_code, %{language: "elixir", code: "IO.puts(1)"})

      assert response == ~s({"success": true})
      assert marker.marker == :show_code
      assert marker.payload.language == "elixir"
    end

    test "returns fake success and marker for :play_audio" do
      {response, marker} = MarkerEmitter.handle(:play_audio, %{url: "clip.mp3"})

      assert response == ~s({"success": true})
      assert marker.marker == :play_audio
    end
  end
end
