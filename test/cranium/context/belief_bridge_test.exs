defmodule Cranium.Context.BeliefBridgeTest do
  use ExUnit.Case, async: true

  alias Cranium.Context.BeliefBridge

  @bridge_output """
  <gee mode="task" surfaced="1" active="5" beliefs="14" pinned="2">
  Meeting with Zayna [0.82]
  <beliefs pinned="2" surfaced="2">
  [B-003] Directness > diplomacy in code review (0.95)
  [B-007] Receipts beat vibes (0.90)
  ---
  [B-042] Shipping beats polishing (0.50, contested)
  [B-051] Naps are load-bearing (0.62, stale)
  </beliefs>
  </gee>
  """

  describe "parse/1" do
    test "splits pinned and surfaced by the element's pinned count" do
      %{pinned: pinned, surfaced: surfaced} = BeliefBridge.parse(@bridge_output)

      assert Enum.map(pinned, & &1.id) == ["B-003", "B-007"]
      assert Enum.map(surfaced, & &1.id) == ["B-042", "B-051"]
      assert hd(surfaced).line == "[B-042] Shipping beats polishing (0.50, contested)"
    end

    test "handles pinned-only block (no separator)" do
      content = """
      <gee mode="task" surfaced="0" active="0" beliefs="1" pinned="1">
      <beliefs pinned="1" surfaced="0">
      [B-001] One belief (0.80)
      </beliefs>
      </gee>
      """

      assert %{pinned: [%{id: "B-001"}], surfaced: []} = BeliefBridge.parse(content)
    end

    test "handles surfaced-only block (no separator)" do
      content = """
      <beliefs pinned="0" surfaced="1">
      [B-002] Another belief (0.70)
      </beliefs>
      """

      assert %{pinned: [], surfaced: [%{id: "B-002"}]} = BeliefBridge.parse(content)
    end

    test "no beliefs element yields empty snapshot" do
      content = """
      <gee mode="task" surfaced="1" active="5" beliefs="0" pinned="0">
      Meeting with Zayna [0.82]
      </gee>
      """

      assert %{pinned: [], surfaced: []} = BeliefBridge.parse(content)
    end

    test "garbage degrades to empty snapshot" do
      assert %{pinned: [], surfaced: []} = BeliefBridge.parse("not xml at all")
      assert %{pinned: [], surfaced: []} = BeliefBridge.parse("<beliefs busted")
    end

    test "lines without a belief id are skipped" do
      content = """
      <beliefs pinned="0" surfaced="2">
      [B-001] Real entry (0.80)
      stray line without an id
      </beliefs>
      """

      assert %{pinned: [], surfaced: [%{id: "B-001"}]} = BeliefBridge.parse(content)
    end
  end

  describe "read_snapshot/2" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "belief_bridge_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads a fresh artifact", %{dir: dir} do
      path = Path.join(dir, "bridge.txt")
      File.write!(path, @bridge_output)

      assert {:ok, %{pinned: [_, _], surfaced: [_, _]}} =
               BeliefBridge.read_snapshot(path, DateTime.utc_now())
    end

    test "missing artifact", %{dir: dir} do
      assert {:error, :missing} =
               BeliefBridge.read_snapshot(Path.join(dir, "nope.txt"), DateTime.utc_now())
    end

    test "stale artifact (mtime older than 2h)", %{dir: dir} do
      path = Path.join(dir, "bridge.txt")
      File.write!(path, @bridge_output)

      future = DateTime.add(DateTime.utc_now(), 3 * 60 * 60, :second)
      assert {:error, :stale} = BeliefBridge.read_snapshot(path, future)
    end

    test "artifact with no beliefs", %{dir: dir} do
      path = Path.join(dir, "bridge.txt")

      File.write!(
        path,
        "<gee mode=\"task\" surfaced=\"0\" active=\"0\" beliefs=\"0\" pinned=\"0\">\n</gee>\n"
      )

      assert {:error, :empty} = BeliefBridge.read_snapshot(path, DateTime.utc_now())
    end
  end
end
