defmodule Cranium.DispatchTest do
  use ExUnit.Case, async: true

  alias Cranium.Dispatch

  describe "from_submit/1" do
    test "preserves Tiamat router metadata" do
      dispatch =
        Dispatch.from_submit(%{
          conversation_id: "cranium",
          harness: "tiamat",
          router_profile: "exo",
          disposition: ["text"],
          ephemeral: false
        })

      assert dispatch.conversation_id == "cranium"
      assert dispatch.harness == :tiamat
      assert dispatch.model == nil
      assert dispatch.router_profile == "exo"
      assert dispatch.renditions == [:text]
      refute dispatch.ephemeral
    end
  end
end
