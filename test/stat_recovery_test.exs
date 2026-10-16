defmodule Geri.StatRecoveryTest do
  use ExUnit.Case, async: true

  @late_reply "223 0 <late@invalid>\r\n"
  @delay 30_100

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-stat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    File.write!(path, "abcdefgh")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: path, nzb: Path.join(dir, "upload.nzb")}
  end

  @tag timeout_case: true, timeout: 45_000
  test "preliminary STAT timeout reconnects before verifying and posting", c do
    {result, commands} =
      upload(c, fn listener ->
        first = accept(listener)
        expect_stat(first)
        Process.sleep(@delay)
        :gen_tcp.send(first, @late_reply)
        expect_closed(first)

        second = accept(listener)
        id = expect_stat(second)
        :gen_tcp.send(second, "430 missing\r\n")
        posted = accept_post(second)
        expect_quit(second)
        {id, posted}
      end)

    assert {:ok, "fixed-key"} = result
    assert {id, id} = commands
    assert File.read!(c.nzb) =~ "</nzb>"
  end

  @tag timeout_case: true, timeout: 45_000
  test "STAT timeout during uncertain-post recovery checks a fresh connection", c do
    {result, id} =
      upload(
        c,
        fn listener ->
          first = accept(listener)
          posted = receive_unacknowledged_post(first)
          :gen_tcp.close(first)

          second = accept(listener)
          assert expect_stat(second) == posted
          Process.sleep(@delay)
          :gen_tcp.send(second, @late_reply)
          expect_closed(second)

          third = accept(listener)
          assert expect_stat(third) == posted
          :gen_tcp.send(third, "223 0 #{posted}\r\n")
          expect_quit(third)
          posted
        end,
        false
      )

    assert {:ok, _key} = result
    segment_id = id |> String.trim_leading("<") |> String.trim_trailing(">")
    assert File.read!(c.nzb) =~ segment_id
  end

  @tag timeout_case: true, timeout: 45_000
  test "STAT timeout after rejection closes the socket and preserves the posting error", c do
    {result, :closed} =
      upload(
        c,
        fn listener ->
          socket = accept(listener)
          receive_unacknowledged_post(socket)
          :gen_tcp.send(socket, "441 rejected\r\n")
          expect_stat(socket)
          Process.sleep(@delay)
          :gen_tcp.send(socket, @late_reply)
          expect_closed(socket)
          :closed
        end,
        false
      )

    assert {:error, {:upload_failed, {:post_rejected, 441, "rejected"}, _}} = result
    assert File.exists?(c.nzb <> ".part")
  end

  for {label, reply} <- [
        {"malformed response", "not an NNTP reply\r\n"},
        {"missing separator", "223garbage\r\n"},
        {"oversized response", "223 " <> String.duplicate("a", 507) <> "\r\n"},
        {"invalid line ending", "223 present\n"}
      ] do
    test "preliminary STAT #{label} discards queued replies before reconnecting", c do
      {result, :verified} =
        upload(c, fn listener ->
          first = accept(listener)
          id = expect_stat(first)
          :gen_tcp.send(first, unquote(reply) <> @late_reply)
          expect_closed(first)

          second = accept(listener)
          assert expect_stat(second) == id
          :gen_tcp.send(second, "223 0 #{id}\r\n")
          expect_quit(second)
          :verified
        end)

      assert {:ok, "fixed-key"} = result
    end
  end

  for {label, reply} <- [
        {"missing separator", "240garbage\r\n"},
        {"tab separator", "240\taccepted\r\n"},
        {"oversized response", "240 " <> String.duplicate("a", 507) <> "\r\n"}
      ] do
    test "final POST #{label} verifies on a fresh socket without reposting", c do
      {result, :verified} =
        upload(c, fn listener ->
          first = accept(listener)
          id = receive_unacknowledged_post(first)
          :ok = :gen_tcp.send(first, unquote(reply) <> "240 accepted\r\n")
          expect_closed(first)

          second = accept(listener)
          assert expect_stat(second) == id
          :ok = :gen_tcp.send(second, "223 0 #{id}\r\n")
          expect_quit(second)
          :verified
        end, false)

      assert {:ok, _key} = result
      assert File.read!(c.nzb) =~ "</nzb>"
    end
  end

  test "closed preliminary STAT connection repeats STAT rather than blindly posting", c do
    {result, :verified} =
      upload(c, fn listener ->
        first = accept(listener)
        id = expect_stat(first)
        :gen_tcp.close(first)

        second = accept(listener)
        assert expect_stat(second) == id
        :gen_tcp.send(second, "223 0 #{id}\r\n")
        expect_quit(second)
        :verified
      end)

    assert {:ok, "fixed-key"} = result
  end

  test "malformed STAT during uncertain recovery discards the socket", c do
    {result, :verified} =
      upload(
        c,
        fn listener ->
          first = accept(listener)
          id = receive_unacknowledged_post(first)
          :gen_tcp.close(first)

          second = accept(listener)
          assert expect_stat(second) == id
          :gen_tcp.send(second, "not a reply\r\n" <> @late_reply)
          expect_closed(second)

          third = accept(listener)
          assert expect_stat(third) == id
          :gen_tcp.send(third, "223 0 #{id}\r\n")
          expect_quit(third)
          :verified
        end,
        false
      )

    assert {:ok, _key} = result
  end

  test "repair continues on a fresh socket after malformed rejection verification", c do
    {:ok, stream} = Geri.Encoder.YEnc.stream_file(c.path, 4)
    article_opts = [from: "test@invalid", newsgroups: ["test"], upload_key: "fixed-key"]

    parts =
      Enum.map(stream, fn part ->
        Map.merge(part, %{
          file_number: 1,
          file_total: 1,
          file_size: 8,
          subject: "repair",
          offset: (part.part - 1) * 4
        })
      end)

    items =
      Enum.map(parts, fn part ->
        {:ok, article} = Geri.Article.build(part, article_opts)

        part
        |> Map.delete(:body)
        |> Map.put(:path, c.path)
        |> Map.put(:part_total, part.total)
        |> Map.put(:message_id, article.message_id)
      end)

    {listener, port} = listen()

    server =
      Task.async(fn ->
        first = accept(listener)
        assert receive_unacknowledged_post(first) == hd(items).message_id
        :gen_tcp.send(first, "441 rejected\r\n")
        assert expect_stat(first) == hd(items).message_id
        :gen_tcp.send(first, "malformed\r\n" <> @late_reply)
        expect_closed(first)

        second = accept(listener)
        assert accept_post(second) == List.last(items).message_id
        expect_quit(second)
      end)

    {:ok, job} = Geri.JobState.start_link("fixed-key", [c.path], article_opts)

    try do
      assert :ok =
               Geri.repair(
                 items,
                 job,
                 [host: "127.0.0.1", port: port, tls: :none, repair_connections: 1],
                 article_opts
               )

      assert :ok = Task.await(server, 5000)
      assert %{repaired: 1, repair_failed: 1} = Geri.JobState.verification(job)

      assert [%{reason: {:post_rejected, 441, "rejected"}}] =
               Geri.JobState.failure_info(job).unresolved
    after
      GenServer.stop(job)
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
    end
  end

  defp upload(c, serve, explicit_key \\ true) do
    {listener, port} = listen()
    server = Task.async(fn -> serve.(listener) end)

    opts = [
      host: "127.0.0.1",
      port: port,
      tls: :none,
      auth_file: false,
      from: "test@invalid",
      newsgroups: ["test"],
      connections: 1,
      nzb: c.nzb
    ]

    opts = if explicit_key, do: Keyword.put(opts, :upload_key, "fixed-key"), else: opts

    try do
      {Geri.upload(c.path, opts), Task.await(server, 5000)}
    after
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
    end
  end

  defp listen do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 5000)
    :ok = :gen_tcp.send(socket, "200 ready\r\n")
    socket
  end

  defp expect_stat(socket) do
    assert {:ok, "STAT " <> rest} = :gen_tcp.recv(socket, 0, 5000)
    String.trim(rest)
  end

  defp receive_unacknowledged_post(socket) do
    assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 5000)
    :ok = :gen_tcp.send(socket, "340 send article\r\n")
    receive_article(socket, nil)
  end

  defp accept_post(socket) do
    id = receive_unacknowledged_post(socket)
    :ok = :gen_tcp.send(socket, "240 accepted\r\n")
    id
  end

  defp receive_article(socket, id) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, ".\r\n"} -> id
      {:ok, "Message-ID: " <> value} -> receive_article(socket, String.trim(value))
      {:ok, _line} -> receive_article(socket, id)
    end
  end

  defp expect_closed(socket) do
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5000)
    :gen_tcp.close(socket)
  end

  defp expect_quit(socket) do
    assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 5000)
    :gen_tcp.close(socket)
  end
end
