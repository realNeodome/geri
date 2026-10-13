defmodule Geri.Encoder.Source.SizeChangedError do
  defexception [:path, :expected_size, :actual_size]

  @impl true
  def message(error) do
    "source size changed for #{error.path}: expected #{error.expected_size} bytes, " <>
      "observed #{error.actual_size} bytes"
  end
end

defmodule Geri.Encoder.Source do
  alias Geri.Encoder.Source.SizeChangedError

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
