defmodule Cranium.Config do
  @moduledoc """
  Profile configuration provider.

  Loads `profiles.yaml` from XDG config path (`~/.config/cranium/profiles.yaml`)
  and serves profile lookups. Follows the NixEnv pattern: ETS table for fast
  public reads, GenServer for serialized file I/O.

  ## Profile structure

      default: exo
      profiles:
        exo:
          backend: tiamat
          router_profile: exo
          identity: /home/dev/Projects/exocortex/EXO.md
        sidecar:
          backend: tiamat
          router_profile: qwen-local

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
      identity_paths: [],
      tools_prompt: false,
      thinking: nil,
      router_profile: nil,
      context_window: nil,
      saturation_warn: nil,
      saturation_critical: nil,
      openai_system_mode: :replace,
      private: false,
      backend_config: %{},
      plugins: [],
      tool_posture: :sandbox,
      tool_rw: [],
      tool_ro: [],
      # Audio config (optional — profiles without these use backend defaults)
      voice: nil,
      speed: nil,
      response_format: nil,
      tts_url: nil,
      stt_url: nil,
      stt_language: nil
    ]

    @type plugin_declaration :: %{module: module(), config: map() | nil}

    @type t :: %__MODULE__{
            name: String.t(),
            backend:
              :tiamat,
            model: String.t() | nil,
            identity_paths: [String.t()],
            tools_prompt: boolean(),
            thinking: boolean() | nil,
            router_profile: String.t() | nil,
            context_window: pos_integer() | nil,
            saturation_warn: number() | nil,
            saturation_critical: number() | nil,
            openai_system_mode: :replace | :prepend | :append,
            private: boolean(),
            backend_config: map(),
            plugins: [plugin_declaration()],
            tool_posture: :sandbox | :permissive,
            tool_rw: [String.t()],
            tool_ro: [String.t()],
            voice: String.t() | nil,
            speed: float() | nil,
            response_format: String.t() | nil,
            tts_url: String.t() | nil,
            stt_url: String.t() | nil,
            stt_language: String.t() | nil
          }
  end

  # --- Public API (ETS reads — no GenServer.call) ---

  @doc "Resolve a profile by name. Returns resolved backend module, model, and identity content."
  @spec resolve_profile(String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolve_profile(name) do
    case :ets.lookup(@table, {:profile, name}) do
      [{_, %Profile{} = profile}] ->
        identity = read_identity_paths(profile.identity_paths)

        {:ok,
         %{
           name: profile.name,
           backend_module: backend_module(profile.backend),
           backend: profile.backend,
           model: profile.model,
           identity: identity,
           tools_prompt: profile.tools_prompt,
           thinking: profile.thinking,
           router_profile: profile.router_profile,
           context_window: profile.context_window,
           saturation_warn: profile.saturation_warn,
           saturation_critical: profile.saturation_critical,
           openai_system_mode: profile.openai_system_mode,
           private: profile.private,
           backend_config: profile.backend_config,
           plugins: profile.plugins,
           tool_posture: profile.tool_posture,
           tool_rw: profile.tool_rw,
           tool_ro: profile.tool_ro,
           voice: profile.voice,
           speed: profile.speed,
           response_format: profile.response_format,
           tts_url: profile.tts_url,
           stt_url: profile.stt_url,
           stt_language: profile.stt_language
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

  @doc "Return all profile names."
  @spec list_profiles() :: [String.t()]
  def list_profiles do
    :ets.match(@table, {{:profile, :"$1"}, :_})
    |> List.flatten()
    |> Enum.sort()
  end

  @doc """
  Look up the default profile name for a room.

  Resolution order:
  1. Explicit room_defaults mapping from config YAML
  2. Convention: rooms named `cdebug-<profile>` route to `<profile>`
  3. nil (falls through to global default)
  """
  @spec room_default_profile(String.t()) :: String.t() | nil
  def room_default_profile(room_name) do
    case :ets.lookup(@table, {:room_default, room_name}) do
      [{_, profile_name}] ->
        profile_name

      [] ->
        # Convention: cdebug-<profile> rooms route to the named profile
        case room_name do
          "cdebug-" <> profile_name when profile_name != "" -> profile_name
          _ -> nil
        end
    end
  end

  @doc "Return all room default mappings as `%{room_name => profile_name}`."
  @spec list_room_defaults() :: %{String.t() => String.t()}
  def list_room_defaults do
    :ets.match(@table, {{:room_default, :"$1"}, :"$2"})
    |> Enum.into(%{}, fn [room, profile] -> {room, profile} end)
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
            "tiamat" -> :tiamat
            "mock" -> :mock
            other -> raise "Cranium.Config: unknown backend '#{other}' for profile '#{name}'. Only 'tiamat' is supported."
          end

        unless backend != :tiamat or valid_router_profile?(config["router_profile"]) do
          raise "Cranium.Config: tiamat profile '#{name}' requires non-empty router_profile"
        end

        thinking =
          case config["thinking"] do
            v when is_boolean(v) -> v
            _ -> nil
          end

        openai_system_mode =
          case config["openai_system_mode"] do
            "prepend" -> :prepend
            "append" -> :append
            _ -> :replace
          end

        plugins = parse_plugins(config["plugins"])

        tool_posture =
          case config["tool_posture"] do
            "permissive" -> :permissive
            _ -> :sandbox
          end

        speed =
          case config["speed"] do
            v when is_number(v) -> v / 1
            _ -> nil
          end

        identity_paths = normalize_identity_paths(config["identity"])

        profile = %Profile{
          name: name,
          backend: backend,
          model: config["model"],
          identity_paths: identity_paths,
          tools_prompt: config["tools_prompt"] == true,
          thinking: thinking,
          router_profile: config["router_profile"],
          context_window: config["context_window"],
          saturation_warn: config["saturation_warn"],
          saturation_critical: config["saturation_critical"],
          openai_system_mode: openai_system_mode,
          private: config["private"] == true,
          backend_config: config["backend_config"] || %{},
          plugins: plugins,
          tool_posture: tool_posture,
          tool_rw: config["tool_rw"] || [],
          tool_ro: config["tool_ro"] || [],
          voice: config["voice"],
          speed: speed,
          response_format: config["response_format"],
          tts_url: config["tts_url"],
          stt_url: config["stt_url"],
          stt_language: config["stt_language"]
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

    # Room defaults
    room_defaults = yaml["room_defaults"]

    if is_map(room_defaults) do
      for {room, profile_name} <- room_defaults do
        unless Map.has_key?(profiles, profile_name) do
          Logger.warning(
            "Config: room_defaults '#{room}' references unknown profile '#{profile_name}', ignoring"
          )
        end

        :ets.insert(@table, {{:room_default, room}, profile_name})
      end
    end

    Logger.info("Config: loaded #{map_size(profiles)} profiles (default: #{default_name})")
  end

  defp valid_router_profile?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_identity_paths(nil), do: []
  defp normalize_identity_paths(path) when is_binary(path), do: [path]
  defp normalize_identity_paths(paths) when is_list(paths), do: paths
  defp normalize_identity_paths(_), do: []

  defp read_identity_paths([]), do: nil

  defp read_identity_paths(paths) do
    contents =
      paths
      |> Enum.map(&read_identity/1)
      |> Enum.reject(&is_nil/1)

    case contents do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp parse_plugins(nil), do: []

  defp parse_plugins(list) when is_list(list) do
    Enum.map(list, fn entry ->
      module_str = entry["module"] || raise "Cranium.Config: plugin entry missing 'module'"
      module = Module.concat([module_str])
      config = if is_map(entry["config"]), do: entry["config"], else: nil
      %{module: module, config: config}
    end)
  end

  defp parse_plugins(_), do: []

  defp backend_module(:tiamat), do: Cranium.Backend.LLM.Tiamat
  # Dynamic construction avoids compile-time xref warning — Mock only exists in test env.
  defp backend_module(:mock), do: Module.concat([Cranium.Backend.LLM, Mock])
end
