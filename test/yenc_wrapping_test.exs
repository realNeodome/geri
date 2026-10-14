defmodule Geri.YEncWrappingTest do
  use ExUnit.Case, async: true

  alias Geri.Encoder.YEnc

  test "escape-heavy data wraps by encoded bytes" do
    for byte <- [214, 224, 227, 19] do
      binary = :binary.copy(<<byte>>, 128)
      encoded = YEnc.encode(binary)
      assert Enum.map(data_lines(encoded), &byte_size/1) == [128, 128]
      assert decode(encoded) == binary
    end
  end

  test "an escape pair can fill the line exactly" do
    binary = :binary.copy("!", 126) <> <<214>> <> "!"
    assert YEnc.encode(binary) == :binary.copy("K", 126) <> "=@\r\nK\r\n"
    assert decode(YEnc.encode(binary)) == binary
  end

  test "an escape pair beginning at column 128 stays intact on a 129-byte line" do
    binary = :binary.copy("!", 127) <> <<214>> <> "!"
    assert YEnc.encode(binary) == :binary.copy("K", 127) <> "=@\r\nK\r\n"
    assert Enum.map(data_lines(YEnc.encode(binary)), &byte_size/1) == [129, 1]
    assert decode(YEnc.encode(binary)) == binary
  end

  test "an escape pair after a full line starts a new line" do
    binary = :binary.copy("!", 128) <> <<214>>
    assert YEnc.encode(binary) == :binary.copy("K", 128) <> "\r\n=@\r\n"
    assert decode(YEnc.encode(binary)) == binary
  end

  test "empty, partial, and exactly full output have the correct final CRLF" do
    assert YEnc.encode(<<>>) == <<>>
    assert YEnc.encode("!") == "K\r\n"
    assert YEnc.encode(:binary.copy("!", 128)) == :binary.copy("K", 128) <> "\r\n"
    assert YEnc.encode(:binary.copy(<<214>>, 64)) == :binary.copy("=@", 64) <> "\r\n"

    assert Enum.map(data_lines(YEnc.encode(:binary.copy("!", 257))), &byte_size/1) == [
             128,
             128,
             1
           ]
  end

  test "all byte values round-trip at every initial line offset" do
    all_bytes = for byte <- 0..255, into: <<>>, do: <<byte>>

    for offset <- 0..127 do
      binary = :binary.copy("!", offset) <> :binary.copy(all_bytes, 4)
      encoded = YEnc.encode(binary)
      assert decode(encoded) == binary

      for line <- data_lines(encoded) do
        assert byte_size(line) <= 129
        assert :binary.match(line, [<<0>>, "\r", "\n"]) == :nomatch
        # Validating the line in isolation rejects escape pairs split by CRLF.
        decode_line(line)

        if byte_size(line) == 129 do
          assert binary_part(line, 127, 1) == "="
        end
      end
    end
  end

  test "multipart bodies preserve part sizes and CRCs after wrapping" do
    dir = Path.join(System.tmp_dir!(), "geri-yenc-wrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    all_bytes = for byte <- 0..255, into: <<>>, do: <<byte>>
    binary = :binary.copy(<<214>>, 384) <> all_bytes
    File.write!(path, binary)

    try do
      {:ok, stream} = YEnc.stream_file(path, 192)
      parts = Enum.to_list(stream)

      decoded =
        for part <- parts do
          [header, part_header | rest] = data_lines(part.body)
          {body, [trailer]} = Enum.split(rest, -1)
          decoded = body |> Enum.map(&decode_line/1) |> IO.iodata_to_binary()
          assert header =~ "line=128"
          assert header =~ "size=#{byte_size(binary)}"
          assert part_header == "=ypart begin=#{part.begin} end=#{part.end}"
          assert Enum.all?(body, &(byte_size(&1) <= 129))
          assert byte_size(decoded) == part.source_size
          assert decoded == binary_part(binary, part.begin - 1, part.source_size)
          assert :erlang.crc32(decoded) == part.pcrc32
          assert trailer =~ "size=#{byte_size(decoded)} "
          assert trailer =~ "pcrc32=#{hex(:erlang.crc32(decoded))}"

          if part.part == part.total,
            do: assert(trailer =~ " crc32=#{hex(:erlang.crc32(binary))}")

          decoded
        end

      assert IO.iodata_to_binary(decoded) == binary
    after
      File.rm_rf!(dir)
    end
  end

  defp data_lines(encoded) do
    encoded |> :binary.split("\r\n", [:global]) |> Enum.reject(&(&1 == <<>>))
  end

  defp decode(encoded),
    do: encoded |> data_lines() |> Enum.map(&decode_line/1) |> IO.iodata_to_binary()

  # Decode independently, one complete encoded line at a time.
  defp decode_line(line), do: decode_line(line, [])
  defp decode_line(<<>>, bytes), do: bytes |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_line(<<"=", escaped, rest::binary>>, bytes) do
    decode_line(rest, [<<Integer.mod(escaped - 64 - 42, 256)>> | bytes])
  end

  defp decode_line(<<"=">>, _bytes), do: flunk("line ends with an incomplete escape pair")

  defp decode_line(<<byte, rest::binary>>, bytes) do
    decode_line(rest, [<<Integer.mod(byte - 42, 256)>> | bytes])
  end

  defp hex(crc),
    do: crc |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")
end
