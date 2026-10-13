defmodule Geri.SourceIntegrityTest do
  use ExUnit.Case, async: true

  @encoders [
    {:base64, Geri.Encoder.Base64},
    {:uuencode, Geri.Encoder.UUEncode},
    {:yenc, Geri.Encoder.YEnc}
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    File.write!(path, :binary.copy("a", 114))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: path}
  end

  for {encoding, encoder} <- @encoders do
    test "#{encoding} preserves the size and part metadata of an unchanged source", c do
      {:ok, stream} = unquote(encoder).stream_file(c.path, 57)
      parts = Enum.to_list(stream)
      assert Enum.sum(Enum.map(parts, & &1.source_size)) == 114
      assert Enum.all?(parts, &(&1.file_size == 114 and &1.total == length(parts)))
      assert Enum.map(parts, & &1.part) == Enum.to_list(1..length(parts))
    end

    for size <- [0, 57, 115, 228] do
      test "#{encoding} rejects a source resized to #{size} before lazy consumption", c do
        {:ok, stream} = unquote(encoder).stream_file(c.path, 57)
        File.write!(c.path, :binary.copy("b", unquote(size)))
        error = assert_raise Geri.Encoder.Source.SizeChangedError, fn -> Enum.to_list(stream) end
        assert error.path == c.path
        assert error.expected_size == 114
        assert error.actual_size != 114
      end
    end

    test "#{encoding} detects a size change after consuming its last source chunk", c do
      {:ok, stream} = unquote(encoder).stream_file(c.path, 57)
      assert_raise Geri.Encoder.Source.SizeChangedError, fn ->
        Enum.each(stream, fn part ->
          if part.part == part.total, do: File.write!(c.path, "")
        end)
      end
    end

    for nzb? <- [false, true] do
      test "#{encoding} upload reports truncation with NZB=#{nzb?}", c do
        File.write!(c.path, :binary.copy("a", 1140))
        nzb = Path.join(c.dir, "upload.nzb")
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
        {:ok, {_ip, port}} = :inet.sockname(listener)
        server = Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          :ok = :gen_tcp.send(socket, "200 ready\r\n")
          assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
          # Backpressure prevents the producer from consuming the whole file.
          File.write!(c.path, "")
          post_remaining(socket)
        end)
        opts = [host: "127.0.0.1", port: port, tls: :none, auth_file: false,
                from: "test@example.invalid", newsgroups: ["test"], connections: 1,
                encoding: unquote(encoding), part_size: 57]
        opts = if unquote(nzb?), do: Keyword.put(opts, :nzb, nzb), else: opts

        try do
          assert {:error, {:upload_failed, {:source_size_changed, path, 1140, actual}, details}} =
                   Geri.upload(c.path, opts)
          assert path == c.path
          assert actual < 1140
          assert is_binary(details.upload_key)
          if unquote(nzb?) do
            assert File.exists?(nzb <> ".part")
            refute File.exists?(nzb)
          end
          assert :ok = Task.await(server, 2_000)
        after
          :gen_tcp.close(listener)
          Task.shutdown(server, :brutal_kill)
        end
      end
    end
  end

  test "finalization without an NZB rejects a partially produced file", c do
    job = start_job(c, [c.path])
    [first, _second] = parts(c.path)
    complete(job, first)
    assert {:error, :upload_incomplete} = Geri.JobState.finalize(job)
    assert Geri.JobState.failure_info(job).recovery.files[1].next_part == 2
  end

  test "finalization without an NZB rejects a file never produced", c do
    job = start_job(c, [c.path, c.path])
    Enum.each(parts(c.path), &complete(job, &1))
    assert {:error, :upload_incomplete} = Geri.JobState.finalize(job)
    assert Geri.JobState.failure_info(job).recovery.completed_files == 1
  end

  test "finalization without an NZB rejects an entirely unproduced job", c do
    job = start_job(c, [c.path])
    assert {:error, :upload_incomplete} = Geri.JobState.finalize(job)
  end

  test "finalization without an NZB accepts all posted parts", c do
    job = start_job(c, [c.path])
    Enum.each(parts(c.path), &complete(job, &1))
    assert :ok = Geri.JobState.finalize(job)
    assert Geri.JobState.failure_info(job).recovery == %{files: %{}, completed_files: 1}
  end

  defp start_job(_c, paths) do
    {:ok, job} = Geri.JobState.start_link("key", paths,
      from: "test@example.invalid", newsgroups: ["test"], encoding: :base64)
    job
  end

  defp parts(path) do
    {:ok, stream} = Geri.Encoder.Base64.stream_file(path, 57)
    Enum.map(stream, &Map.merge(&1, %{file_number: 1, file_total: 1, offset: (&1.part - 1) * 57}))
  end

  defp complete(job, part) do
    article = %{message_id: "<#{part.part}@test.invalid>", data: "article\r\n"}
    assert :ok = Geri.JobState.prepare_part(job, part, article)
    assert :ok = Geri.JobState.complete_part(job, part, article, ["test"], 1)
  end

  defp post_remaining(socket) do
    :gen_tcp.send(socket, "340 send article\r\n")
    receive_article(socket)
    :gen_tcp.send(socket, "240 received\r\n")
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, "POST\r\n"} -> post_remaining(socket)
      {:ok, "QUIT\r\n"} -> :gen_tcp.close(socket)
      {:error, :closed} -> :gen_tcp.close(socket)
    end
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> receive_article(socket)
    end
  end
end
