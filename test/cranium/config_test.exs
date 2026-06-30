defmodule Cranium.ConfigTest do
  use ExUnit.Case, async: false

  alias Cranium.Config

  describe "resolve_profile/1" do
    test "resolves a known profile" do
      assert {:ok, resolved} = Config.resolve_profile("test")
      assert resolved.name == "test"
      assert resolved.backend == :mock
      assert resolved.backend_module == Cranium.Backend.LLM.Mock
      assert resolved.model == "test-model"
      assert resolved.identity == nil
    end


    test "resolves tiamat router profile" do
      assert {:ok, resolved} = Config.resolve_profile("test-tiamat")
      assert resolved.backend == :tiamat
      assert resolved.backend_module == Cranium.Backend.LLM.Tiamat
      assert resolved.model == nil
      assert resolved.router_profile == "exo"

      assert resolved.backend_config == %{
               "endpoint" => "http://localhost:4002",
               "timeout" => 300_000
             }

      assert resolved.identity == "You are a test identity."
    end

    test "returns error for unknown profile" do
      assert {:error, :not_found} = Config.resolve_profile("nonexistent")
    end

    test "resolves identity content from file" do
      assert {:ok, resolved} = Config.resolve_profile("test-with-identity")
      assert resolved.identity == "You are a test identity."
    end

    test "resolves identity from list of files" do
      assert {:ok, resolved} = Config.resolve_profile("test-identity-list")
      assert resolved.identity == "You are a test identity.\n\nYou have a second identity layer."
    end

    test "resolves tools_prompt flag" do
      assert {:ok, resolved} = Config.resolve_profile("test-tools-prompt")
      assert resolved.tools_prompt == true
    end

    test "tools_prompt defaults to false" do
      assert {:ok, resolved} = Config.resolve_profile("test")
      assert resolved.tools_prompt == false
    end
  end

  describe "default_profile_name/0" do
    test "returns the configured default" do
      assert Config.default_profile_name() == "test"
    end
  end

  describe "ollama_url/0" do
    test "returns the configured URL" do
      assert Config.ollama_url() == "http://localhost:11434"
    end
  end

  describe "list_profiles/0" do
    test "returns all profile names sorted" do
      profiles = Config.list_profiles()
      assert is_list(profiles)
      assert "test" in profiles
      assert "test" in profiles
      assert "test-tiamat" in profiles
      assert profiles == Enum.sort(profiles)
    end
  end

  describe "openai_system_mode" do
    test "defaults to :replace when not specified" do
      {:ok, resolved} = Config.resolve_profile("test")
      assert resolved.openai_system_mode == :replace
    end

    test "parses prepend mode" do
      {:ok, resolved} = Config.resolve_profile("test-prepend")
      assert resolved.openai_system_mode == :prepend
    end

    test "parses append mode" do
      {:ok, resolved} = Config.resolve_profile("test-append")
      assert resolved.openai_system_mode == :append
    end
  end

  describe "plugins" do
    test "parses plugin declarations from profile" do
      {:ok, resolved} = Config.resolve_profile("test-with-plugins")
      assert length(resolved.plugins) == 2

      [echo, skipper] = resolved.plugins
      assert echo.module == Cranium.TestPlugins.Echo
      assert echo.config == nil
      assert skipper.module == Cranium.TestPlugins.Skipper
      assert skipper.config == %{"threshold" => 3}
    end

    test "defaults to empty list when no plugins declared" do
      {:ok, resolved} = Config.resolve_profile("test")
      assert resolved.plugins == []
    end
  end

  describe "tool_posture" do
    test "defaults to :sandbox when not specified" do
      {:ok, resolved} = Config.resolve_profile("test")
      assert resolved.tool_posture == :sandbox
      assert resolved.tool_rw == []
      assert resolved.tool_ro == []
    end

    test "parses permissive posture" do
      {:ok, resolved} = Config.resolve_profile("test-permissive")
      assert resolved.tool_posture == :permissive
    end

    test "parses rw and ro grants" do
      {:ok, resolved} = Config.resolve_profile("test-sandbox-grants")
      assert resolved.tool_posture == :sandbox
      assert resolved.tool_rw == ["/home/dev/Projects/hoard"]
      assert resolved.tool_ro == ["/var/log"]
    end
  end

  describe "room_default_profile/1" do
    test "returns profile for configured room" do
      assert Config.room_default_profile("personal-chat") == "test-with-identity"
    end

    test "returns nil for unconfigured room" do
      assert Config.room_default_profile("unknown-room") == nil
    end
  end

  describe "read_identity/1" do
    test "reads and caches identity file" do
      path = Path.join(File.cwd!(), "test/fixtures/test-identity.txt")
      assert Config.read_identity(path) == "You are a test identity."

      # Second call should return cached (same result)
      assert Config.read_identity(path) == "You are a test identity."
    end

    test "returns nil for nonexistent file" do
      assert Config.read_identity("/tmp/nonexistent-identity-#{:rand.uniform(999_999)}.txt") ==
               nil
    end
  end
end
