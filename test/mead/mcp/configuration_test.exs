defmodule Mead.MCP.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Configuration

  @sentinel_header_value "Bearer SENTINEL-0123456789"

  defp stdio(overrides \\ []) do
    Keyword.merge(
      [
        transport: {:stdio, command: "npx", arguments: ["-y", "server"]},
        tools: [read_file: :read, write_file: :effect]
      ],
      overrides
    )
  end

  test "no servers is a valid configuration" do
    assert Configuration.validate([]) == {:ok, []}
  end

  test "a stdio server is normalized, with the tool names as strings" do
    assert Configuration.validate(filesystem: stdio()) ==
             {:ok,
              [
                %{
                  name: :filesystem,
                  transport:
                    {:stdio, command: "npx", arguments: ["-y", "server"], cwd: nil, env: []},
                  tools: %{"read_file" => :read, "write_file" => :effect},
                  never_remember: MapSet.new()
                }
              ]}
  end

  describe "never_remember" do
    test "names the tools that must be confirmed on every call" do
      assert {:ok, [server]} = Configuration.validate(a: stdio(never_remember: [:write_file]))
      assert server.never_remember == MapSet.new(["write_file"])
    end

    test "defaults to no tool" do
      assert {:ok, [server]} = Configuration.validate(a: stdio())
      assert server.never_remember == MapSet.new()
    end

    test "a tool that is not listed under tools is refused, since a typo would leave it unprotected" do
      assert Configuration.validate(a: stdio(never_remember: [:write_fil])) ==
               {:error, {:invalid_server, :a, {:never_remember_not_in_tools, :write_fil}}}
    end

    test "a repeated name, a non-list and a non-atom are refused" do
      assert Configuration.validate(a: stdio(never_remember: [:write_file, :write_file])) ==
               {:error, {:invalid_server, :a, {:duplicate_never_remember, :write_file}}}

      assert Configuration.validate(a: stdio(never_remember: :write_file)) ==
               {:error, {:invalid_server, :a, :invalid_never_remember}}

      assert Configuration.validate(a: stdio(never_remember: ["write_file"])) ==
               {:error, {:invalid_server, :a, :invalid_never_remember}}
    end
  end

  test "stdio arguments, working directory, environment and tools default to unset" do
    assert {:ok, [server]} = Configuration.validate(bare: [transport: {:stdio, command: "x"}])
    assert server.transport == {:stdio, command: "x", arguments: [], cwd: nil, env: []}
    assert server.tools == %{}
  end

  test "a stdio server may name the directory it starts in and variables it adds" do
    transport =
      {:stdio,
       command: "uv",
       arguments: ["run", "server"],
       cwd: "/srv/bridge",
       env: [{"BRIDGE_TOKEN", "value"}, {"LOG_LEVEL", "debug"}]}

    assert {:ok, [server]} = Configuration.validate(bridge: [transport: transport])

    assert server.transport ==
             {:stdio,
              command: "uv",
              arguments: ["run", "server"],
              cwd: "/srv/bridge",
              env: [{"BRIDGE_TOKEN", "value"}, {"LOG_LEVEL", "debug"}]}
  end

  test "an http server is normalized, with headers defaulting to empty" do
    assert {:ok, [server]} =
             Configuration.validate(remote: [transport: {:http, url: "https://example.test/mcp"}])

    assert server.transport == {:http, url: "https://example.test/mcp", headers: []}
  end

  test "servers keep the order they were configured in" do
    assert {:ok, servers} = Configuration.validate(b: stdio(), a: stdio())
    assert Enum.map(servers, & &1.name) == [:b, :a]
  end

  describe "rejections" do
    test "servers that are not a keyword list" do
      assert Configuration.validate(%{a: stdio()}) == {:error, :servers_not_a_keyword_list}
      assert Configuration.validate(["a"]) == {:error, :servers_not_a_keyword_list}
      assert Configuration.validate(nil) == {:error, :servers_not_a_keyword_list}
    end

    test "a duplicated server name" do
      assert Configuration.validate(a: stdio(), a: stdio()) == {:error, {:duplicate_server, :a}}
    end

    test "a server name that could break the server__tool split or the model's name rules" do
      for name <- [:my_server, :"has space", :"dot.name", :trailing_, :""] do
        assert Configuration.validate([{name, stdio()}]) == {:error, {:invalid_server_name, name}}
      end
    end

    test "a hyphen and digits are allowed in a server name" do
      assert {:ok, [%{name: :"github-full"}]} = Configuration.validate("github-full": stdio())
      assert {:ok, [%{name: :s2}]} = Configuration.validate(s2: stdio())
    end

    test "a definition that is not a keyword list, or has an unknown option" do
      assert Configuration.validate(a: :nonsense) ==
               {:error, {:invalid_server, :a, :definition_not_a_keyword_list}}

      assert Configuration.validate(a: stdio(tool: [])) ==
               {:error, {:invalid_server, :a, {:unknown_options, [:tool]}}}
    end

    test "a missing or unknown transport" do
      assert Configuration.validate(a: [tools: []]) ==
               {:error, {:invalid_server, :a, :missing_transport}}

      assert Configuration.validate(a: [transport: {:carrier_pigeon, []}]) ==
               {:error, {:invalid_server, :a, {:unknown_transport, :carrier_pigeon}}}

      assert Configuration.validate(a: [transport: "stdio"]) ==
               {:error, {:invalid_server, :a, :missing_transport}}
    end

    test "stdio options that are wrong" do
      assert Configuration.validate(a: [transport: {:stdio, []}]) ==
               {:error, {:invalid_server, :a, :invalid_command}}

      assert Configuration.validate(a: [transport: {:stdio, command: ""}]) ==
               {:error, {:invalid_server, :a, :invalid_command}}

      assert Configuration.validate(a: [transport: {:stdio, command: "x", arguments: "-y"}]) ==
               {:error, {:invalid_server, :a, :invalid_arguments}}

      assert Configuration.validate(a: [transport: {:stdio, command: "x", arguments: [1]}]) ==
               {:error, {:invalid_server, :a, :invalid_arguments}}

      assert Configuration.validate(a: [transport: {:stdio, command: "x", argument: []}]) ==
               {:error, {:invalid_server, :a, {:unknown_transport_options, [:argument]}}}
    end

    test "a working directory must be a non-empty absolute path" do
      for cwd <- ["relative/dir", "", "~/bridge", 123, :"/srv", ["/srv"]] do
        assert Configuration.validate(a: [transport: {:stdio, command: "x", cwd: cwd}]) ==
                 {:error, {:invalid_server, :a, :invalid_cwd}},
               "cwd #{inspect(cwd)} should be refused"
      end
    end

    test "an environment must be a list of name and value binaries" do
      for environment <- [
            %{"A" => "1"},
            "A=1",
            [{"A", 1}],
            [{:A, "1"}],
            [{"", "1"}],
            [{"A=B", "1"}],
            [{"A", "one\0two"}],
            [{"A\0B", "1"}],
            ["A=1"]
          ] do
        assert Configuration.validate(a: [transport: {:stdio, command: "x", env: environment}]) ==
                 {:error, {:invalid_server, :a, :invalid_env}},
               "env #{inspect(environment)} should be refused"
      end
    end

    # A reason names a key and never a value: a configured token must not reach a log through an
    # error, so even a malformed entry that carries one is reported without it.
    test "a refused environment never carries a value in the reason" do
      environment = [{"BRIDGE_TOKEN", "first-secret"}, {"BAD=NAME", "second-secret"}]

      result = Configuration.validate(a: [transport: {:stdio, command: "x", env: environment}])

      assert result == {:error, {:invalid_server, :a, :invalid_env}}
      refute inspect(result) =~ "secret"
    end

    test "an environment name given twice is refused by name, never by value" do
      environment = [{"BRIDGE_TOKEN", "first-secret"}, {"BRIDGE_TOKEN", "second-secret"}]

      result = Configuration.validate(a: [transport: {:stdio, command: "x", env: environment}])

      assert result == {:error, {:invalid_server, :a, {:duplicate_env_name, "BRIDGE_TOKEN"}}}
      refute inspect(result) =~ "secret"
    end

    test "http options that are wrong" do
      assert Configuration.validate(a: [transport: {:http, []}]) ==
               {:error, {:invalid_server, :a, :invalid_url}}

      assert Configuration.validate(a: [transport: {:http, url: "ftp://example.test"}]) ==
               {:error, {:invalid_server, :a, :invalid_url}}

      assert Configuration.validate(a: [transport: {:http, url: "http://x.test", headers: %{}}]) ==
               {:error, {:invalid_server, :a, :invalid_headers}}

      assert Configuration.validate(
               a: [transport: {:http, url: "http://x.test", headers: [{"a", 1}]}]
             ) ==
               {:error, {:invalid_server, :a, :invalid_headers}}
    end

    test "a bad header never puts its value in the reason" do
      {:error, reason} =
        Configuration.validate(
          a: [
            transport:
              {:http,
               url: "http://x.test",
               headers: [{"authorization", @sentinel_header_value}, {:bad, 1}]}
          ]
        )

      refute inspect(reason) =~ "SENTINEL"
    end

    test "a tool name the model could never be shown is refused at boot" do
      for tool <- [:"read.file", :"read file", :"lire\u00e9"] do
        assert Configuration.validate(a: stdio(tools: [{tool, :read}])) ==
                 {:error, {:invalid_server, :a, {:invalid_tool_name, tool}}}
      end
    end

    test "a tool whose server__tool name passes 64 characters is refused, and 64 is allowed" do
      longest = String.to_atom(String.duplicate("t", 61))
      too_long = String.to_atom(String.duplicate("t", 62))

      assert {:ok, [_server]} = Configuration.validate(a: stdio(tools: [{longest, :read}]))

      assert Configuration.validate(a: stdio(tools: [{too_long, :read}])) ==
               {:error, {:invalid_server, :a, {:invalid_tool_name, too_long}}}
    end

    test "tools that are wrong" do
      assert Configuration.validate(a: stdio(tools: %{read_file: :read})) ==
               {:error, {:invalid_server, :a, :invalid_tools}}

      assert Configuration.validate(a: stdio(tools: [read_file: :admin])) ==
               {:error, {:invalid_server, :a, {:invalid_tool_class, :read_file}}}

      assert Configuration.validate(a: stdio(tools: [read_file: :read, read_file: :effect])) ==
               {:error, {:invalid_server, :a, {:duplicate_tool, :read_file}}}

      assert Configuration.validate(a: stdio(tools: [{"read_file", :read}])) ==
               {:error, {:invalid_server, :a, :invalid_tools}}
    end
  end
end
