defmodule Geri.UploadDuplicatesTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-duplicates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    File.write!(path, "hello")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: path, nzb: Path.join(dir, "upload.nzb")}
  end

  test "explicit key skips POST for an existing article and records its NZB segment", c do
    {result, commands} = upload(c, ["223 0 <existing@invalid>\r\n"], "240 Posted\r\n", true)
    assert {:ok, "fixed-key"} = result
    assert [{:stat, message_id}] = commands
    segment_id = message_id |> String.trim_leading("<") |> String.trim_trailing(">")
    assert File.read!(c.nzb) =~ segment_id
    assert File.read!(c.nzb) =~ "</nzb>"
  end

  test "explicit key posts a missing article", c do
    {result, commands} = upload(c, ["430 Missing\r\n"], "240 Posted\r\n", true)
    assert {:ok, "fixed-key"} = result
    assert [{:stat, _}, {:post, article}] = commands
    assert article =~ "=ybegin"
    assert article =~ "=yend"
  end

  test "generated key posts without a preliminary STAT", c do
    {result, commands} = upload(c, [], "240 Posted\r\n", false)
    assert {:ok, _key} = result
    assert [{:post, _}] = commands
  end

  test "rejected POST followed by presence succeeds even for a generated key", c do
    {result, commands} = upload(c, ["223 0 <existing@invalid>\r\n"], "441 Rejected\r\n", false)
    assert {:ok, _key} = result
    assert [{:post, _}, {:stat, _}] = commands
    assert File.read!(c.nzb) =~ "</nzb>"
  end

  test "rejected POST followed by absence remains a failure", c do
    {result, commands} = upload(c, ["430 Missing\r\n"], "441 Rejected\r\n", false)
    assert {:error, {:upload_failed, {:post_rejected, 441, "Rejected"}, _}} = result
    assert [{:post, _}, {:stat, _}] = commands
    assert File.exists?(c.nzb <> ".part")
    refute File.exists?(c.nzb)
  end

  test "unavailable preliminary STAT does not prevent posting", c do
    {result, commands} = upload(c, ["500 STAT unavailable\r\n"], "240 Posted\r\n", true)
    assert {:ok, "fixed-key"} = result
    assert [{:stat, _}, {:post, _}] = commands
  end

  test "a race between preliminary STAT and POST is resolved by a second STAT", c do
    {result, commands} = upload(c, ["430 Missing\r\n", "223 0 <existing@invalid>\r\n"], "441 Rejected\r\n", true)
    assert {:ok, "fixed-key"} = result
    assert [{:stat, _}, {:post, _}, {:stat, _}] = commands
  end

  test "an inconclusive STAT after rejection preserves the original posting error", c do
    {result, _commands} = upload(c, ["500 STAT unavailable\r\n"], "441 Rejected\r\n", false)
    assert {:error, {:upload_failed, {:post_rejected, 441, "Rejected"}, _}} = result
  end

  defp upload(c, stat_responses, post_response, explicit_key) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server = Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 5_000)
      :ok = :gen_tcp.send(socket, "200 Test server ready\r\n")
      try do
        serve(socket, stat_responses, post_response, [])
      after
        :gen_tcp.close(socket)
      end
    end)

    opts = [host: "127.0.0.1", port: port, tls: :none, auth_file: false,
            from: "test@example.invalid", newsgroups: ["test"], connections: 1,
            encoding: :yenc, nzb: c.nzb]
    opts = if explicit_key, do: Keyword.put(opts, :upload_key, "fixed-key"), else: opts

    try do
      result = Geri.upload(c.path, opts)
      {result, Task.await(server, 5_000)}
    after
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
    end
  end

  defp serve(socket, stat_responses, post_response, commands) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "STAT " <> rest} ->
        [response | remaining] = stat_responses
        :ok = :gen_tcp.send(socket, response)
        serve(socket, remaining, post_response, [{:stat, String.trim(rest)} | commands])

      {:ok, "POST\r\n"} ->
        :ok = :gen_tcp.send(socket, "340 Send article\r\n")
        article = receive_article(socket, [])
        :ok = :gen_tcp.send(socket, post_response)
        serve(socket, stat_responses, post_response, [{:post, article} | commands])

      {:ok, "QUIT\r\n"} ->
        :gen_tcp.send(socket, "205 Goodbye\r\n")
        Enum.reverse(commands)

      {:error, :closed} ->
        Enum.reverse(commands)
    end
  end

  defp receive_article(socket, lines) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, ".\r\n"} -> lines |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, line} -> receive_article(socket, [line | lines])
    end
  end
end
