defmodule Geri.Encoder.Source.SizeChangedError do
  defexception [:path, :expected_size, :actual_size]

  @impl true
  def message(error) do
    "source size changed for #{error.path}: expected #{error.expected_size} bytes, " <>
      "observed #{error.actual_size} bytes"
  end
end

defmodule Geri.Encoder.Source do
  @moduledoc """
  Streams source-byte chunks while enforcing the initially observed file size.

  Enumeration can raise File.Error or SizeChangedError. Size checks run on each
  chunk and at EOF; they do not provide a snapshot or detect every same-size
  edit. Hashes in encoded parts separately protect later repair reads.
  """

  alias Geri.Encoder.Source.SizeChangedError

  @spec stream_file(Path.t(), pos_integer(), non_neg_integer()) :: Enumerable.t()
  def stream_file(path, part_size, file_size) do
    path
    |> File.stream!(part_size, [])
    |> Stream.transform(
      fn -> 0 end,
      fn binary, offset ->
        size = byte_size(binary)
        expected = min(part_size, file_size - offset)

        if size != expected do
          raise SizeChangedError,
            path: path, expected_size: file_size, actual_size: offset + size
        end

        {[binary], offset + size}
      end,
      fn offset ->
        if offset != file_size do
          raise SizeChangedError,
            path: path, expected_size: file_size, actual_size: offset
        end

        actual_size = File.stat!(path).size
        if actual_size != file_size do
          raise SizeChangedError,
            path: path, expected_size: file_size, actual_size: actual_size
        end

        {[], offset}
      end,
      fn _offset -> :ok end
    )
  end
end
