defmodule Geri.InstallationTest do
  use ExUnit.Case, async: true

  @installer Path.expand("../install.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-install-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = release(dir, "old")
    new = release(dir, "new")
    prefix = Path.join(dir, "prefix with spaces")
    mock = Path.join(dir, "mock-bin")
    File.mkdir!(mock)
    commands = Map.new(["cp", "mv", "ln", "rm"], &{&1, System.find_executable(&1)})
    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      dir: dir,
      old: old,
      new: new,
      prefix: prefix,
      mock: mock,
      commands: commands,
      destination: Path.join(prefix, "lib/geri"),
      link: Path.join(prefix, "bin/geri"),
      lock: Path.join(prefix, "lib/.geri-install.lock")
    }
  end

  test "upgrades replace stale release files and reuse the existing command link", c do
    assert {_output, 0} = install(c, c.old)
    assert {"old\n", 0} = System.cmd(c.link, ["--version"])
    assert File.exists?(Path.join(c.destination, "obsolete"))
    target = File.read_link!(c.link)
    mock(c, "ln", "exit 73")
    assert {_output, 0} = install(c, c.new, mocked_env(c))
    assert_release(c, "new")
    assert File.read_link!(c.link) == target
    refute File.exists?(Path.join(c.destination, "obsolete"))
    assert {"new\n", 0} = System.cmd(c.link, ["--version"])
    refute File.exists?(c.lock)
  end

  for created <- [false, true] do
    test "a failed first install removes its release and link (link created: #{created})", c do
      script =
        if unquote(created),
          do: "#{quote_sh(c.commands["ln"])} \"$@\" || exit $?\nexit 73",
          else: "exit 73"

      mock(c, "ln", script)
      assert {_output, status} = install(c, c.new, mocked_env(c))
      assert status != 0
      refute File.exists?(c.destination)
      assert File.lstat(c.link) == {:error, :enoent}
      refute File.exists?(c.lock)
    end
  end

  test "an upgrade whose missing command link cannot be created restores the old release", c do
    assert {_output, 0} = install(c, c.old)
    File.rm!(c.link)
    mock(c, "ln", "exit 73")
    assert {_output, status} = install(c, c.new, mocked_env(c))
    assert status != 0
    assert_release(c, "old")
    assert File.exists?(Path.join(c.destination, "obsolete"))
    assert File.lstat(c.link) == {:error, :enoent}
    refute File.exists?(c.lock)
  end

  test "a failed move of the new release restores the previous one", c do
    assert {_output, 0} = install(c, c.old)

    mock(c, "mv", """
    case $1 in */.geri-install.lock/release) exit 73 ;; esac
    exec #{quote_sh(c.commands["mv"])} "$@"
    """)

    assert {_output, status} = install(c, c.new, mocked_env(c))
    assert status != 0
    assert_release(c, "old")
    assert {"old\n", 0} = System.cmd(c.link, ["--version"])
    refute File.exists?(c.lock)
  end

  for upgrading <- [false, true] do
    test "TERM immediately after release placement rolls back (upgrade: #{upgrading})", c do
      if unquote(upgrading), do: assert({_output, 0} = install(c, c.old))

      mock(c, "mv", """
      #{quote_sh(c.commands["mv"])} "$@" || exit $?
      case $1 in */.geri-install.lock/release) kill -TERM "$PPID" ;; esac
      """)

      assert {_output, 143} = install(c, c.new, mocked_env(c))

      if unquote(upgrading) do
        assert_release(c, "old")
        assert {"old\n", 0} = System.cmd(c.link, ["--version"])
      else
        refute File.exists?(c.destination)
        assert File.lstat(c.link) == {:error, :enoent}
      end

      refute File.exists?(c.lock)
    end
  end

  test "a failed rollback move preserves the old release and blocks another installer", c do
    assert {_output, 0} = install(c, c.old)
    File.rm!(c.link)
    mock(c, "ln", "exit 73")

    mock(c, "mv", """
    case $1 in */.geri-install.lock/previous) exit 74 ;; esac
    exec #{quote_sh(c.commands["mv"])} "$@"
    """)

    assert {output, status} = install(c, c.new, mocked_env(c))
    assert status != 0
    previous = Path.join(c.lock, "previous")
    assert File.read!(Path.join(previous, "version")) == "old"
    assert File.exists?(Path.join(previous, "obsolete"))
    refute File.exists?(c.destination)
    assert output =~ "previous release retained at #{previous}"
    assert {blocked, blocked_status} = install(c, c.new)
    assert blocked_status != 0
    assert blocked =~ "installation lock"
    assert File.read!(Path.join(previous, "version")) == "old"
  end

  test "failure removing the replacement leaves the previous release protected", c do
    assert {_output, 0} = install(c, c.old)
    File.rm!(c.link)
    mock(c, "ln", "exit 73")

    mock(c, "rm", """
    if [ "$#" -eq 2 ] && [ "$1" = -rf ] && [ "$2" = #{quote_sh(c.destination)} ]; then exit 74; fi
    exec #{quote_sh(c.commands["rm"])} "$@"
    """)

    assert {output, status} = install(c, c.new, mocked_env(c))
    assert status != 0
    previous = Path.join(c.lock, "previous")
    assert File.read!(Path.join(previous, "version")) == "old"
    assert_release(c, "new")
    assert output =~ "rollback failed"
    assert output =~ previous
  end

  test "a copy failure leaves the installed release untouched and releases the lock", c do
    assert {_output, 0} = install(c, c.old)
    mock(c, "cp", "exit 73")
    assert {_output, status} = install(c, c.new, mocked_env(c))
    assert status != 0
    assert_release(c, "old")
    assert {"old\n", 0} = System.cmd(c.link, ["--version"])
    refute File.exists?(c.lock)
  end

  test "the lock rejects a competing installer without blocking another prefix", c do
    assert {_output, 0} = install(c, c.old)
    ready = Path.join(c.dir, "ready")
    resume = Path.join(c.dir, "resume")

    mock(c, "cp", """
    : > #{quote_sh(ready)}
    attempts=0
    while [ ! -f #{quote_sh(resume)} ]; do
      attempts=$((attempts + 1))
      [ "$attempts" -le 10 ] || exit 75
      sleep 1
    done
    exec #{quote_sh(c.commands["cp"])} "$@"
    """)

    first = Task.async(fn -> install(c, c.new, mocked_env(c)) end)

    try do
      wait_until(fn -> File.exists?(ready) end)
      assert Bitwise.band(File.stat!(c.lock).mode, 0o777) == 0o700
      assert {output, status} = install(c, c.new)
      assert status != 0
      assert output =~ "installation lock"
      assert File.exists?(c.lock)
      assert Task.yield(first, 20) == nil
      assert_release(c, "old")
      other = %{c | prefix: Path.join(c.dir, "other prefix")}
      assert {_output, 0} = install(other, c.new)
      File.write!(resume, "continue")
      assert {_output, 0} = Task.await(first, 3_000)
      assert_release(c, "new")
      refute File.exists?(c.lock)
      assert {_output, 0} = install(c, c.new)
    after
      File.write!(resume, "continue")

      if Process.alive?(first.pid),
        do: Task.yield(first, 2_000) || Task.shutdown(first, :brutal_kill)
    end
  end

  for conflict <- [:command, :directory] do
    test "refusing an unrelated #{conflict} preserves it and releases the lock", c do
      path =
        if unquote(conflict) == :command, do: c.link, else: Path.join(c.destination, "unrelated")

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "do not replace")
      assert {output, status} = install(c, c.new)
      assert status != 0
      assert output =~ "refusing to replace"
      assert File.read!(path) == "do not replace"
      refute File.exists?(c.lock)
    end
  end

  defp release(dir, version) do
    root = Path.join(dir, "#{version} release")
    for name <- ["bin", "lib", "releases"], do: File.mkdir_p!(Path.join(root, name))
    File.write!(Path.join(root, "bin/geri"), "#!/bin/sh\nprintf '%s\\n' '#{version}'\n")
    File.chmod!(Path.join(root, "bin/geri"), 0o755)
    File.write!(Path.join(root, "version"), version)
    if version == "old", do: File.write!(Path.join(root, "obsolete"), "old only")
    root
  end

  defp install(c, release, env \\ []) do
    System.cmd("/bin/sh", [@installer, "--prefix", c.prefix, "--release", release],
      stderr_to_stdout: true,
      env: env
    )
  end

  defp assert_release(c, version),
    do: assert(File.read!(Path.join(c.destination, "version")) == version)

  defp mock(c, command, body) do
    path = Path.join(c.mock, command)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  defp mocked_env(c), do: [{"PATH", c.mock <> ":" <> System.fetch_env!("PATH")}]
  defp quote_sh(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp wait_until(fun), do: wait_until(fun, System.monotonic_time(:millisecond) + 2_000)

  defp wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(2)
      wait_until(fun, deadline)
    end
  end
end
