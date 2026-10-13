defmodule Geri.AuthTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a host-only entry supplies its complete pair on any port", c do
    for port <- [119, 563, 9119] do
      assert {:ok, opts} = resolve(c, "machine news.invalid login user password secret", port: port)
      assert {opts[:username], opts[:password]} == {"user", "secret"}
    end
  end

  test "exact port beats an earlier host-only entry", c do
    assert {:ok, opts} = resolve(c, """
    machine news.invalid login generic password generic-secret
    machine news.invalid port 563 login tls-user password tls-secret
    """)
    assert {opts[:username], opts[:password]} == {"tls-user", "tls-secret"}
  end

  test "an explicit port does not match a different port", c do
    assert {:ok, opts} = resolve(c,
      "machine news.invalid port 119 login plain password plain-secret", port: 563)
    assert is_nil(opts[:username]) and is_nil(opts[:password])
  end

  test "server-specific entries beat an earlier default", c do
    assert {:ok, opts} = resolve(c, """
    default port 563 login fallback password fallback-secret
    machine news.invalid login specific password specific-secret
    """)
    assert {opts[:username], opts[:password]} == {"specific", "specific-secret"}
  end

  test "an explicit default entry remains a fallback", c do
    assert {:ok, opts} = resolve(c,
      "machine other.invalid login other password other-secret\ndefault login guest password guest-secret")
    assert {opts[:username], opts[:password]} == {"guest", "guest-secret"}
  end

  test "equal specificity retains the first entry", c do
    assert {:ok, opts} = resolve(c, """
    machine news.invalid login first password first-secret
    machine news.invalid login second password second-secret
    """)
    assert {opts[:username], opts[:password]} == {"first", "first-secret"}
  end

  test "a requested username selects its own password", c do
    assert {:ok, opts} = resolve(c, """
    machine news.invalid login other password other-secret
    machine news.invalid login requested password requested-secret
    """, username: "requested")
    assert {opts[:username], opts[:password]} == {"requested", "requested-secret"}
  end

  test "username filtering applies before port preference", c do
    assert {:ok, opts} = resolve(c, """
    machine news.invalid port 563 login other password other-secret
    machine news.invalid login requested password requested-secret
    """, username: "requested")
    assert {opts[:username], opts[:password]} == {"requested", "requested-secret"}
  end

  test "a requested username cannot borrow a different identity's password", c do
    assert {:error, :incomplete_credentials} = resolve(c,
      "machine news.invalid login other password other-secret", username: "requested")
  end

  test "password-only options cannot borrow a username from a file", c do
    assert {:error, :incomplete_credentials} = resolve(c,
      "machine news.invalid login user password file-secret", password: "explicit-secret")
  end

  test "fully supplied credentials do not read an unused unsafe file", c do
    path = write_auth(c, "machine news.invalid login other password other-secret")
    File.chmod!(path, 0o644)
    assert {:ok, opts} = Geri.Auth.resolve(host: "news.invalid", auth_file: path,
      username: "explicit", password: "explicit-secret")
    assert {opts[:username], opts[:password]} == {"explicit", "explicit-secret"}
  end

  test "selected credentials still require safe file permissions", c do
    path = write_auth(c, "machine news.invalid login user password secret")
    File.chmod!(path, 0o644)
    assert {:error, {:unsafe_auth_file_permissions, ^path, _}} =
             Geri.Auth.resolve(host: "news.invalid", auth_file: path)
  end

  test "a matching incomplete entry is rejected", c do
    assert {:error, :incomplete_credentials} = resolve(c, "machine news.invalid login user")
    assert {:error, :incomplete_credentials} = resolve(c, "machine news.invalid password secret")
  end

  test "a missing file permits anonymous use but cannot complete a username", c do
    opts = [host: "news.invalid", auth_file: Path.join(c.dir, "missing")]
    assert {:ok, ^opts} = Geri.Auth.resolve(opts)
    assert {:error, :incomplete_credentials} = Geri.Auth.resolve(Keyword.put(opts, :username, "user"))
  end

  test "the account alias and quoted credentials remain supported", c do
    assert {:ok, opts} = resolve(c,
      "machine news.invalid account 'user name' password 'secret with spaces'")
    assert {opts[:username], opts[:password]} == {"user name", "secret with spaces"}
  end

  for field <- [:username, :password], newline <- ["\r", "\n"] do
    test "#{field} containing #{inspect(newline)} is rejected in options and files", c do
      field = unquote(field)
      invalid = "value" <> unquote(newline) <> "POST"
      opts = [host: "news.invalid", auth_file: false, username: "user", password: "secret"]
      assert {:error, {:invalid_credentials, ^field}} =
               Geri.Auth.resolve(Keyword.put(opts, field, invalid))
      credentials = Keyword.put([username: "user", password: "secret"], field, invalid)
      login = credentials[:username]
      password = credentials[:password]
      assert {:error, {:invalid_credentials, ^field}} = resolve(c,
        "machine news.invalid login '#{login}' password '#{password}'")

      # A nil connection proves validation happens before accessing the socket.
      assert {:error, {:invalid_credentials, ^field}} =
               Geri.NNTP.authenticate(nil, login, password)
    end
  end

  defp resolve(c, contents, opts \\ []) do
    path = write_auth(c, contents)
    Geri.Auth.resolve(Keyword.merge([host: "news.invalid", port: 563, auth_file: path], opts))
  end

  defp write_auth(c, contents) do
    path = Path.join(c.dir, "authinfo")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end
end
