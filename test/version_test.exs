defmodule Geri.VersionTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "geri-version-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp git(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end

  defp repository(root) do
    git(root, ["init", "-q"])
    git(root, ["config", "user.name", "Version test"])
    git(root, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(root, "source"), "first")
    git(root, ["add", "source"])
    git(root, ["commit", "-qm", "First"])
    git(root, ["rev-parse", "--short", "HEAD"])
  end

  test "untagged checkout and dirty tracked changes", %{root: root} do
    hash = repository(root)
    assert Geri.BuildVersion.version(root, "0.1.0") == "0.1.0+#{hash}"
    File.write!(Path.join(root, "untracked"), "new")
    assert Geri.BuildVersion.version(root, "0.1.0") == "0.1.0+#{hash}"
    File.write!(Path.join(root, "source"), "second")
    assert Geri.BuildVersion.version(root, "0.1.0") == "0.1.0+#{hash}.dirty"
  end

  test "annotated tag and subsequent commits", %{root: root} do
    repository(root)
    git(root, ["tag", "-a", "v1.2.3", "-m", "Release"])
    assert Geri.BuildVersion.version(root, "0.1.0") == "1.2.3"
    File.write!(Path.join(root, "source"), "second")
    assert Geri.BuildVersion.version(root, "0.1.0") == "1.2.3+dirty"
    git(root, ["commit", "-qam", "Second"])
    hash = git(root, ["rev-parse", "--short", "HEAD"])
    assert Geri.BuildVersion.version(root, "0.1.0") == "1.2.3+1.g#{hash}"
    File.write!(Path.join(root, "source"), "third")
    assert Geri.BuildVersion.version(root, "0.1.0") == "1.2.3+1.g#{hash}.dirty"
  end

  test "lightweight tags and stale archive stamp", %{root: root} do
    repository(root)
    git(root, ["tag", "v2.0.0"])
    git(root, ["tag", "unrelated"])
    File.write!(Path.join(root, "SOURCE_VERSION"), "9.9.9")
    assert Geri.BuildVersion.version(root, "0.1.0") == "2.0.0"
  end

  test "archive stamp and invalid or absent stamp", %{root: root} do
    assert Geri.BuildVersion.version(root, "0.1.0") == "0.1.0"
    stamp = Path.join(root, "SOURCE_VERSION")
    File.write!(stamp, "2.0.0+3.gabcdef0\n")
    assert Geri.BuildVersion.version(root, "0.1.0") == "2.0.0+3.gabcdef0"
    File.write!(stamp, "invalid")
    assert Geri.BuildVersion.version(root, "0.1.0") == "0.1.0"
  end

  test "archive cannot inherit an unrelated parent repository", %{root: root} do
    repository(root)
    git(root, ["tag", "v9.9.9"])
    archive = Path.join(root, "archive")
    File.mkdir!(archive)
    assert Geri.BuildVersion.version(archive, "0.1.0") == "0.1.0"
    File.write!(Path.join(archive, "SOURCE_VERSION"), "1.0.0")
    assert Geri.BuildVersion.version(archive, "0.1.0") == "1.0.0"
  end

  test "build metadata refreshes after tag-only changes without recompiling source", %{root: root} do
    aliases = Geri.MixProject.project()[:aliases]
    File.cp!(Path.expand("../build_support/version.exs", __DIR__), Path.join(root, "version.exs"))
    File.write!(Path.join(root, ".gitignore"), "/_build/\n")
    File.mkdir!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/fixture.ex"), "defmodule VersionFixture do\nend\n")

    File.write!(Path.join(root, "mix.exs"), """
    Code.require_file("version.exs", __DIR__)
    defmodule VersionFixture.MixProject do
      use Mix.Project
      def project do
        [app: :version_fixture, version: Geri.BuildVersion.version(__DIR__, "0.1.0"),
         aliases: #{inspect(aliases)}]
      end
    end
    """)

    repository(root)
    git(root, ["add", "."])
    git(root, ["commit", "-qm", "Build fixture"])

    version = fn ->
      {output, 0} =
        System.cmd(
          System.find_executable("elixir"),
          [
            System.find_executable("mix"),
            "run",
            "--no-start",
            "-e",
            "IO.puts(Application.spec(:version_fixture, :vsn))"
          ],
          cd: root,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_ROOT", nil}, {"MIX_BUILD_PATH", nil}]
        )

      output |> String.trim() |> String.split("\n") |> List.last()
    end

    assert String.starts_with?(version.(), "0.1.0+")
    beam = Path.join(root, "_build/dev/lib/version_fixture/ebin/Elixir.VersionFixture.beam")
    original = File.stat!(beam)
    git(root, ["tag", "-a", "v2.3.4", "-m", "Release"])
    assert version.() == "2.3.4"
    assert File.stat!(beam).mtime == original.mtime
    git(root, ["commit", "--allow-empty", "-qm", "Next"])
    assert String.starts_with?(version.(), "2.3.4+1.g")
    assert File.stat!(beam).mtime == original.mtime
  end
end
