defmodule Cranium.Config do
  @moduledoc """
  Profile configuration provider.

  Loads `profiles.yaml` from XDG config path (`~/.config/cranium/profiles.yaml`)
  and serves profile lookups. Follows the NixEnv pattern: ETS table for fast
  public reads, GenServer for serialized file I/O.

  ## Profile structure

      default: exo
      ollama_url: http://lordhenry.tail95401.ts.net:11434

      profiles:
        exo:
          backend: claudecode
          model: claude-opus-4-6
          identity: /home/dev/Projects/exocortex/EXO.md
        exo-local:
          backend: ollama
          model: gemma4-cranium
          identity: /home/dev/Projects/exocortex/EXO.md

  Crashes on startup if profiles.yaml is missing or malformed.
  """

  use GenServer
  require Logger

  @table __MODULE__

  defmodule Profile do
    @moduledoc false
    defstruct [
      :name,
      :backend,
      :model,
      :identity_path,
      thinking: nil,
      context_window: nil,
      saturation_warn: nil,
      saturation_critical: nil
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            backend: :claudecode | :anthropic | :ollama,
            model: String.t() | nil,
            identity_path: String.t() | nil,
            thinking: boolean() | nil,
            context_window: pos_integer() | nil,
            saturation_warn: number() | nil,
            saturation_critical: number() | nil
          }
  end

  # --- Public API (ETS reads — no GenServer.call) ---

  @doc "Resolve a profile by name. Returns resolved backend module, model, and identity content."
  @spec resolve_profile(String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolve_profile(name) do
    case :ets.lookup(@table, {:profile, name}) do
      [{_, %Profile{} = profile}] ->
        identity = if profile.identity_path, do: read_identity(profile.identity_path), else: nil

        {:ok,
         %{
           name: profile.name,
           backend_module: backend_module(profile.backend),
           backend: profile.backend,
           model: profile.model,
           identity: identity,
           thinking: profile.thinking,
           context_window: profile.context_window,
           saturation_warn: profile.saturation_warn,
           saturation_critical: profile.saturation_critical
         }}

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Return the default profile name."
  @spec default_profile_name() :: String.t()
  def default_profile_name do
    [{_, name}] = :ets.lookup(@table, :default)
    name
  end

  @doc "Ollama API base URL from config."
  @spec ollama_url() :: String.t()
  def ollama_url do
    case :ets.lookup(@table, :ollama_url) do
      [{_, url}] -> url
      [] -> "http://localhost:11434"
    end
  end

  @doc "Read and cache an identity file by path. Returns content or nil on failure."
  @spec read_identity(String.t()) :: String.t() | nil
  def read_identity(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        case :ets.lookup(@table, {:identity, path}) do
          [{_, ^mtime, content}] ->
            content

          _ ->
            # Serialize file reads through GenServer to avoid duplicate work
            GenServer.call(__MODULE__, {:read_identity, path, mtime}, 10_000)
        end

      {:error, reason} ->
        Logger.warning("Config: cannot stat identity file", path: path, reason: reason)
        nil
    end
  end

  # --- GenServer ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    path = Keyword.get(opts, :path) || config_path()
    load_profiles!(path)

    {:ok, %{path: path}}
  end

  @impl true
  def handle_call({:read_identity, path, mtime}, _from, state) do
    # Double-check inside serialized call
    content =
      case :ets.lookup(@table, {:identity, path}) do
        [{_, ^mtime, cached}] ->
          cached

        _ ->
          case File.read(path) do
            {:ok, content} ->
              :ets.insert(@table, {{:identity, path}, mtime, content})
              Logger.info("Config: identity cached", path: path, size: byte_size(content))
              content

            {:error, reason} ->
              Logger.warning("Config: failed to read identity", path: path, reason: reason)
              nil
          end
      end

    {:reply, content, state}
  end

  # --- Private ---

  defp config_path do
    Application.get_env(:cranium, :profiles_path) ||
      Path.join(
        System.get_env("XDG_CONFIG_HOME", Path.expand("~/.config")),
        "cranium/profiles.yaml"
      )
  end

  defp load_profiles!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} ->
        validate_and_store!(yaml, path)

      {:error, reason} ->
        raise "Cranium.Config: failed to load profiles from #{path}: #{inspect(reason)}"
    end
  end

  defp validate_and_store!(yaml, path) do
    profiles_raw = yaml["profiles"] || raise "Cranium.Config: no 'profiles' key in #{path}"

    unless is_map(profiles_raw) and map_size(profiles_raw) > 0 do
      raise "Cranium.Config: 'profiles' must be a non-empty map in #{path}"
    end

    profiles =
      for {name, config} <- profiles_raw, into: %{} do
        backend =
          case config["backend"] do
            "claudecode" -> :claudecode
            "anthropic" -> :anthropic
            "ollama" -> :ollama
            "mock" -> :mock
            other -> raise "Cranium.Config: unknown backend '#{other}' for profile '#{name}'"
          end

        thinking =
          case config["thinking"] do
            v when is_boolean(v) -> v
            _ -> nil
          end

        profile = %Profile{
          name: name,
          backend: backend,
          model: config["model"],
          identity_path: config["identity"],
          thinking: thinking,
          context_window: config["context_window"],
          saturation_warn: config["saturation_warn"],
          saturation_critical: config["saturation_critical"]
        }

        :ets.insert(@table, {{:profile, name}, profile})
        {name, profile}
      end

    # Default: explicit key, or first profile
    default_name = yaml["default"] || profiles |> Map.keys() |> Enum.sort() |> hd()
    :ets.insert(@table, {:default, default_name})

    unless Map.has_key?(profiles, default_name) do
      raise "Cranium.Config: default profile '#{default_name}' not found in profiles"
    end

    # Ollama URL
    if url = yaml["ollama_url"] do
      :ets.insert(@table, {:ollama_url, url})
    end

    Logger.info("Config: loaded #{map_size(profiles)} profiles (default: #{default_name})")
  end

  defp backend_module(:claudecode), do: Cranium.Backend.LLM.ClaudeCode
  defp backend_module(:anthropic), do: Cranium.Backend.LLM.Anthropic
  defp backend_module(:ollama), do: Cranium.Backend.LLM.Ollama
  # Dynamic construction avoids compile-time xref warning — Mock only exists in test env.
  defp backend_module(:mock), do: Module.concat([Cranium.Backend.LLM, Mock])
end
