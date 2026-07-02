defmodule Cranium.Macro.ExecutorTest do
  use ExUnit.Case, async: true

  alias Cranium.Macro.{Definition, Executor}

  # --- Helpers ---

  defp make_prompt_macro(overrides \\ %{}) do
    base = %Definition{
      name: "test-prompt",
      description: "test",
      trigger: :ambient,
      advertising: :hidden,
      lifecycle: :turn,
      learning: :none,
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "Hello world", tag: nil, priority: nil}
    }

    struct!(base, Map.to_list(overrides))
  end

  defp make_script_macro(command, overrides \\ %{}) do
    base = %Definition{
      name: "test-script",
      description: "test",
      trigger: :explicit,
      advertising: :listed,
      lifecycle: :turn,
      learning: :none,
      revision: :never,
      disposition: :foreground,
      body_type: :script,
      script_body: %{command: command, timeout_seconds: nil, sandbox: nil}
    }

    struct!(base, Map.to_list(overrides))
  end

  # --- Prompt body ---

  describe "execute/4 prompt body" do
    test "simple prompt returns injection" do
      macro = make_prompt_macro()

      assert {:ok, %{priority: 50, content: "Hello world"}, %{}} =
               Executor.execute(macro, %{}, %{})
    end

    test "respects configured priority" do
      macro = make_prompt_macro(%{prompt_body: %{text: "hi", tag: nil, priority: 15}})
      assert {:ok, %{priority: 15}, _} = Executor.execute(macro, %{}, %{})
    end

    test "wraps content in XML tag when configured" do
      macro =
        make_prompt_macro(%{prompt_body: %{text: "k8s info", tag: "glossary", priority: 15}})

      assert {:ok, %{content: "<glossary>k8s info</glossary>"}, _} =
               Executor.execute(macro, %{}, %{})
    end

    test "no tag wrapping when tag is nil" do
      macro = make_prompt_macro(%{prompt_body: %{text: "raw content", tag: nil, priority: 50}})
      assert {:ok, %{content: "raw content"}, _} = Executor.execute(macro, %{}, %{})
    end

    test "resolves template variables from state" do
      macro =
        make_prompt_macro(%{prompt_body: %{text: "Hello %{user_name}", tag: nil, priority: nil}})

      assert {:ok, %{content: "Hello Kevin"}, _} =
               Executor.execute(macro, %{"user_name" => "Kevin"}, %{})
    end

    test "resolves template variables from context" do
      macro =
        make_prompt_macro(%{prompt_body: %{text: "Room: %{room_name}", tag: nil, priority: nil}})

      assert {:ok, %{content: "Room: cranium"}, _} =
               Executor.execute(macro, %{}, %{room_name: "cranium"})
    end

    test "state takes precedence over context" do
      macro = make_prompt_macro(%{prompt_body: %{text: "Val: %{key}", tag: nil, priority: nil}})

      assert {:ok, %{content: "Val: from-state"}, _} =
               Executor.execute(macro, %{"key" => "from-state"}, %{key: "from-context"})
    end

    test "empty resolved template returns nil output" do
      macro = make_prompt_macro(%{prompt_body: %{text: "%{missing}", tag: nil, priority: nil}})
      assert {:ok, nil, _} = Executor.execute(macro, %{}, %{})
    end

    test "multiple template variables" do
      macro =
        make_prompt_macro(%{
          prompt_body: %{text: "%{greeting} %{name}, turn %{turn_count}", tag: nil, priority: nil}
        })

      state = %{"greeting" => "Hey", "name" => "Kev"}
      context = %{turn_count: 5}

      assert {:ok, %{content: "Hey Kev, turn 5"}, _} = Executor.execute(macro, state, context)
    end

    test "passes state through unchanged" do
      macro = make_prompt_macro()
      state = %{"counter" => 42}
      assert {:ok, _, ^state} = Executor.execute(macro, state, %{})
    end
  end

  # --- Script body ---

  describe "execute/4 script body" do
    test "captures stdout on success" do
      macro = make_script_macro("echo hello")
      assert {:ok, "hello", %{}} = Executor.execute(macro, %{}, %{})
    end

    test "sets MACRO_NAME env var" do
      macro = make_script_macro("echo $MACRO_NAME")
      assert {:ok, "test-script", _} = Executor.execute(macro, %{}, %{})
    end

    test "sets context env vars" do
      macro = make_script_macro("echo $MACRO_ROOM_NAME-$MACRO_TURN_COUNT")
      context = %{room_name: "cranium", turn_count: 7}
      assert {:ok, "cranium-7", _} = Executor.execute(macro, %{}, context)
    end

    test "sets state as MACRO_STATE_ env vars" do
      macro = make_script_macro("echo $MACRO_STATE_COLOR")
      state = %{"color" => "blue"}
      assert {:ok, "blue", _} = Executor.execute(macro, state, %{})
    end

    test "returns error on non-zero exit" do
      macro = make_script_macro("echo fail && exit 1")
      assert {:error, msg} = Executor.execute(macro, %{}, %{})
      assert msg =~ "exited with code 1"
      assert msg =~ "fail"
    end

    test "respects timeout" do
      macro =
        make_script_macro("sleep 10", %{
          script_body: %{command: "sleep 10", timeout_seconds: 1, sandbox: nil}
        })

      assert {:error, msg} = Executor.execute(macro, %{}, %{})
      assert msg =~ "timed out"
    end
  end

  # --- Sequence body ---

  describe "execute/4 sequence body" do
    test "executes steps in order with inline definitions" do
      step1 =
        make_prompt_macro(%{name: "s1", prompt_body: %{text: "first", tag: nil, priority: 10}})

      step2 =
        make_prompt_macro(%{name: "s2", prompt_body: %{text: "second", tag: nil, priority: 20}})

      macro = %Definition{
        name: "pipeline",
        description: "test",
        trigger: :passive,
        advertising: :hidden,
        lifecycle: :turn,
        learning: :none,
        revision: :never,
        disposition: :foreground,
        body_type: :sequence,
        sequence_body: %{
          steps: [
            %{name: nil, inline: step1},
            %{name: nil, inline: step2}
          ],
          on_failure: :halt
        }
      }

      assert {:ok, outputs, _} = Executor.execute(macro, %{}, %{})
      assert [%{priority: 10, content: "first"}, %{priority: 20, content: "second"}] = outputs
    end

    test "halt on_failure stops sequence on error" do
      good =
        make_prompt_macro(%{name: "good", prompt_body: %{text: "ok", tag: nil, priority: 10}})

      bad = make_script_macro("exit 1", %{name: "bad"})

      after_bad =
        make_prompt_macro(%{name: "after", prompt_body: %{text: "never", tag: nil, priority: 30}})

      macro = %Definition{
        name: "pipeline",
        description: "test",
        trigger: :passive,
        advertising: :hidden,
        lifecycle: :turn,
        learning: :none,
        revision: :never,
        disposition: :foreground,
        body_type: :sequence,
        sequence_body: %{
          steps: [
            %{name: nil, inline: good},
            %{name: nil, inline: bad},
            %{name: nil, inline: after_bad}
          ],
          on_failure: :halt
        }
      }

      assert {:error, msg} = Executor.execute(macro, %{}, %{})
      assert msg =~ "halted"
    end

    test "skip on_failure continues past errors" do
      bad = make_script_macro("exit 1", %{name: "bad"})

      good =
        make_prompt_macro(%{
          name: "good",
          prompt_body: %{text: "survived", tag: nil, priority: 10}
        })

      macro = %Definition{
        name: "pipeline",
        description: "test",
        trigger: :passive,
        advertising: :hidden,
        lifecycle: :turn,
        learning: :none,
        revision: :never,
        disposition: :foreground,
        body_type: :sequence,
        sequence_body: %{
          steps: [
            %{name: nil, inline: bad},
            %{name: nil, inline: good}
          ],
          on_failure: :skip
        }
      }

      assert {:ok, outputs, _} = Executor.execute(macro, %{}, %{})
      assert [%{content: "survived"}] = outputs
    end

    test "abort on_failure returns error" do
      bad = make_script_macro("exit 1", %{name: "bad"})

      macro = %Definition{
        name: "pipeline",
        description: "test",
        trigger: :passive,
        advertising: :hidden,
        lifecycle: :turn,
        learning: :none,
        revision: :never,
        disposition: :foreground,
        body_type: :sequence,
        sequence_body: %{
          steps: [%{name: nil, inline: bad}],
          on_failure: :abort
        }
      }

      assert {:error, msg} = Executor.execute(macro, %{}, %{})
      assert msg =~ "aborted"
    end

    test "resolves named steps via resolver" do
      resolved =
        make_prompt_macro(%{
          name: "resolved",
          prompt_body: %{text: "found it", tag: nil, priority: 10}
        })

      resolver = fn "my-step" -> {:ok, resolved} end

      macro = %Definition{
        name: "pipeline",
        description: "test",
        trigger: :passive,
        advertising: :hidden,
        lifecycle: :turn,
        learning: :none,
        revision: :never,
        disposition: :foreground,
        body_type: :sequence,
        sequence_body: %{
          steps: [%{name: "my-step", inline: nil}],
          on_failure: :halt
        }
      }

      assert {:ok, [%{content: "found it"}], _} =
               Executor.execute(macro, %{}, %{}, resolver: resolver)
    end

    test "cleans up tmpdir after execution" do
      step = make_script_macro("echo $MACRO_TMPDIR", %{name: "s1"})

      macro = %Definition{
        name: "pipeline",
        description: "test",
        trigger: :passive,
        advertising: :hidden,
        lifecycle: :turn,
        learning: :none,
        revision: :never,
        disposition: :foreground,
        body_type: :sequence,
        sequence_body: %{
          steps: [%{name: nil, inline: step}],
          on_failure: :halt
        }
      }

      assert {:ok, [tmpdir_path], _} = Executor.execute(macro, %{}, %{})
      assert is_binary(tmpdir_path)
      refute File.exists?(tmpdir_path)
    end
  end
end
