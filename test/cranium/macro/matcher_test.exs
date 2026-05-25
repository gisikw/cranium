defmodule Cranium.Macro.MatcherTest do
  use ExUnit.Case, async: true

  alias Cranium.Macro.Matcher

  describe "compile_pattern/1 literals" do
    test "simple word matches case-insensitively" do
      assert {:ok, regex} = Matcher.compile_pattern("kubernetes")
      assert Regex.match?(regex, "I love Kubernetes")
      assert Regex.match?(regex, "KUBERNETES is great")
      assert Regex.match?(regex, "kubernetes")
    end

    test "word boundary prevents partial matches" do
      assert {:ok, regex} = Matcher.compile_pattern("kube")
      refute Regex.match?(regex, "kubernetes")
      assert Regex.match?(regex, "kube is short")
    end

    test "hyphens and spaces are interchangeable" do
      assert {:ok, regex} = Matcher.compile_pattern("ship it")
      assert Regex.match?(regex, "let's ship it now")
      assert Regex.match?(regex, "let's ship-it now")

      assert {:ok, regex2} = Matcher.compile_pattern("self-report")
      assert Regex.match?(regex2, "use self-report")
      assert Regex.match?(regex2, "use self report")
    end

    test "special regex characters in literal are escaped" do
      assert {:ok, regex} = Matcher.compile_pattern("what?")
      assert Regex.match?(regex, "say what?")
      refute Regex.match?(regex, "say wha")
    end
  end

  describe "compile_pattern/1 regex" do
    test "regex pattern compiled raw" do
      assert {:ok, regex} = Matcher.compile_pattern("/kube[-\\s]?cluster/")
      assert Regex.match?(regex, "the kube-cluster is up")
      assert Regex.match?(regex, "the kube cluster is up")
      assert Regex.match?(regex, "the kubecluster is up")
    end

    test "invalid regex returns error" do
      assert {:error, msg} = Matcher.compile_pattern("/[invalid/")
      assert msg =~ "invalid regex"
    end

    test "single slash is treated as literal" do
      assert {:ok, regex} = Matcher.compile_pattern("/path")
      # Treated as literal — should not be regex
      refute Regex.match?(regex, "the path is set")
    end
  end

  describe "compile_patterns/1" do
    test "compiles a list of patterns" do
      assert {:ok, compiled} = Matcher.compile_patterns(["kubernetes", "k8s"])
      assert length(compiled) == 2
    end

    test "stops on first error" do
      assert {:error, _} = Matcher.compile_patterns(["ok", "/[bad/"])
    end
  end

  describe "match?/2" do
    test "returns true when any pattern matches" do
      {:ok, compiled} = Matcher.compile_patterns(["kubernetes", "k8s"])
      assert Matcher.match?("tell me about k8s", compiled)
      assert Matcher.match?("tell me about kubernetes", compiled)
    end

    test "returns false when no pattern matches" do
      {:ok, compiled} = Matcher.compile_patterns(["kubernetes", "k8s"])
      refute Matcher.match?("tell me about docker", compiled)
    end

    test "works with mixed literal and regex patterns" do
      {:ok, compiled} = Matcher.compile_patterns(["kubernetes", "/kube[-\\s]?cluster/"])
      assert Matcher.match?("the kube-cluster is running", compiled)
      assert Matcher.match?("kubernetes is great", compiled)
      refute Matcher.match?("docker is fine", compiled)
    end

    test "empty pattern list never matches" do
      {:ok, compiled} = Matcher.compile_patterns([])
      refute Matcher.match?("anything", compiled)
    end
  end
end
