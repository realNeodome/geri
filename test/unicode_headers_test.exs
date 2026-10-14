defmodule Geri.UnicodeHeadersTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-unicode-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "café-日本語-😀.bin")
    File.write!(path, :binary.copy("a", 130))

    opts = [
      host: "127.0.0.1",
      from: "geri@example.com",
      name: "Géri 日本語",
      newsgroups: ["test"],
      upload_key: "fixed",
      auth_file: false
    ]

    %{dir: dir, path: path, opts: opts}
  end

  test "bare address and ASCII name use predictable quoting" do
    assert {:ok, "geri@example.com"} = Geri.Header.encode_from("geri@example.com")
    assert {:ok, "geri@example.com"} = Geri.Header.encode_from("geri@example.com", "")

    assert {:ok, "\"Geri\" <geri@example.com>"} =
             Geri.Header.encode_from("geri@example.com", "Geri")

    assert {:ok, "\"Geri \\\"test\\\" \\\\ name\" <geri@example.com>"} =
             Geri.Header.encode_from("geri@example.com", "Geri \"test\" \\ name")
  end

  test "combined forms and Unicode addresses fail before output creation", c do
    nzb = Path.join(c.dir, "out.nzb")

    for value <- [
          "\"Geri\" <geri@example.com>",
          "geri@example.com (Geri)",
          "<geri@example.com>",
          "géri@example.com",
          "a@@b",
          "@b",
          "a@",
          "a b@example.com",
          "a@example.com,other@example.com"
        ] do
      assert {:error, {:invalid_option, :from, :email_address_required}} =
               Geri.upload(c.path, Keyword.merge(c.opts, from: value, nzb: nzb))

      refute File.exists?(nzb <> ".part")
    end

    assert {:error, message} =
             Geri.CLI.run([
               "upload",
               "--host",
               "localhost",
               "--group",
               "test",
               "--from",
               "Geri <geri@example.com>",
               "--",
               c.path
             ])

    assert message =~ "--name"
  end

  test "headers reject injected lines and malformed UTF-8", c do
    for key <- [:name, :comment], value <- ["x\r\ny", <<0>>, <<255>>] do
      assert {:error, {:invalid_option, ^key, :header_text_required}} =
               Geri.Options.normalize(c.path, Keyword.put(c.opts, key, value))
    end

    assert {:error, :invalid_header} = Geri.Header.encode_subject("x\nPOST")
    assert {:error, :invalid_header} = Geri.Header.encode_from("geri@example.com", <<255>>)
  end

  test "MIME words preserve exact Unicode, whitespace, and character boundaries" do
    for text <- ["Géri", String.duplicate("é日本😀 é ", 20), "=?UTF-8?B?YWJj?=", "a\tb"] do
      assert {:ok, encoded} = Geri.Header.encode_subject(text)
      assert decode_words(encoded) == text

      for word <- String.split(Geri.Header.unfold(encoded), " ") do
        assert byte_size(word) <= 75
        assert String.valid?(decode_word(word))
      end

      for line <- String.split("Subject: " <> encoded, "\r\n"), do: assert(byte_size(line) <= 76)
    end

    assert {:ok, "plain ASCII"} = Geri.Header.encode_subject("plain ASCII")
    name = String.duplicate("Géri 日本語 ", 15)
    assert {:ok, from} = Geri.Header.encode_from("geri@example.com", name)
    assert String.ends_with?(from, "<geri@example.com>")
    phrase = from |> Geri.Header.unfold() |> String.replace_suffix(" <geri@example.com>", "")
    assert decode_words(phrase) == name
    for line <- String.split("From: " <> from, "\r\n"), do: assert(byte_size(line) <= 76)
  end

  test "all encoders preserve Unicode filenames and reject invalid names", c do
    for {encoder, size} <- [
          {Geri.Encoder.YEnc, 128},
          {Geri.Encoder.UUEncode, 90},
          {Geri.Encoder.Base64, 114}
        ] do
      assert {:ok, stream} = encoder.stream_file(c.path, size)
      assert Enum.all?(stream, &(&1.filename == Path.basename(c.path)))

      for filename <- [
            <<"bad-", 255, ".bin">>,
            "bad-\n.bin",
            "bad-\r.bin",
            "bad-\x01.bin",
            "bad-\uFFFF.bin"
          ] do
        path = Path.join(c.dir, filename)
        assert {:error, :invalid_filename} = encoder.stream_file(path, size)

        assert {:error, {:invalid_input, ^path, :invalid_filename}} =
                 Geri.upload(path, Keyword.put(c.opts, :nzb, Path.join(c.dir, "invalid.nzb")))

        refute File.exists?(Path.join(c.dir, "invalid.nzb.part"))
      end
    end

    # Canonically equivalent names are distinct; neither is normalized.
    for filename <- ["é.bin", "é.bin"] do
      path = Path.join(c.dir, filename)
      File.write!(path, "hello")
      {:ok, stream} = Geri.Encoder.YEnc.stream_file(path, 128)
      assert hd(Enum.to_list(stream)).filename == filename
    end
  end

  test "CLI upload writes the article's encoded From and Subject into NZB", c do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          :ok = :gen_tcp.send(socket, "200 ready\r\n")
          assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
          :ok = :gen_tcp.send(socket, "340 send it\r\n")
          data = read_article(socket, [])
          :ok = :gen_tcp.send(socket, "240 accepted\r\n")
          assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
          data
        after
          :gen_tcp.close(socket)
        end
      end)

    nzb = Path.join(c.dir, "unicode.nzb")
    name = String.duplicate("Géri 日本語 ", 8)

    try do
      assert :ok =
               Geri.CLI.run([
                 "upload",
                 "--host",
                 "127.0.0.1",
                 "--port",
                 to_string(port),
                 "--tls",
                 "none",
                 "--auth-file",
                 Path.join(c.dir, "absent.auth"),
                 "--from",
                 "geri@example.com",
                 "--name",
                 name,
                 "--group",
                 "test",
                 "--connections",
                 "1",
                 "--nzb",
                 nzb,
                 "--comment",
                 "Résumé & <test>",
                 "--",
                 c.path
               ])

      article = Task.await(server, 2_000)
      [headers, body] = String.split(article, "\r\n\r\n", parts: 2)
      assert body =~ "name=" <> Path.basename(c.path)
      headers = Geri.Header.unfold(headers) |> String.split("\r\n")

      from =
        headers
        |> Enum.find(&String.starts_with?(&1, "From: "))
        |> String.replace_prefix("From: ", "")

      subject =
        headers
        |> Enum.find(&String.starts_with?(&1, "Subject: "))
        |> String.replace_prefix("Subject: ", "")

      assert decode_words(String.replace_suffix(from, " <geri@example.com>", "")) == name
      assert decode_words(subject) =~ "Résumé & <test>"
      assert decode_words(subject) =~ Path.basename(c.path)
      xml = File.read!(nzb)
      assert xml =~ "poster=\"#{xml_escape(from)}\""
      assert xml =~ "subject=\"#{xml_escape(subject)}\""
      refute File.exists?(nzb <> ".part")
    after
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
    end
  end

  defp read_article(socket, lines) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> lines |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, line} -> read_article(socket, [line | lines])
    end
  end

  defp decode_words(value) do
    value |> Geri.Header.unfold() |> String.split(" ") |> Enum.map_join(&decode_word/1)
  end

  defp decode_word("=?UTF-8?B?" <> rest) do
    rest |> String.replace_suffix("?=", "") |> Base.decode64!()
  end

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
