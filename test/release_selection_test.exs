defmodule Geri.ReleaseSelectionTest do
  use ExUnit.Case, async: true

  @source Path.expand("..", __DIR__)
  @tui "_build/prod/rel/geri"
  @headless "_build/headless/prod/rel/geri"

  setup do
    root = Path.join(System.tmp_dir!(), "geri-release-test-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source with spaces")
    File.mkdir_p!(Path.join(source, "docs"))

    for name <- ["geri.sh", "install.sh", "README.md", "LICENSE"] do
      File.cp!(Path.join(@source, name), Path.join(source, name))
    end

    File.write!(Path.join(source, "docs/installation.md"), "fixture")
    on_exit(fn -> File.rm_rf!(root) end)
    %{source: source, prefix: Path.join(root, "prefix with spaces")}
  end

  for {builds, expected} <- [
        {[:tui], "tui"},
        {[:headless], "headless"},
        {[:tui, :headless], "tui"}
      ] do
    test "source launcher selects #{expected} with #{inspect(builds)}", c do
      for build <- unquote(builds), do: release(c.source, build)
      # --no-tui controls runtime display; it must not select another build.
      assert {unquote(expected) <> "\n", 0} =
               System.cmd("/bin/sh", [Path.join(c.source, "geri.sh"), "--no-tui"],
                 cd: c.prefix |> Path.dirname()
               )
    end

    test "installer selects #{expected} with #{inspect(builds)}", c do
      for build <- unquote(builds), do: release(c.source, build)
      assert {_output, 0} = install(c)

      assert {unquote(expected) <> "\n", 0} =
               System.cmd(Path.join(c.prefix, "bin/geri"), ["--version"])
    end
  end

  test "adjacent installed release takes precedence over source builds", c do
    release(c.source, :tui)
    release(c.source, :headless)
    release(c.source, :installed)
    assert {"installed\n", 0} = System.cmd("/bin/sh", [Path.join(c.source, "geri.sh")])
  end

  test "an explicit release overrides the default preference", c do
    release(c.source, :tui)
    headless = release(c.source, :headless)
    assert {_output, 0} = install(c, ["--release", headless])
    assert {"headless\n", 0} = System.cmd(Path.join(c.prefix, "bin/geri"), ["--version"])
  end

  test "an invalid explicit release does not fall back to an available build", c do
    release(c.source, :tui)
    assert {output, status} = install(c, ["--release", Path.join(c.source, "missing")])
    assert status != 0
    assert output =~ "built release not found"
    refute File.exists?(c.prefix)
  end

  test "nonexecutable TUI release falls back to headless", c do
    tui = release(c.source, :tui)
    release(c.source, :headless)
    File.chmod!(Path.join(tui, "bin/geri"), 0o644)
    assert {"headless\n", 0} = System.cmd("/bin/sh", [Path.join(c.source, "geri.sh")])
    assert {_output, 0} = install(c)
    assert {"headless\n", 0} = System.cmd(Path.join(c.prefix, "bin/geri"), ["--version"])
  end

  test "missing builds fail without creating an installation", c do
    assert {launcher_output, 1} =
             System.cmd("/bin/sh", [Path.join(c.source, "geri.sh")], stderr_to_stdout: true)

    assert launcher_output =~ "release not found"
    assert {installer_output, 1} = install(c)
    assert installer_output =~ "built release not found"
    refute File.exists?(c.prefix)
  end

  defp release(source, variant) do
    root =
      case variant do
        :tui -> Path.join(source, @tui)
        :headless -> Path.join(source, @headless)
        :installed -> source
      end

    for dir <- ["bin", "lib", "releases"], do: File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join(root, "bin/geri"), "#!/bin/sh\nprintf '%s\\n' '#{variant}'\n")
    File.chmod!(Path.join(root, "bin/geri"), 0o755)
    root
  end

  defp install(c, args \\ []) do
    System.cmd("/bin/sh", [Path.join(c.source, "install.sh"), "--prefix", c.prefix] ++ args,
      stderr_to_stdout: true
    )
  end
end
