defmodule Geri.Options do
  @moduledoc false

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
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 -> :ok
      {:ok, %{type: :regular}} -> {:error, {:invalid_input, path, :empty_file}}
      {:ok, _} -> {:error, {:invalid_input, path, :not_regular_file}}
      {:error, reason} -> {:error, {:file_stat_failed, path, reason}}
    end
  end

  defp input(path), do: {:error, {:invalid_input, path, :path_required}}

  defp default_port(:implicit), do: 563
  defp default_port(_), do: 119
  defp invalid(key, reason), do: {:error, {:invalid_option, key, reason}}
end
