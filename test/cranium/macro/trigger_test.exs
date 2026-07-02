defmodule Cranium.Macro.TriggerTest do
  use ExUnit.Case, async: true

  alias Cranium.Macro.{Definition, Trigger}

  # --- Helpers ---

  defp make_macro(overrides \\ %{}) do
    base = %Definition{
      name: "test-macro",
      description: "test",
      trigger: :match,
      match_config: %{patterns: ["kubernetes"], once: false},
      advertising: :hidden,
      lifecycle: :turn,
      learning: :none,
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "test", tag: nil, priority: nil}
    }

    struct!(base, Map.to_list(overrides))
  end

  # --- Trigger type evaluation ---

  describe "evaluate/3 trigger types" do
    test "match trigger fires on keyword" do
      macro = make_macro(%{name: "k8s-glossary"})
      result = Trigger.evaluate([macro], "tell me about kubernetes")

      assert [%{name: "k8s-glossary"}] = result.firing
    end

    test "match trigger does not fire when no match" do
      macro = make_macro(%{name: "k8s-glossary"})
      result = Trigger.evaluate([macro], "tell me about docker")

      assert result.firing == []
    end

    test "ambient trigger always fires" do
      macro = make_macro(%{name: "time-gap", trigger: :ambient, match_config: nil})
      result = Trigger.evaluate([macro], "anything at all")

      assert [%{name: "time-gap"}] = result.firing
    end

    test "explicit trigger is skipped" do
      macro = make_macro(%{name: "greeting", trigger: :explicit, match_config: nil})
      result = Trigger.evaluate([macro], "hello")

      assert result.firing == []
    end

    test "passive trigger is skipped" do
      macro = make_macro(%{name: "pipeline-step", trigger: :passive, match_config: nil})
      result = Trigger.evaluate([macro], "anything")

      assert result.firing == []
    end
  end

  # --- Once flag ---

  describe "evaluate/3 once flag" do
    test "once=true fires on first match" do
      macro =
        make_macro(%{
          name: "k8s-glossary",
          match_config: %{patterns: ["kubernetes"], once: true},
          version: 1
        })

      result = Trigger.evaluate([macro], "tell me about kubernetes")
      assert [%{name: "k8s-glossary"}] = result.firing
      assert MapSet.member?(result.seen, "k8s-glossary")
    end

    test "once=true does not fire again after seen" do
      macro =
        make_macro(%{
          name: "k8s-glossary",
          match_config: %{patterns: ["kubernetes"], once: true},
          version: 1
        })

      seen = MapSet.new(["k8s-glossary"])

      result =
        Trigger.evaluate([macro], "more about kubernetes", %{
          seen: seen,
          versions: %{"k8s-glossary" => 1}
        })

      assert result.firing == []
    end

    test "once=true resets on version change" do
      macro =
        make_macro(%{
          name: "k8s-glossary",
          match_config: %{patterns: ["kubernetes"], once: true},
          version: 2
        })

      seen = MapSet.new(["k8s-glossary"])

      result =
        Trigger.evaluate([macro], "kubernetes again", %{
          seen: seen,
          versions: %{"k8s-glossary" => 1}
        })

      assert [%{name: "k8s-glossary"}] = result.firing
    end

    test "once=false fires every time" do
      macro =
        make_macro(%{
          name: "counter",
          match_config: %{patterns: ["count"], once: false}
        })

      r1 = Trigger.evaluate([macro], "count this")
      assert [%{name: "counter"}] = r1.firing

      r2 = Trigger.evaluate([macro], "count that", %{seen: r1.seen})
      assert [%{name: "counter"}] = r2.firing
    end
  end

  # --- Multiple macros ---

  describe "evaluate/3 multiple macros" do
    test "multiple macros can fire on same message" do
      m1 = make_macro(%{name: "k8s", match_config: %{patterns: ["kubernetes"], once: false}})
      m2 = make_macro(%{name: "infra", trigger: :ambient, match_config: nil})

      result = Trigger.evaluate([m1, m2], "tell me about kubernetes")

      names = Enum.map(result.firing, & &1.name)
      assert "k8s" in names
      assert "infra" in names
    end

    test "only matching macros fire" do
      m1 = make_macro(%{name: "k8s", match_config: %{patterns: ["kubernetes"], once: false}})
      m2 = make_macro(%{name: "docker", match_config: %{patterns: ["docker"], once: false}})

      result = Trigger.evaluate([m1, m2], "tell me about kubernetes")

      assert [%{name: "k8s"}] = result.firing
    end
  end

  # --- Regex patterns ---

  describe "evaluate/3 regex patterns" do
    test "regex pattern in match_config works" do
      macro =
        make_macro(%{
          name: "kube-cluster",
          match_config: %{patterns: ["/kube[-\\s]?cluster/"], once: false}
        })

      assert [_] = Trigger.evaluate([macro], "the kube-cluster is up").firing
      assert [_] = Trigger.evaluate([macro], "the kube cluster works").firing
      assert [_] = Trigger.evaluate([macro], "the kubecluster runs").firing
      assert [] = Trigger.evaluate([macro], "just kubernetes").firing
    end

    test "mixed literal and regex patterns" do
      macro =
        make_macro(%{
          name: "k8s-glossary",
          match_config: %{patterns: ["kubernetes", "k8s", "/kube[-\\s]?cluster/"], once: false}
        })

      assert [_] = Trigger.evaluate([macro], "kubernetes is cool").firing
      assert [_] = Trigger.evaluate([macro], "k8s rocks").firing
      assert [_] = Trigger.evaluate([macro], "kube-cluster status").firing
      assert [] = Trigger.evaluate([macro], "docker runs fine").firing
    end
  end

  # --- Discoverable advertising ---

  describe "evaluate/3 discoverable keywords" do
    test "discoverable macro advertised on keyword match" do
      macro =
        make_macro(%{
          name: "deploy",
          trigger: :explicit,
          match_config: nil,
          advertising: :discoverable,
          discoverable_config: %{keywords: ["deploy", "deployment"]}
        })

      result = Trigger.evaluate([macro], "how do I deploy?")

      # Explicit trigger — not in firing
      assert result.firing == []
      # But discovered via keyword
      assert [%{name: "deploy"}] = result.discovered
      assert MapSet.member?(result.discovered_set, "deploy")
    end

    test "already-discovered macro not re-announced" do
      macro =
        make_macro(%{
          name: "deploy",
          trigger: :explicit,
          match_config: nil,
          advertising: :discoverable,
          discoverable_config: %{keywords: ["deploy"]}
        })

      discovered = MapSet.new(["deploy"])
      result = Trigger.evaluate([macro], "deploy again", %{discovered: discovered})

      assert result.discovered == []
    end

    test "non-discoverable macros not in discovered" do
      macro = make_macro(%{name: "hidden-thing", advertising: :hidden})
      result = Trigger.evaluate([macro], "anything")

      assert result.discovered == []
    end
  end

  # --- Edge cases ---

  describe "evaluate/3 edge cases" do
    test "empty macro list returns empty results" do
      result = Trigger.evaluate([], "hello")
      assert result.firing == []
      assert result.discovered == []
    end

    test "empty message text" do
      macro = make_macro()
      result = Trigger.evaluate([macro], "")
      assert result.firing == []
    end

    test "preserves firing order" do
      m1 = make_macro(%{name: "alpha", trigger: :ambient, match_config: nil})
      m2 = make_macro(%{name: "beta", trigger: :ambient, match_config: nil})
      m3 = make_macro(%{name: "gamma", trigger: :ambient, match_config: nil})

      result = Trigger.evaluate([m1, m2, m3], "anything")
      names = Enum.map(result.firing, & &1.name)
      assert names == ["alpha", "beta", "gamma"]
    end
  end
end
