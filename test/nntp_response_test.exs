defmodule Geri.NNTPResponseTest do
  use ExUnit.Case, async: true

  setup_all do
    certificate = [key: {:rsa, 2048, 65_537}, digest: :sha256]
    %{tls_options: :public_key.pkix_test_data(%{root: certificate, peer: certificate})}
  end

  for mode <- [:none, :implicit, :starttls] do
    test "#{mode}: bare codes, spaces, UTF-8 and a 512-byte response are accepted", c do
      replies = [
        {"200\r\n", ""},
        {"200 \r\n", ""},
        {"200   ready\r\n", "ready"},
        {"200 " <> String.duplicate("é", 253) <> "\r\n", String.duplicate("é", 253)}
      ]

      with_server(
        c,
        unquote(mode),
        fn transport, socket ->
          for {reply, _message} <- replies do
            assert {:ok, "DATE\r\n"} = recv(transport, socket)
            :ok = send_data(transport, socket, reply)
          end

          expect_closed(transport, socket)
        end,
        fn opts ->
          assert {:ok, conn} = Geri.NNTP.connect(opts)

          for {_reply, message} <- replies do
            assert {:ok, 200, ^message} = Geri.NNTP.command(conn, "DATE")
          end

          Geri.NNTP.close(conn)
        end
      )
    end

    test "#{mode}: malformed separators and line endings discard queued replies", c do
      for reply <- ["200garbage\r\n", "200\tready\r\n", "2000 ready\r\n", "200 ready\n"] do
        with_server(
          c,
          unquote(mode),
          fn transport, socket ->
            assert {:ok, "DATE\r\n"} = recv(transport, socket)
            :ok = send_data(transport, socket, reply <> "200 queued\r\n")
            expect_closed(transport, socket)
          end,
          fn opts ->
            assert {:ok, conn} = Geri.NNTP.connect(opts)
            assert {:error, _} = Geri.NNTP.command(conn, "DATE")
            # The valid-looking reply behind the malformed one must be unreachable.
            assert {:error, _} = Geri.NNTP.command(conn, "DATE")
          end
        )
      end
    end

    test "#{mode}: a 513-byte line and an oversized unterminated line fail promptly", c do
      for reply <- ["200 " <> String.duplicate("a", 507) <> "\r\n", String.duplicate("a", 1024)] do
        with_server(
          c,
          unquote(mode),
          fn transport, socket ->
            assert {:ok, "DATE\r\n"} = recv(transport, socket)
            :ok = send_data(transport, socket, reply)
            expect_closed(transport, socket)
          end,
          fn opts ->
            assert {:ok, conn} = Geri.NNTP.connect(opts)
            assert {:error, _} = Geri.NNTP.command(conn, "DATE")
          end
        )
      end
    end

    test "#{mode}: malformed final POST response remains uncertain and large articles still send",
         c do
      article = "From: uploader@example.com\r\n\r\n" <> String.duplicate("body\r\n", 300)

      with_server(
        c,
        unquote(mode),
        fn transport, socket ->
          assert {:ok, "POST\r\n"} = recv(transport, socket)
          :ok = send_data(transport, socket, "340 send it\r\n")
          assert receive_article(transport, socket) > 512
          :ok = send_data(transport, socket, "240garbage\r\n240 accepted\r\n")
          expect_closed(transport, socket)
        end,
        fn opts ->
          assert {:ok, conn} = Geri.NNTP.connect(opts)

          assert {:error, {:transport, :uncertain, {:invalid_response, "240garbage"}}} =
                   Geri.NNTP.post(conn, article)
        end
      )
    end
  end

  test "a malformed STARTTLS greeting closes TCP before any upgrade", c do
    for reply <- ["200garbage\r\n", String.duplicate("a", 1024)] do
      with_server(
        c,
        :starttls,
        fn transport, socket ->
          :ok = send_data(transport, socket, reply)
          expect_closed(transport, socket)
        end,
        fn opts ->
          assert {:error, _} = Geri.NNTP.connect(opts)
        end,
        false
      )
    end
  end

  defp with_server(c, mode, serve, client, greet \\ true) do
    options = [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}]
    transport = if mode == :implicit, do: :ssl, else: :gen_tcp

    {:ok, listener} =
      if transport == :ssl,
        do: :ssl.listen(0, options ++ c.tls_options),
        else: :gen_tcp.listen(0, options)

    {:ok, {_, port}} =
      if transport == :ssl, do: :ssl.sockname(listener), else: :inet.sockname(listener)

    server =
      Task.async(fn ->
        {transport, socket} = accept(transport, listener, c.tls_options)
        if greet, do: :ok = send_data(transport, socket, "200\r\n")

        {transport, socket} =
          if mode == :starttls and greet do
            assert {:ok, "STARTTLS\r\n"} = recv(transport, socket)
            :ok = send_data(transport, socket, "382 continue\r\n")

            {:ok, ssl} =
              :ssl.handshake(
                socket,
                c.tls_options ++ [:binary, active: false, packet: :line],
                5_000
              )

            {:ssl, ssl}
          else
            {transport, socket}
          end

        try do
          serve.(transport, socket)
        after
          apply(transport, :close, [socket])
        end
      end)

    try do
      client.(host: "127.0.0.1", port: port, tls: mode, tls_verify: :none)
      Task.await(server, 6_000)
    after
      apply(transport, :close, [listener])
      if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
    end
  end

  defp accept(:gen_tcp, listener, _opts) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:gen_tcp, socket}
  end

  defp accept(:ssl, listener, _opts) do
    {:ok, socket} = :ssl.transport_accept(listener, 5_000)
    {:ok, socket} = :ssl.handshake(socket, 5_000)
    {:ssl, socket}
  end

  defp recv(transport, socket), do: apply(transport, :recv, [socket, 0, 5_000])
  defp send_data(transport, socket, data), do: apply(transport, :send, [socket, data])

  defp expect_closed(transport, socket) do
    assert {:error, reason} = recv(transport, socket)
    refute reason == :timeout
  end

  defp receive_article(transport, socket, size \\ 0) do
    case recv(transport, socket) do
      {:ok, ".\r\n"} -> size
      {:ok, line} -> receive_article(transport, socket, size + byte_size(line))
    end
  end
end
