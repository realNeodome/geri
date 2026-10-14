defmodule Geri.ArticleIdentityTest do
  use ExUnit.Case, async: true

  @opts [from: "test@example.invalid", newsgroups: ["test"], upload_key: "fixed-key"]

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-identity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "same-basename yEnc files with a shared prefix have distinct first-part IDs", %{dir: dir} do
    first = encoded_part(dir, "a", "abcdefgh", :yenc, 4)
    second = encoded_part(dir, "b", "abcdXXXXXXXX", :yenc, 4)

    assert first.source_hash == second.source_hash
    assert first.crc32 == second.crc32
    assert first.filename == second.filename
    assert first.total == 2 and second.total == 3
    refute first.body == second.body
    refute article(first).message_id == article(second).message_id
  end

  test "yEnc file size is bound even when total parts and source bytes match", %{dir: dir} do
    first = encoded_part(dir, "a", "abcdefg", :yenc, 4)
    second = encoded_part(dir, "b", "abcdefgh", :yenc, 4)

    assert first.total == second.total
    assert first.source_hash == second.source_hash
    refute article(first).message_id == article(second).message_id
  end

  test "UUEncode and Base64 part totals distinguish otherwise identical first parts", %{dir: dir} do
    for {encoding, size} <- [uuencode: 45, base64: 57] do
      prefix = :binary.copy("a", size)
      first = encoded_part(dir, "#{encoding}-a", prefix <> prefix, encoding, size)
      second = encoded_part(dir, "#{encoding}-b", prefix <> prefix <> prefix, encoding, size)

      assert first.source_hash == second.source_hash
      assert first.body == second.body
      assert first.total == 2 and second.total == 3
      refute article(first).message_id == article(second).message_id
    end
  end

  test "regenerating an unchanged part retains its ID across batch positions and headers", %{
    dir: dir
  } do
    part = encoded_part(dir, "a", "abcdefgh", :yenc, 4)
    rebuilt = encoded_part(dir, "b", "abcdefgh", :yenc, 4)
    rebuilt = Map.merge(rebuilt, %{file_number: 9, file_total: 20, subject: "different comment"})

    changed_headers =
      Keyword.merge(@opts, from: "another@example.invalid", name: "Géri 日本語", newsgroups: ["another"])

    assert article(part).message_id == article(rebuilt, changed_headers).message_id
  end

  test "re-encoding a repair produces the original Message-ID for every encoding", %{dir: dir} do
    for {encoding, size} <- [yenc: 4, uuencode: 45, base64: 57] do
      binary = :binary.copy("a", size)
      part = encoded_part(dir, "#{encoding}-repair", binary <> binary, encoding, size)

      body =
        case encoding do
          :yenc ->
            Geri.Encoder.YEnc.encode_part(
              binary,
              part.filename,
              part.file_size,
              part.part,
              part.total,
              part.begin,
              part.end,
              part.pcrc32,
              part.crc32
            )

          :uuencode ->
            Geri.Encoder.UUEncode.encode_part(binary, part.filename, part.part, part.total)

          :base64 ->
            Geri.Encoder.Base64.encode(binary)
        end

      assert body == part.body
      assert article(%{part | body: body}).message_id == article(part).message_id
    end
  end

  test "different keys and part numbers remain distinct", %{dir: dir} do
    part = encoded_part(dir, "a", "abcdefgh", :yenc, 4)

    refute article(part).message_id ==
             article(part, Keyword.put(@opts, :upload_key, "other-key")).message_id

    refute article(part).message_id == article(%{part | part: 2}).message_id
  end

  test "a caller-supplied Message-ID remains unchanged", %{dir: dir} do
    part = encoded_part(dir, "a", "abcdefgh", :yenc, 4)

    assert article(part, Keyword.put(@opts, :message_id, "<custom@invalid>")).message_id ==
             "<custom@invalid>"
  end

  test "repair workers retain the original IDs for first and final parts", %{dir: dir} do
    for {encoding, size} <- [yenc: 128, uuencode: 45, base64: 57] do
      path = Path.join(dir, "#{encoding}.bin")
      byte = if encoding == :yenc, do: <<214>>, else: "a"
      binary = :binary.copy(byte, size * 2)
      File.write!(path, binary)
      module = encoder(encoding)
      {:ok, stream} = module.stream_file(path, size)

      parts =
        stream
        |> Enum.map(fn part ->
          Map.merge(part, %{
            file_number: 1,
            file_total: 1,
            file_size: byte_size(binary),
            subject: "repair",
            offset: (part.part - 1) * size
          })
        end)

      expected = Enum.map(parts, &article(&1).message_id)

      items =
        Enum.map(parts, fn part ->
          part
          |> Map.delete(:body)
          |> Map.put(:path, path)
          |> Map.put(:part_total, part.total)
          |> Map.put(:message_id, article(part).message_id)
        end)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

      {:ok, {_, port}} = :inet.sockname(listener)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5000)
          :gen_tcp.send(socket, "200 ready\r\n")

          try do
            receive_posts(socket, [])
          after
            :gen_tcp.close(socket)
          end
        end)

      {:ok, job} = Geri.JobState.start_link("fixed-key", [path], @opts)

      try do
        assert :ok =
                 Geri.repair(
                   items,
                   job,
                   [host: "127.0.0.1", port: port, tls: :none, repair_connections: 1],
                   @opts
                 )

        assert Task.await(server, 5000) == expected
        assert Geri.JobState.verification(job).repaired == 2
      after
        GenServer.stop(job)
        :gen_tcp.close(listener)
        if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
      end
    end
  end

  defp receive_posts(socket, ids) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, "POST\r\n"} ->
        :gen_tcp.send(socket, "340 send article\r\n")
        id = receive_article(socket, nil)
        :gen_tcp.send(socket, "240 accepted\r\n")
        receive_posts(socket, [id | ids])

      {:ok, "QUIT\r\n"} ->
        Enum.reverse(ids)
    end
  end

  defp receive_article(socket, id) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, ".\r\n"} -> id
      {:ok, "Message-ID: " <> value} -> receive_article(socket, String.trim(value))
      {:ok, _line} -> receive_article(socket, id)
    end
  end

  defp encoded_part(dir, subdir, binary, encoding, size) do
    path = Path.join([dir, subdir, "same.bin"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, binary)

    module = encoder(encoding)
    {:ok, stream} = module.stream_file(path, size)

    stream
    |> Enum.take(1)
    |> hd()
    |> Map.merge(%{file_size: byte_size(binary), file_number: 1, file_total: 1, subject: "same"})
  end

  defp encoder(:yenc), do: Geri.Encoder.YEnc
  defp encoder(:uuencode), do: Geri.Encoder.UUEncode
  defp encoder(:base64), do: Geri.Encoder.Base64

  defp article(part, opts \\ @opts) do
    {:ok, article} = Geri.Article.build(part, opts)
    article
  end
end
