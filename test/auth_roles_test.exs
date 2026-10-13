defmodule Geri.AuthRolesTest.Observer do
  @behaviour :gen_event
  def init(parent), do: {:ok, parent}
  def handle_call({:attach, control}, parent) do
    send(parent, {:upload_control, control})
    {:ok, :ok, parent}
  end
  def handle_event(_event, parent), do: {:ok, parent}
  def handle_info(_message, parent), do: {:ok, parent}
  def terminate(_reason, _parent), do: :ok
  def code_change(_old, parent, _extra), do: {:ok, parent}
end

defmodule Geri.AuthRolesTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-role-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    source = Path.join(dir, "source.bin")
    File.write!(source, "hello")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, source: source}
  end

  test "ABB checks and repairs with B's resolved credentials", c do
    run_roles(c, :abb)
  end

  test "ABC authenticates A, B and C independently", c do
    run_roles(c, :abc)
  end

  test "ABB repair username looks up that identity on B", c do
    run_roles(c, :abb_override)
  end

  test "a check username cannot borrow credentials from another B identity", c do
    path = auth_file(c, "check", "machine b.invalid login other password other-secret")
    assert {:error, {:check_auth, :incomplete_credentials}} = Geri.upload(c.source,
      host: "a.invalid", auth_file: false, check_host: "b.invalid", check_auth_file: path,
      check_username: "requested", from: "test@example.invalid", newsgroups: ["test"])
  end

  test "C cannot inherit B's password for an explicit C username", c do
    path = auth_file(c, "repair", "machine c.invalid login other password other-secret")
    assert {:error, {:repair_auth, :incomplete_credentials}} = Geri.upload(c.source,
      host: "a.invalid", auth_file: false, check_host: "b.invalid",
      check_username: "b-user", check_password: "b-secret", repair_host: "c.invalid",
      repair_username: "c-user", repair_auth_file: path,
      from: "test@example.invalid", newsgroups: ["test"])
  end

  test "line breaks are rejected for B and C before starting the upload", c do
    base = [host: "a.invalid", auth_file: false, check_host: "b.invalid",
      from: "test@example.invalid", newsgroups: ["test"]]
    assert {:error, {:check_auth, {:invalid_credentials, :username}}} =
             Geri.upload(c.source, Keyword.put(base, :check_username, "b\nPOST"))
    assert {:error, {:repair_auth, {:invalid_credentials, :password}}} =
             Geri.upload(c.source, Keyword.merge(base,
               repair_host: "c.invalid", repair_username: "c", repair_password: "secret\rPOST"))
  end

  defp run_roles(c, mode) do
    {a, a_port} = listener()
    {b, b_port} = listener()
    {r, r_port} = listener()
    observer = {Geri.AuthRolesTest.Observer, make_ref()}
    :ok = :gen_event.add_handler(:erl_signal_server, observer, self())

    global = auth_file(c, "global", """
    machine 127.0.0.1 login fallback password fallback-secret
    machine 127.0.0.1 port #{a_port} login a-user password a-secret
    machine 127.0.0.1 port #{b_port} login global-b password wrong-b-source
    machine 127.0.0.1 port #{r_port} login global-c password wrong-c-source
    """)
    checking = auth_file(c, "checking", """
    machine 127.0.0.1 port #{b_port} login b-reader password b-read-secret
    machine 127.0.0.1 port #{b_port} login b-writer password b-write-secret
    """)
    repairing = auth_file(c, "repairing",
      "machine 127.0.0.1 port #{r_port} login c-writer password c-secret")

    a_server = Task.async(fn ->
      socket = accept(a)
      authenticate(socket, "a-user", "a-secret")
      post(socket)
    end)
    b_server = Task.async(fn ->
      socket = accept(b)
      checker = Task.async(fn ->
        receive do
          {:socket, socket} ->
            authenticate(socket, "b-reader", "b-read-secret")
            for _ <- 1..3 do
              assert {:ok, "STAT " <> _} = :gen_tcp.recv(socket, 0, 2_000)
              :ok = :gen_tcp.send(socket, "430 missing\r\n")
            end
            expect_close(socket)
        end
      end)
      :ok = :gen_tcp.controlling_process(socket, checker.pid)
      send(checker.pid, {:socket, socket})
      if mode != :abc do
        repair = accept(b)
        if mode == :abb_override do
          authenticate(repair, "b-writer", "b-write-secret")
        else
          authenticate(repair, "b-reader", "b-read-secret")
        end
        post(repair)
      end
      Task.await(checker, 5_000)
    end)
    r_server = if mode == :abc do
      Task.async(fn ->
        socket = accept(r)
        authenticate(socket, "c-writer", "c-secret")
        post(socket)
      end)
    end

    opts = [host: "127.0.0.1", port: a_port, tls: :none, auth_file: global,
      check_host: "127.0.0.1", check_port: b_port, check_tls: :none,
      check_auth_file: checking, check_username: "b-reader", signal_handler: observer,
      connections: 1, check_connections: 1, repair_connections: 1,
      from: "test@example.invalid", newsgroups: ["test"]]
    opts = case mode do
      :abc -> Keyword.merge(opts, repair_host: "127.0.0.1", repair_port: r_port,
                repair_tls: :none, repair_auth_file: repairing)
      :abb_override -> Keyword.put(opts, :repair_username, "b-writer")
      :abb -> opts
    end
    upload = Task.async(fn -> Geri.upload(c.source, opts) end)
    servers = Enum.reject([a_server, b_server, r_server], &is_nil/1)

    try do
      assert_receive {:upload_control, control}, 2_000
      checker = wait_until(fn -> Geri.Control.context(control)[:checker] end)
      # Advance the propagation schedule while retaining real NNTP exchanges.
      for _ <- 1..3, do: run_next_check(checker)
      assert {:ok, _key} = Task.await(upload, 5_000)
      Enum.each(servers, fn server -> assert :ok = Task.await(server, 2_000) end)
    after
      Enum.each([a, b, r], &:gen_tcp.close/1)
      Task.shutdown(upload, :brutal_kill)
      Enum.each(servers, &Task.shutdown(&1, :brutal_kill))
      :gen_event.delete_handler(:erl_signal_server, observer, [])
    end
  end

  defp run_next_check(checker) do
    wait_until(fn -> not :gb_trees.is_empty(:sys.get_state(checker).queue) end)
    :sys.replace_state(checker, fn state ->
      if state.timer, do: Process.cancel_timer(state.timer)
      now = System.monotonic_time(:millisecond) - 1
      entries = for {{_due, sequence}, item} <- :gb_trees.to_list(state.queue), do: {{now, sequence}, item}
      %{state | queue: :gb_trees.from_orddict(Enum.sort(entries)), timer: nil}
    end)
    send(checker, :dispatch)
  end

  defp wait_until(fun), do: wait_until(fun, System.monotonic_time(:millisecond) + 2_000)
  defp wait_until(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] -> value
      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        wait_until(fun, deadline)
    end
  end

  defp auth_file(c, name, contents) do
    path = Path.join(c.dir, name)
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  defp listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    :ok = :gen_tcp.send(socket, "200 ready\r\n")
    socket
  end

  defp authenticate(socket, username, password) do
    assert {:ok, "AUTHINFO USER " <> received} = :gen_tcp.recv(socket, 0, 2_000)
    assert received == username <> "\r\n"
    :ok = :gen_tcp.send(socket, "381 password required\r\n")
    assert {:ok, "AUTHINFO PASS " <> received} = :gen_tcp.recv(socket, 0, 2_000)
    assert received == password <> "\r\n"
    :ok = :gen_tcp.send(socket, "281 authenticated\r\n")
  end

  defp post(socket) do
    assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
    :ok = :gen_tcp.send(socket, "340 send article\r\n")
    receive_article(socket)
    :ok = :gen_tcp.send(socket, "240 received\r\n")
    expect_close(socket)
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> receive_article(socket)
    end
  end

  defp expect_close(socket) do
    assert :gen_tcp.recv(socket, 0, 2_000) in [{:ok, "QUIT\r\n"}, {:error, :closed}]
    :gen_tcp.close(socket)
  end
end
