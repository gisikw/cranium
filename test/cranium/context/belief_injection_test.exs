defmodule Cranium.Context.BeliefInjectionTest do
  use ExUnit.Case, async: true

  alias Cranium.Context.BeliefInjection

  defp entry(id, statement \\ nil) do
    statement = statement || "Belief #{id} statement"
    %{id: id, line: "[#{id}] #{statement} (0.80)"}
  end

  defp snapshot(pinned_ids, surfaced_ids) do
    %{pinned: Enum.map(pinned_ids, &entry/1), surfaced: Enum.map(surfaced_ids, &entry/1)}
  end

  describe "session start" do
    test "injects pinned + surfaced as one block" do
      snap = snapshot(["B-1", "B-2"], ["B-3"])

      assert {:inject, meta} = BeliefInjection.decide(snap, %{is_fresh: true})
      assert meta.kind == :session_start
      assert meta.ids == ["B-1", "B-2", "B-3"]
      assert meta.dropped == 0
      assert meta.tokens > 0
      assert meta.block =~ "<system-reminder>"
      assert meta.block =~ ~s(<beliefs pinned="2" surfaced="1">)
      assert meta.block =~ "[B-1]"
      assert meta.block =~ "---"
      assert meta.block =~ "[B-3]"
    end

    test "empty snapshot skips" do
      assert :skip = BeliefInjection.decide(%{pinned: [], surfaced: []}, %{is_fresh: true})
    end

    test "pinned-only block has no separator" do
      assert {:inject, meta} = BeliefInjection.decide(snapshot(["B-1"], []), %{is_fresh: true})
      refute meta.block =~ "---"
    end
  end

  describe "mid-session delta" do
    test "same ids skip" do
      snap = snapshot(["B-1"], ["B-2"])

      assert :skip =
               BeliefInjection.decide(snap, %{is_fresh: false, last_belief_ids: ["B-1", "B-2"]})
    end

    test "belief entering the band triggers reinjection" do
      snap = snapshot(["B-1"], ["B-2", "B-9"])

      assert {:inject, %{kind: :delta}} =
               BeliefInjection.decide(snap, %{is_fresh: false, last_belief_ids: ["B-1", "B-2"]})
    end

    test "belief leaving the band triggers reinjection" do
      snap = snapshot(["B-1"], [])

      assert {:inject, %{kind: :delta, ids: ["B-1"]}} =
               BeliefInjection.decide(snap, %{is_fresh: false, last_belief_ids: ["B-1", "B-2"]})
    end

    test "first bridge appearance mid-session injects (nil last ids)" do
      snap = snapshot(["B-1"], [])

      assert {:inject, %{kind: :delta}} =
               BeliefInjection.decide(snap, %{is_fresh: false, last_belief_ids: nil})
    end
  end

  describe "budget enforcement" do
    test "drops the surfaced tail when over budget, pinned first" do
      # ~15 tokens per line; frame overhead 40. Budget of 80 tokens fits
      # the frame plus roughly two entries.
      long = String.duplicate("verbose statement ", 3)

      snap = %{
        pinned: [entry("B-p1", long), entry("B-p2", long)],
        surfaced: [entry("B-s1", long), entry("B-s2", long), entry("B-s3", long)]
      }

      assert {:inject, meta} =
               BeliefInjection.decide(snap, %{
                 is_fresh: true,
                 context_window: 2400,
                 budget_fraction: 0.05
               })

      # 2400 * 0.05 = 120 token budget — not enough for all five entries.
      assert meta.dropped > 0
      assert meta.tokens <= 120
      # The kept set is a prefix of pinned-then-surfaced: the drop comes
      # out of the surfaced tail, never out of the pinned set.
      full_order = ["B-p1", "B-p2", "B-s1", "B-s2", "B-s3"]
      assert meta.ids == Enum.take(full_order, length(meta.ids))
      assert "B-p1" in meta.ids
    end

    test "under budget keeps everything" do
      snap = snapshot(["B-1"], ["B-2"])

      assert {:inject, %{dropped: 0, ids: ["B-1", "B-2"]}} =
               BeliefInjection.decide(snap, %{is_fresh: true, context_window: 200_000})
    end

    test "default ceiling is 5% of a 200k window" do
      # A block of ~600 one-line beliefs (~10k tokens) exceeds nothing at
      # the 10k default budget only if it fits; verify enforcement kicks in
      # for an absurdly large band.
      surfaced = Enum.map(1..2000, fn i -> entry("B-#{i}") end)
      snap = %{pinned: [], surfaced: surfaced}

      assert {:inject, meta} = BeliefInjection.decide(snap, %{is_fresh: true})
      assert meta.tokens <= 10_000
      assert meta.dropped > 0
    end
  end
end
