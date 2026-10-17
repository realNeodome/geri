defmodule Geri.Options do
  @moduledoc """
  Validates upload inputs and resolves effective endpoint settings.

  Endpoint helpers accept unresolved or resolved keyword options so execution
  and JobState display use the same defaults. They perform no network or
  credential lookup; repair's independent-endpoint flag guides credential
  inheritance in Geri.
  """

  def normalize(paths, opts) do
    paths = if is_binary(paths), do: [paths], else: paths

    with :ok <- keyword_options(opts),
         opts =
           Keyword.merge(
             Geri.defaults() ++
               [
                 tls_verify: :peer,
                 check_connections: 2,
                 repair_connections: 2,
                 reconnect_delay: 5_000
               ],
             opts
           ),
         :ok <- text_option(opts, :host, true),
         :ok <- text_option(opts, :from, true),
         :ok <- sender(opts),
         :ok <- header_option(opts, :comment),
         :ok <- text_option(opts, :check_host, false),
         :ok <- text_option(opts, :repair_host, false),
         :ok <- repair_dependency(opts),
         {:ok, groups} <- groups(opts[:newsgroups]),
         :ok <- choices(opts),
         :ok <- numbers(opts),
         {:ok, size} <- part_size(opts),
         :ok <- inputs(paths) do
      opts =
        opts
        |> Keyword.put(:newsgroups, groups)
        |> Keyword.put(:part_size, size)
        |> Keyword.put_new(:port, default_port(opts[:tls]))

      {:ok, paths, opts}
    end
  end

  @doc "Returns the effective posting address and transport."
  @spec posting_endpoint(keyword()) :: keyword()
  def posting_endpoint(opts) do
    tls = Keyword.get(opts, :tls, :implicit)
    [host: opts[:host], port: opts[:port] || default_port(tls), tls: tls]
  end

  @doc "Returns checking session settings, or nil when checking is disabled."
  @spec check_endpoint(keyword()) :: keyword() | nil
  def check_endpoint(opts) do
    case opts[:check_host] do
      nil ->
        nil

      host ->
        tls = Keyword.get(opts, :check_tls, :implicit)

        [
          host: host,
          port: opts[:check_port] || default_port(tls),
          tls: tls,
          reader: Keyword.get(opts, :check_reader, false),
          tls_verify: Keyword.get(opts, :check_tls_verify, :peer),
          tls_ca_file: opts[:check_tls_ca_file]
        ]
    end
  end

  # A different listener or transport is a separate repair endpoint even when
  # its hostname is inherited. Only ABB inherits B's session defaults and login.
  @doc "Returns repair independence and settings, or {false, nil} without checking."
  @spec repair_endpoint(keyword()) :: {boolean(), keyword() | nil}
  def repair_endpoint(opts) do
    case check_endpoint(opts) do
      nil ->
        {false, nil}

      checking ->
        # Resolve B locally as callers may not have passed through auth setup.
        opts = Keyword.merge(opts, check_port: checking[:port], check_tls: checking[:tls])
        resolve_repair_endpoint(opts)
    end
  end

  defp resolve_repair_endpoint(opts) do
    separate_listener =
      not is_nil(opts[:repair_host]) or
        (not is_nil(opts[:repair_port]) and opts[:repair_port] != opts[:check_port])

    tls =
      Keyword.get(opts, :repair_tls, if(separate_listener, do: :implicit, else: opts[:check_tls]))

    port =
      Keyword.get(
        opts,
        :repair_port,
        if(separate_listener or tls != opts[:check_tls],
          do: default_port(tls),
          else: opts[:check_port]
        )
      )

    separate = separate_listener or tls != opts[:check_tls]

    defaults =
      if separate do
        [reader: false, tls_verify: :peer, tls_ca_file: nil]
      else
        [
          reader: Keyword.get(opts, :check_reader, false),
          tls_verify: Keyword.get(opts, :check_tls_verify, :peer),
          tls_ca_file: opts[:check_tls_ca_file]
        ]
      end

    endpoint = [
      host: opts[:repair_host] || opts[:check_host],
      port: port,
      tls: tls,
      reader: Keyword.get(opts, :repair_reader, defaults[:reader]),
      tls_verify: Keyword.get(opts, :repair_tls_verify, defaults[:tls_verify]),
      tls_ca_file: Keyword.get(opts, :repair_tls_ca_file, defaults[:tls_ca_file])
    ]

    {separate, endpoint}
  end

  defp keyword_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_options}
  end

  defp text_option(opts, key, required) do
    case opts[key] do
      nil when not required ->
        :ok

      value when is_binary(value) ->
        if String.trim(value) != "" and not String.contains?(value, ["\r", "\n", <<0>>]),
          do: :ok,
          else: invalid(key, :nonempty_text_required)

      _ ->
        invalid(key, :nonempty_text_required)
    end
  end

  defp repair_dependency(opts) do
    if not is_nil(opts[:repair_host]) and is_nil(opts[:check_host]),
      do: invalid(:repair_host, :checking_server_required),
      else: :ok
  end

  defp groups(value) when is_binary(value), do: groups(String.split(value, ","))

  defp groups(value) when is_list(value) and value != [] do
    if Enum.all?(value, fn group ->
         is_binary(group) and String.trim(group) != "" and
           not String.contains?(group, ["\r", "\n", <<0>>])
       end), do: {:ok, value}, else: invalid(:newsgroups, :nonempty_groups_required)
  end

  defp groups(_), do: invalid(:newsgroups, :nonempty_groups_required)

  defp choices(opts) do
    allowed = [
      encoding: [:yenc, :base64, :uuencode],
      tls: [:implicit, :starttls, :none],
      check_tls: [:implicit, :starttls, :none],
      repair_tls: [:implicit, :starttls, :none],
      tls_verify: [:peer, :none],
      check_tls_verify: [:peer, :none],
      repair_tls_verify: [:peer, :none]
    ]

    Enum.reduce_while(allowed, :ok, fn {key, values}, :ok ->
      case Keyword.fetch(opts, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} ->
          if value in values, do: {:cont, :ok}, else: {:halt, invalid(key, :unsupported_value)}
      end
    end)
  end

  defp numbers(opts) do
    keys = [
      :port,
      :check_port,
      :repair_port,
      :connections,
      :check_connections,
      :repair_connections,
      :reconnect_delay
    ]

    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Keyword.fetch(opts, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} ->
          port = key in [:port, :check_port, :repair_port]

          if is_integer(value) and value > 0 and (not port or value <= 65535),
            do: {:cont, :ok},
            else:
              {:halt,
               invalid(key, if(port, do: :port_out_of_range, else: :positive_integer_required))}
      end
    end)
  end

  defp part_size(opts) do
    size = opts[:part_size]

    minimum =
      case opts[:encoding] do
        :base64 -> 57
        :uuencode -> 45
        :yenc -> 1
      end

    if is_integer(size) and size >= minimum,
      do: {:ok, div(size, minimum) * minimum},
      else: invalid(:part_size, {:minimum_bytes, minimum})
  end

  defp inputs(paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case input(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp inputs(_), do: {:error, :files_required}

  defp input(path) when is_binary(path) do
    with :ok <- input_filename(path) do
      input_stat(path)
    end
  end

  defp input(path), do: {:error, {:invalid_input, path, :path_required}}

  defp input_filename(path) do
    case Geri.Filename.validate(Path.basename(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_input, path, reason}}
    end
  end

  defp input_stat(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 -> :ok
      {:ok, %{type: :regular}} -> {:error, {:invalid_input, path, :empty_file}}
      {:ok, _} -> {:error, {:invalid_input, path, :not_regular_file}}
      {:error, reason} -> {:error, {:file_stat_failed, path, reason}}
    end
  end

  defp sender(opts) do
    with :ok <- header_option(opts, :name) do
      case Geri.Header.address(opts[:from]) do
        :ok -> :ok
        {:error, reason} -> invalid(:from, reason)
      end
    end
  end

  defp header_option(opts, key) do
    case opts[key] do
      nil -> :ok
      value ->
        case Geri.Header.text(value) do
          :ok -> :ok
          {:error, _} -> invalid(key, :header_text_required)
        end
    end
  end

  defp default_port(:implicit), do: 563
  defp default_port(_), do: 119
  defp invalid(key, reason), do: {:error, {:invalid_option, key, reason}}
end
