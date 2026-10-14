defmodule Geri.Filename do
  @moduledoc false

  def validate(filename) do
    # Preserve the name byte-for-byte. Reject malformed UTF-8, protocol line
    # breaks, and characters that cannot be represented in XML 1.0.
    if String.valid?(filename) and
         not Regex.match?(~r/[\x{0}-\x{8}\x{a}-\x{1f}\x{fffe}\x{ffff}]/u, filename),
       do: :ok,
       else: {:error, :invalid_filename}
  end
end
