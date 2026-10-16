defmodule Geri.BuildVersion do
  @moduledoc false

  # Run while Mix evaluates the project, so commit/tag changes also refresh
  # the application metadata when no Elixir source needs recompiling.
  def version(root, base) do
    with {:ok, top} <- git(root, ["rev-parse", "--show-toplevel"]),
         true <- Path.expand(top) == Path.expand(root),
         {:ok, description} <-
           git(root, [
             "describe",
             "--tags",
             "--match",
             "v[0-9]*.[0-9]*.[0-9]*",
             "--long",
             "--always",
             "--dirty"
           ]) do
      from_description(description, base)
    else
      _ -> archived_version(root, base)
    end
  end

  defp from_description(description, base) do
    dirty = String.ends_with?(description, "-dirty")
    description = String.replace_suffix(description, "-dirty", "")

    version =
      case Regex.run(~r/^v(\d+\.\d+\.\d+)-(\d+)-g([0-9a-f]+)$/, description) do
        [_, tag, "0", _hash] -> tag
        [_, tag, count, hash] -> tag <> "+" <> count <> ".g" <> hash
        _ -> base <> "+" <> description
      end

    version =
      if dirty,
        do: version <> if(String.contains?(version, "+"), do: ".dirty", else: "+dirty"),
        else: version

    if Version.parse(version) == :error, do: base, else: version
  end

  defp archived_version(root, base) do
    with {:ok, contents} <- File.read(Path.join(root, "SOURCE_VERSION")),
         version = String.trim(contents),
         {:ok, _} <- Version.parse(version) do
      version
    else
      _ -> base
    end
  end

  defp git(root, args) do
    case System.find_executable("git") do
      nil ->
        :error

      executable ->
        case System.cmd(executable, args, cd: root, stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          _ -> :error
        end
    end
  end
end
