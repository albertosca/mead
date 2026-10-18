defmodule Mead.Router.ClassifierTest do
  use ExUnit.Case, async: true

  alias Mead.Router.Classifier
  alias Mead.Session.Turn

  defp history(count), do: for(_turn <- 1..count//1, do: Turn.start("earlier"))

  test "short routine requests go local" do
    for input <- [
          "list my unread emails",
          "check the status of the build",
          "format this as a table",
          "count the open tasks",
          "liste meus compromissos de hoje",
          "confira o status do deploy"
        ] do
      assert Classifier.classify([], input) == :local, "expected local for #{inspect(input)}"
    end
  end

  test "requests for reasoning or writing go to the cloud, even with a triage word" do
    for input <- [
          "explain why the build is failing",
          "compare these two options",
          "write a reply to this email",
          "list the options and explain the trade-offs",
          "resuma este documento",
          "por que o deploy falhou?",
          "por quê?"
        ] do
      assert Classifier.classify([], input) == :cloud, "expected cloud for #{inspect(input)}"
    end
  end

  test "an input that matches nothing goes to the cloud" do
    assert Classifier.classify([], "hello there") == :cloud
    assert Classifier.classify([], "") == :cloud
  end

  test "a long input goes to the cloud even when it looks routine" do
    assert Classifier.classify([], "list " <> String.duplicate("a", 275)) == :local
    assert Classifier.classify([], "list " <> String.duplicate("a", 276)) == :cloud
  end

  test "a heavy history sends a routine request to the cloud" do
    assert Classifier.classify(history(20), "list my tasks") == :local
    assert Classifier.classify(history(21), "list my tasks") == :cloud
  end

  test "an input that is not a string goes to the cloud" do
    for input <- [nil, 42, :list, {:list, "tasks"}, ["list"]] do
      assert Classifier.classify([], input) == :cloud
    end
  end

  test "keywords match whole words only" do
    assert Classifier.classify([], "the planet status") == :local
    assert Classifier.classify([], "whitelist") == :cloud
  end
end
