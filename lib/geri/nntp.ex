defmodule Geri.NNTP do
  require Logger

  defstruct [:socket, :transport, :host]

  @connect_timeout 15_000
  @recv_timeout 30_000
  @max_response_length 512

  def connect(opts) do
    host = Keyword.fetch!(opts, :host)
    mode = tls_mode(opts)
    port = Keyword.get(opts, :port, default_port(mode))

    Logger.debug("#{log_prefix(opts)}connecting to #{host}:#{port} tls=#{mode}")

    case mode do
      :implicit ->
        connect_implicit(host, port, opts)

      :starttls ->
        connect_starttls(host, port, opts)

      :none ->
        connect_plain(host, port, opts)
    end
  end

  def authenticate(conn, username, password, opts \\ [])

  def authenticate(_conn, nil, nil, opts) do
    Logger.debug("#{log_prefix(opts)}authentication not configured")

    :ok
  end

  def authenticate(_conn, nil, _password, _opts) do
    {:error, :incomplete_credentials}
  end

  def authenticate(_conn, _username, nil, _opts) do
    {:error, :incomplete_credentials}
  end

  def authenticate(conn, username, password, opts) do
    with :ok <- Geri.Auth.validate_credentials(username, password) do
      authenticate_pair(conn, username, password, opts)
    end
  end

  defp authenticate_pair(conn, username, password, opts) do
    Logger.debug("#{log_prefix(opts)}sending AUTHINFO USER")

    case command(
           conn,
           "AUTHINFO USER #{username}",
           Keyword.put(opts, :suppress_command_log, true)
         ) do
      {:ok, 281, _} ->
        Logger.debug("#{log_prefix(opts)}authentication successful")

        :ok

      {:ok, 381, _} ->
        Logger.debug("#{log_prefix(opts)}sending AUTHINFO PASS")

        case command(
               conn,
               "AUTHINFO PASS #{password}",
               Keyword.put(opts, :suppress_command_log, true)
             ) do
          {:ok, 281, _} ->
            Logger.debug("#{log_prefix(opts)}authentication successful")

            :ok

          {:ok, code, message} ->
            {:error, {:authentication_failed, code, message}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, code, message} ->
        {:error, {:authentication_failed, code, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def command(conn, command, opts \\ []) do
    unless Keyword.get(opts, :suppress_command_log, false) do
      Logger.debug("#{log_prefix(opts)}sending #{command_name(command)}")
    end

    with :ok <- send_data(conn, command <> "\r\n") do
      recv_response(conn)
    end
  end

  def stat(conn, message_id, opts \\ []) do
    Logger.debug("#{log_prefix(opts)}sending STAT #{message_id}")

    case command(
           conn,
           "STAT #{message_id}",
           Keyword.put(opts, :suppress_command_log, true)
         ) do
      {:ok, 223, _} ->
        Logger.debug("#{log_prefix(opts)}STAT present #{message_id}")

        :present

      {:ok, 430, _} ->
        Logger.debug("#{log_prefix(opts)}STAT missing #{message_id}")

        :missing

      {:ok, code, message} ->
        {:error, {:stat_failed, code, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def post(conn, article, opts \\ []) when is_binary(article) do
    message_id =
      Keyword.get(
        opts,
        :message_id,
        "<unknown>"
      )

    with :ok <- validate_article(article) do
      Logger.debug("#{log_prefix(opts)}sending POST #{message_id}")

      case command(
             conn,
             "POST",
             Keyword.put(opts, :suppress_command_log, true)
           ) do
        {:ok, 340, _} ->
          post_article(
            conn,
            article,
            message_id,
            opts
          )

        {:ok, code, message} ->
          {:error, {:post_rejected, code, message}}

        {:error, reason} ->
          {:error, {:transport, :before_article, reason}}
      end
    end
  end

  def quit(nil), do: :ok
  def quit(conn) do
    # Send QUIT only between protocol operations; never wait on shutdown.
    send_data(conn, "QUIT\r\n")
    close(conn)
  end

  def close(nil), do: :ok
  def close(%__MODULE__{transport: :ssl, socket: socket}) do
    :ssl.close(socket)
  end

  def close(%__MODULE__{transport: :tcp, socket: socket}) do
    :gen_tcp.close(socket)
  end

  defp connect_implicit(host, port, opts) do
    hostname = String.to_charlist(host)

    case :ssl.connect(
           hostname,
           port,
           ssl_options(host, opts),
           @connect_timeout
         ) do
      {:ok, socket} ->
        conn = %__MODULE__{
          socket: socket,
          transport: :ssl,
          host: host
        }

        finish_connect(conn, host, port, opts)

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp connect_plain(host, port, opts) do
    case open_tcp(host, port) do
      {:ok, conn} ->
        finish_connect(conn, host, port, opts)

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp connect_starttls(host, port, opts) do
    with {:ok, conn} <- open_tcp(host, port),
         {:ok, conn} <- read_greeting(conn),
         {:ok, conn} <- starttls(conn, host, opts) do
      case maybe_mode_reader(conn, opts) do
        :ok ->
          Logger.debug("#{log_prefix(opts)}connected to #{host}:#{port} tls=starttls")

          {:ok, conn}

        {:error, _reason} = error ->
          close(conn)
          error
      end
    end
  end

  # The greeting arrives on the raw TCP socket; close it here on failure so a
  # rejected or unresponsive server does not leak the connection.
  defp read_greeting(conn) do
    case recv_response(conn) do
      {:ok, code, message} ->
        case accept_greeting(code, message) do
          :ok ->
            {:ok, conn}

          {:error, _reason} = error ->
            close(conn)
            error
        end

      {:error, _reason} = error ->
        close(conn)
        error
    end
  end

  defp finish_connect(conn, host, port, opts) do
    case recv_response(conn) do
      {:ok, code, message} ->
        case accept_greeting(code, message) do
          :ok ->
            case maybe_mode_reader(conn, opts) do
              :ok ->
                Logger.debug("#{log_prefix(opts)}connected to #{host}:#{port}")

                {:ok, conn}

              {:error, _reason} = error ->
                close(conn)
                error
            end

          {:error, _reason} = error ->
            close(conn)
            error
        end

      {:error, _reason} = error ->
        close(conn)
        error
    end
  end

  defp open_tcp(host, port) do
    hostname = String.to_charlist(host)

    options = [
      :binary,
      active: false,
      packet: :line,
      packet_size: @max_response_length
    ]

    case :gen_tcp.connect(
           hostname,
           port,
           options,
           @connect_timeout
         ) do
      {:ok, socket} ->
        {:ok,
         %__MODULE__{
           socket: socket,
           transport: :tcp,
           host: host
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_mode_reader(conn, opts) do
    if Keyword.get(opts, :reader, false) do
      Logger.debug("#{log_prefix(opts)}sending MODE READER")

      case command(
             conn,
             "MODE READER",
             Keyword.put(opts, :suppress_command_log, true)
           ) do
        {:ok, code, _message} when code in [200, 201] ->
          Logger.debug("#{log_prefix(opts)}reader mode enabled")

          :ok

        {:ok, code, message} ->
          {:error, {:mode_reader_failed, code, message}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp starttls(conn, host, opts) do
    Logger.debug("#{log_prefix(opts)}sending STARTTLS")

    case command(
           conn,
           "STARTTLS",
           Keyword.put(opts, :suppress_command_log, true)
         ) do
      {:ok, 382, _} ->
        upgrade_to_tls(conn, host, opts)

      {:ok, code, message} ->
        close(conn)
        {:error, {:starttls_rejected, code, message}}

      {:error, reason} ->
        close(conn)
        {:error, reason}
    end
  end

  defp upgrade_to_tls(
         %__MODULE__{
           transport: :tcp,
           socket: socket
         },
         host,
         opts
       ) do
    Logger.debug("#{log_prefix(opts)}starting TLS handshake")

    case :ssl.connect(
           socket,
           ssl_options(host, opts),
           @connect_timeout
         ) do
      {:ok, ssl_socket} ->
        Logger.debug("#{log_prefix(opts)}TLS handshake successful")

        {:ok,
         %__MODULE__{
           socket: ssl_socket,
           transport: :ssl,
           host: host
         }}

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, {:tls_handshake_failed, reason}}
    end
  end

  defp post_article(
         conn,
         article,
         message_id,
         opts
       ) do
    case send_article(conn, article) do
      :ok ->
        case recv_response(conn) do
          {:ok, 240, _} ->
            Logger.debug("#{log_prefix(opts)}article posted #{message_id}")

            :ok

          {:ok, code, message} ->
            {:error, {:post_rejected, code, message}}

          {:error, reason} ->
            {:error, {:transport, :uncertain, reason}}
        end

      {:error, reason} ->
        {:error, {:transport, :uncertain, reason}}
    end
  end

  defp ssl_options(host, opts) do
    hostname = String.to_charlist(host)

    base = [
      :binary,
      active: false,
      packet: :line,
      packet_size: @max_response_length,
      server_name_indication: hostname
    ]

    case Keyword.get(opts, :tls_verify, :peer) do
      :none ->
        [
          verify: :verify_none
        ] ++ base

      :peer ->
        trust =
          case Keyword.get(opts, :tls_ca_file) do
            nil ->
              [
                cacerts: :public_key.cacerts_get()
              ]

            path ->
              [
                cacertfile: String.to_charlist(path)
              ]
          end

        [
          verify: :verify_peer,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ trust ++ base
    end
  end

  defp recv_response(conn) do
    response =
      case recv_line(conn) do
        {:ok, line} -> parse_response(line)
        {:error, reason} -> {:error, {:recv_failed, reason}}
      end

    case response do
      {:error, _reason} = error ->
        # Never reuse an incomplete or malformed response stream.
        close(conn)
        error

      reply ->
        reply
    end
  end

  defp recv_line(%__MODULE__{transport: :ssl, socket: socket}) do
    :ssl.recv(
      socket,
      0,
      @recv_timeout
    )
  end

  defp recv_line(%__MODULE__{transport: :tcp, socket: socket}) do
    :gen_tcp.recv(
      socket,
      0,
      @recv_timeout
    )
  end

  defp send_data(
         %__MODULE__{
           transport: :ssl,
           socket: socket
         },
         data
       ) do
    case :ssl.send(socket, data) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  defp send_data(
         %__MODULE__{
           transport: :tcp,
           socket: socket
         },
         data
       ) do
    case :gen_tcp.send(socket, data) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  defp send_article(conn, article) do
    article = dot_stuff(article)

    payload =
      if String.ends_with?(
           article,
           "\r\n"
         ) do
        article <> ".\r\n"
      else
        article <> "\r\n.\r\n"
      end

    send_data(conn, payload)
  end

  defp dot_stuff(article) do
    article
    |> String.split("\r\n")
    |> Enum.map_join(
      "\r\n",
      fn
        "." <> rest ->
          ".." <> rest

        line ->
          line
      end
    )
  end

  defp validate_article(article) do
    cond do
      article == "" ->
        {:error, :empty_article}

      String.contains?(article, "\n") and
          String.contains?(
            String.replace(
              article,
              "\r\n",
              ""
            ),
            "\n"
          ) ->
        {:error, :invalid_line_ending}

      true ->
        :ok
    end
  end

  defp parse_response(line) when byte_size(line) > @max_response_length,
    do: {:error, :response_too_long}

  defp parse_response(line) do
    size = byte_size(line)

    if size >= 2 and
         binary_part(
           line,
           size - 2,
           2
         ) == "\r\n" do
      line
      |> binary_part(
        0,
        size - 2
      )
      |> parse_response_line()
    else
      {:error, {:invalid_line_ending, line}}
    end
  end

  defp parse_response_line(line) do
    case line do
      <<a, b, c, rest::binary>>
      when a in ?0..?9 and
             b in ?0..?9 and
             c in ?0..?9 ->
        code =
          (a - ?0) * 100 +
            (b - ?0) * 10 +
            (c - ?0)

        case rest do
          "" -> {:ok, code, ""}
          <<" ", message::binary>> -> {:ok, code, String.trim_leading(message, " ")}
          _ -> {:error, {:invalid_response, line}}
        end

      _ ->
        {:error, {:invalid_response, line}}
    end
  end

  defp accept_greeting(code, _message)
       when code in [200, 201] do
    :ok
  end

  defp accept_greeting(code, message) do
    {:error, {:unexpected_greeting, code, message}}
  end

  defp tls_mode(opts) do
    case Keyword.fetch(opts, :tls) do
      {:ok, mode}
      when mode in [:implicit, :starttls, :none] ->
        mode

      {:ok, mode} ->
        raise ArgumentError,
              "invalid tls mode: #{inspect(mode)}"

      :error ->
        case Keyword.get(opts, :ssl) do
          true ->
            :implicit

          false ->
            :none

          nil ->
            :implicit
        end
    end
  end

  defp default_port(:implicit), do: 563
  defp default_port(:starttls), do: 119
  defp default_port(:none), do: 119

  defp command_name(command) do
    command
    |> String.split(
      " ",
      parts: 3
    )
    |> case do
      ["AUTHINFO", "USER" | _] ->
        "AUTHINFO USER"

      ["AUTHINFO", "PASS" | _] ->
        "AUTHINFO PASS"

      [name | _] ->
        name
    end
  end

  defp log_prefix(opts) do
    case Keyword.get(opts, :worker) do
      nil ->
        ""

      worker ->
        "worker #{worker} "
    end
  end
end
