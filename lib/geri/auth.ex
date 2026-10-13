defmodule Geri.Auth do
  import Bitwise

  def resolve(opts) do
    host = opts[:host]

    with :ok <- validate_value(:username, opts[:username]),
         :ok <- validate_value(:password, opts[:password]) do
      if not is_nil(opts[:password]) or not is_binary(host) do
        with :ok <- validate_credentials(opts[:username], opts[:password]), do: {:ok, opts}
      else
        with {:ok, credentials} <- find_credentials(host, effective_port(opts), opts) do
          resolved = opts
            |> put_if_missing(:username, credentials[:login])
            |> put_if_missing(:password, credentials[:password])

          with :ok <- validate_credentials(resolved[:username], resolved[:password]),
            do: {:ok, resolved}
        end
      end
    end
  end

  def validate_credentials(username, password) do
    with :ok <- validate_value(:username, username),
         :ok <- validate_value(:password, password) do
      case {username, password} do
        {nil, nil} -> :ok
        {nil, _} -> {:error, :incomplete_credentials}
        {_, nil} -> {:error, :incomplete_credentials}
        _ -> :ok
      end
    end
  end

  defp validate_value(_field, nil), do: :ok
  defp validate_value(field, value) when is_binary(value) do
    if String.contains?(value, ["\r", "\n"]),
      do: {:error, {:invalid_credentials, field}}, else: :ok
  end
  defp validate_value(field, _value), do: {:error, {:invalid_credentials, field}}

  defp find_credentials(host, port, opts) do
    auth_files(opts)
    |> Enum.reduce_while({:ok, nil}, fn path, {:ok, best} ->
      case read_file(path, host, port, opts[:username]) do
        {:ok, credentials} ->
          best = if credential_rank(credentials) < credential_rank(best), do: credentials, else: best
          result = {:ok, best}
          if credential_rank(best) == {0, 0}, do: {:halt, result}, else: {:cont, result}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, credentials} -> {:ok, credentials || %{}}
      error -> error
    end
  end

  defp auth_files(opts) do
    case Keyword.get(
           opts,
           :auth_file
         ) do
      nil ->
        home =
          System.user_home!()

        [
          Path.join(
            home,
            ".authinfo"
          ),
          Path.join(
            home,
            ".netrc"
          )
        ]

      false ->
        []

      path when is_binary(path) ->
        [path]
    end
  end

  defp read_file(
         path,
         host,
         port,
         username
       ) do
    case File.stat(path) do
      {:ok, stat} ->
        with :ok <-
               validate_permissions(
                 path,
                 stat.mode
               ),
             {:ok, contents} <-
               File.read(path),
             {:ok, entries} <-
               parse(contents) do
          {:ok,
           select(
             entries,
             host,
             port,
             username
           )}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:auth_file, path, reason}}
    end
  end

  defp validate_permissions(
         path,
         mode
       ) do
    if (mode &&& 0o077) == 0 do
      :ok
    else
      {:error, {:unsafe_auth_file_permissions, path, mode &&& 0o777}}
    end
  end

  defp parse(contents) do
    with {:ok, tokens} <-
           tokenize(contents) do
      {:ok,
       tokens
       |> parse_tokens(
         [],
         nil
       )
       |> Enum.reverse()}
    end
  end

  defp parse_tokens(
         [],
         entries,
         nil
       ) do
    entries
  end

  defp parse_tokens(
         [],
         entries,
         current
       ) do
    [current | entries]
  end

  defp parse_tokens(
         ["machine", host | rest],
         entries,
         current
       ) do
    entries =
      maybe_add_entry(
        entries,
        current
      )

    parse_tokens(
      rest,
      entries,
      %{
        machine: host
      }
    )
  end

  defp parse_tokens(
         ["default" | rest],
         entries,
         current
       ) do
    entries =
      maybe_add_entry(
        entries,
        current
      )

    parse_tokens(
      rest,
      entries,
      %{
        machine: :default
      }
    )
  end

  defp parse_tokens(
         ["account", value | rest],
         entries,
         current
       )
       when not is_nil(current) do
    parse_tokens(
      rest,
      entries,
      Map.put(
        current,
        :login,
        value
      )
    )
  end

  defp parse_tokens(
         [key, value | rest],
         entries,
         current
       )
       when key in [
              "login",
              "password",
              "port"
            ] and
              not is_nil(current) do
    atom_key =
      String.to_existing_atom(key)

    parse_tokens(
      rest,
      entries,
      Map.put(
        current,
        atom_key,
        value
      )
    )
  end

  defp parse_tokens(
         [_token | rest],
         entries,
         current
       ) do
    parse_tokens(
      rest,
      entries,
      current
    )
  end

  defp maybe_add_entry(
         entries,
         nil
       ) do
    entries
  end

  defp maybe_add_entry(
         entries,
         entry
       ) do
    [entry | entries]
  end

  defp select(
         entries,
         host,
         port,
         username
       ) do
    entries
    |> Enum.filter(fn entry ->
        machine_matches?(
          entry.machine,
          host
        ) and
          port_matches?(
            entry[:port],
            port
          ) and (is_nil(username) or entry[:login] == username)
    end)
    |> Enum.min_by(&credential_rank/1, fn -> nil end)
  end

  defp credential_rank(nil), do: {2, 2}
  defp credential_rank(entry) do
    {if(entry.machine == :default, do: 1, else: 0), if(is_nil(entry[:port]), do: 1, else: 0)}
  end

  defp machine_matches?(
         :default,
         _host
       ) do
    true
  end

  defp machine_matches?(
         configured,
         host
       ) do
    configured == host
  end

  defp port_matches?(
         nil,
         _port
       ) do
    true
  end

  defp port_matches?(
         configured,
         port
       ) do
    to_string(configured) ==
      to_string(port)
  end

  defp tokenize(contents) do
    contents
    |> String.to_charlist()
    |> scan_tokens(
      [],
      [],
      nil,
      false
    )
  end

  defp scan_tokens(
         [],
         tokens,
         current,
         nil,
         false
       ) do
    {:ok,
     finish_token(
       tokens,
       current
     )
     |> Enum.reverse()}
  end

  defp scan_tokens(
         [],
         _tokens,
         _current,
         quote,
         _comment
       )
       when quote in [?', ?"] do
    {:error, :unterminated_auth_quote}
  end

  defp scan_tokens(
         [],
         tokens,
         current,
         nil,
         true
       ) do
    {:ok,
     finish_token(
       tokens,
       current
     )
     |> Enum.reverse()}
  end

  defp scan_tokens(
         [char | rest],
         tokens,
         current,
         quote,
         true
       ) do
    if char == ?\n do
      scan_tokens(
        rest,
        tokens,
        current,
        quote,
        false
      )
    else
      scan_tokens(
        rest,
        tokens,
        current,
        quote,
        true
      )
    end
  end

  defp scan_tokens(
         [char | rest],
         tokens,
         current,
         nil,
         false
       )
       when char in [?', ?"] do
    scan_tokens(
      rest,
      tokens,
      current || [],
      char,
      false
    )
  end

  defp scan_tokens(
         [char | rest],
         tokens,
         current,
         quote,
         false
       )
       when char == quote and
              quote in [?', ?"] do
    scan_tokens(
      rest,
      tokens,
      current,
      nil,
      false
    )
  end

  defp scan_tokens(
         [?# | rest],
         tokens,
         current,
         nil,
         false
       ) do
    scan_tokens(
      rest,
      finish_token(
        tokens,
        current
      ),
      nil,
      nil,
      true
    )
  end

  defp scan_tokens(
         [char | rest],
         tokens,
         current,
         nil,
         false
       )
       when char in [32, 9, 10, 13] do
    scan_tokens(
      rest,
      finish_token(
        tokens,
        current
      ),
      nil,
      nil,
      false
    )
  end

  defp scan_tokens(
         [char | rest],
         tokens,
         current,
         quote,
         false
       ) do
    current =
      [char | current || []]

    scan_tokens(
      rest,
      tokens,
      current,
      quote,
      false
    )
  end

  defp finish_token(
         tokens,
         nil
       ) do
    tokens
  end

  defp finish_token(
         tokens,
         chars
       ) do
    token =
      chars
      |> Enum.reverse()
      |> List.to_string()

    [token | tokens]
  end

  defp put_if_missing(
         opts,
         _key,
         nil
       ) do
    opts
  end

  defp put_if_missing(
         opts,
         key,
         value
       ) do
    case Keyword.get(
           opts,
           key
         ) do
      nil ->
        Keyword.put(
          opts,
          key,
          value
        )

      _value ->
        opts
    end
  end

  defp effective_port(opts) do
    case Keyword.get(
           opts,
           :port
         ) do
      nil ->
        case Keyword.get(
               opts,
               :tls,
               :implicit
             ) do
          :implicit ->
            563

          _ ->
            119
        end

      port ->
        port
    end
  end
end
