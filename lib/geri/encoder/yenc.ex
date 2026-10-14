defmodule Geri.Encoder.YEnc do
  @line_length 128

  def stream_file(path, part_size)
      when is_integer(part_size) and part_size > 0 do
    with {:ok, stat} <- File.stat(path),
         :ok <- validate_file_size(stat.size),
         filename = Path.basename(path),
         :ok <- validate_filename(filename) do
      total =
        div(
          stat.size + part_size - 1,
          part_size
        )

      stream =
        path
        |> Geri.Encoder.Source.stream_file(part_size, stat.size)
        |> Stream.with_index(1)
        |> Stream.transform(
          {0, 0},
          fn {binary, part}, {offset, previous_crc32} ->
            begin_pos = offset + 1
            end_pos = offset + byte_size(binary)

            source_hash =
              :crypto.hash(
                :sha256,
                binary
              )

            pcrc32 =
              :erlang.crc32(binary)

            crc32 =
              :erlang.crc32(
                previous_crc32,
                binary
              )

            body =
              encode_part(
                binary,
                filename,
                stat.size,
                part,
                total,
                begin_pos,
                end_pos,
                pcrc32,
                crc32
              )

            item = %{
              encoding: :yenc,
              filename: filename,
              file_size: stat.size,
              part: part,
              total: total,
              source_hash: source_hash,
              source_size: byte_size(binary),
              begin: begin_pos,
              end: end_pos,
              pcrc32: pcrc32,
              crc32: crc32,
              subject: nil,
              body: body
            }

            {
              [item],
              {end_pos, crc32}
            }
          end
        )

      {:ok, stream}
    end
  end

  def encode(binary) when is_binary(binary) do
    binary
    |> encode_bytes([], 0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  def encode_part(
        binary,
        filename,
        file_size,
        _part,
        1,
        _begin_pos,
        _end_pos,
        _pcrc32,
        crc32
      ) do
    header =
      "=ybegin line=#{@line_length} " <>
        "size=#{file_size} name=#{filename}\r\n"

    trailer =
      "=yend size=#{byte_size(binary)} " <>
        "crc32=#{crc32_hex(crc32)}\r\n"

    header <>
      encode(binary) <>
      trailer
  end

  def encode_part(
        binary,
        filename,
        file_size,
        part,
        total,
        begin_pos,
        end_pos,
        pcrc32,
        crc32
      ) do
    header =
      "=ybegin part=#{part} total=#{total} " <>
        "line=#{@line_length} " <>
        "size=#{file_size} name=#{filename}\r\n"

    part_header =
      "=ypart begin=#{begin_pos} end=#{end_pos}\r\n"

    trailer =
      if part == total do
        "=yend size=#{byte_size(binary)} " <>
          "part=#{part} " <>
          "pcrc32=#{crc32_hex(pcrc32)} " <>
          "crc32=#{crc32_hex(crc32)}\r\n"
      else
        "=yend size=#{byte_size(binary)} " <>
          "part=#{part} " <>
          "pcrc32=#{crc32_hex(pcrc32)}\r\n"
      end

    header <>
      part_header <>
      encode(binary) <>
      trailer
  end

  defp encode_bytes(
         <<>>,
         acc,
         0
       ) do
    acc
  end

  defp encode_bytes(
         <<>>,
         acc,
         _column
       ) do
    ["\r\n" | acc]
  end

  defp encode_bytes(
         <<byte, rest::binary>>,
         acc,
         column
       ) do
    encoded =
      rem(
        byte + 42,
        256
      )

    output =
      if encoded in [0, 10, 13, ?=] do
        escaped =
          rem(
            encoded + 64,
            256
          )

        <<"=", escaped>>
      else
        <<encoded>>
      end

    # Count encoded bytes; an escape pair at column 128 stays on this line,
    # making it 129 bytes as permitted by the yEnc draft.
    next_column = column + byte_size(output)

    {acc, next_column} =
      if next_column >= @line_length do
        {
          ["\r\n", output | acc],
          0
        }
      else
        {
          [output | acc],
          next_column
        }
      end

    encode_bytes(
      rest,
      acc,
      next_column
    )
  end

  defp crc32_hex(crc) do
    crc
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  defp validate_file_size(0) do
    {:error, :empty_file}
  end

  defp validate_file_size(_size) do
    :ok
  end

  defp validate_filename(filename) do
    if String.contains?(
         filename,
         ["\r", "\n", <<0>>]
       ) do
      {:error, :invalid_filename}
    else
      :ok
    end
  end
end
