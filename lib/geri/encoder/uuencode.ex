defmodule Geri.Encoder.UUEncode do
  import Bitwise

  @line_bytes 45

  def normalize_part_size(size) when size < @line_bytes do
    {:error, :part_size_too_small}
  end

  def normalize_part_size(size) do
    {:ok, div(size, @line_bytes) * @line_bytes}
  end

  def encode(binary) when is_binary(binary) do
    binary
    |> chunks(@line_bytes)
    |> Enum.map_join(&encode_line/1)
  end

  def encode_part(binary, filename, part, total)
      when is_binary(binary) and
             is_binary(filename) and
             part >= 1 and
             part <= total do
    prefix =
      if part == 1 do
        "begin 644 #{filename}\r\n"
      else
        ""
      end

    suffix =
      if part == total do
        "`\r\nend\r\n"
      else
        ""
      end

    prefix <> encode(binary) <> suffix
  end

  def stream_file(path, part_size) do
    with {:ok, effective_size} <- normalize_part_size(part_size),
         {:ok, stat} <- File.stat(path),
         :ok <- validate_file_size(stat.size),
         filename = Path.basename(path),
         :ok <- validate_filename(filename) do
      total = div(stat.size + effective_size - 1, effective_size)

      stream =
        path
        |> File.stream!(effective_size, [])
        |> Stream.with_index(1)
        |> Stream.map(fn {binary, part} ->
          %{
            encoding: :uuencode,
            filename: filename,
            part: part,
            total: total,
            source_hash: :crypto.hash(:sha256, binary),
            source_size: byte_size(binary),
            subject: "#{filename} (#{part}/#{total})",
            body: encode_part(binary, filename, part, total)
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

  defp validate_filename(filename) do
    if String.contains?(filename, ["\r", "\n", <<0>>]) do
      {:error, :invalid_filename}
    else
      :ok
    end
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

  defp encode_line(binary) do
    length =
      binary
      |> byte_size()
      |> encode_char()

    encoded =
      binary
      |> pad()
      |> encode_groups()

    <<length>> <> encoded <> "\r\n"
  end

  defp pad(binary) do
    case rem(byte_size(binary), 3) do
      0 ->
        binary

      1 ->
        binary <> <<0, 0>>

      2 ->
        binary <> <<0>>
    end
  end

  defp encode_groups(<<>>) do
    ""
  end

  defp encode_groups(<<a, b, c, rest::binary>>) do
    x1 = a >>> 2
    x2 = (a &&& 0x03) <<< 4 ||| b >>> 4
    x3 = (b &&& 0x0F) <<< 2 ||| c >>> 6
    x4 = c &&& 0x3F

    <<
      encode_char(x1),
      encode_char(x2),
      encode_char(x3),
      encode_char(x4)
    >> <> encode_groups(rest)
  end

  defp encode_char(0) do
    ?`
  end

  defp encode_char(value) do
    value + 32
  end
end
