defmodule Geri.Encoder.Base64 do
  @line_bytes 57

  def normalize_part_size(size) when size < @line_bytes do
    {:error, :part_size_too_small}
  end

  def normalize_part_size(size) do
    {:ok, div(size, @line_bytes) * @line_bytes}
  end

  def encode(binary) when is_binary(binary) do
    binary
    |> chunks(@line_bytes)
    |> Enum.map_join(fn chunk ->
      Base.encode64(chunk) <> "\r\n"
    end)
  end

  def stream_file(path, part_size) do
    with {:ok, effective_size} <- normalize_part_size(part_size),
         filename = Path.basename(path),
         :ok <- Geri.Filename.validate(filename),
         {:ok, stat} <- File.stat(path),
         :ok <- validate_file_size(stat.size) do
      total = div(stat.size + effective_size - 1, effective_size)

      stream =
        path
        |> Geri.Encoder.Source.stream_file(effective_size, stat.size)
        |> Stream.with_index(1)
        |> Stream.map(fn {binary, part} ->
          %{
            encoding: :base64,
            filename: filename,
            file_size: stat.size,
            part: part,
            total: total,
            source_hash: :crypto.hash(:sha256, binary),
            source_size: byte_size(binary),
            subject: "#{filename} (#{part}/#{total})",
            body: encode(binary)
          }
        end)

      {:ok, stream}
    end
  end

  defp validate_file_size(0) do
    {:error, :empty_file}
  end

  defp validate_file_size(_size) do
    :ok
  end

  defp chunks(<<>>, _size) do
    []
  end

  defp chunks(binary, size) do
    case binary do
      <<chunk::binary-size(^size), rest::binary>> ->
        [chunk | chunks(rest, size)]

      _ ->
        [binary]
    end
  end
end
