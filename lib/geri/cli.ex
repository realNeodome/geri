defmodule Geri.CLI do
  @moduledoc "Command-line entry point for Geri."

  @switches [
    host: :string, port: :integer, tls: :string, tls_verify: :string,
    tls_ca_file: :string, username: :string, auth_file: :string,
    from: :string, name: :string, group: :keep, encoding: :string, part_size: :string,
    connections: :integer, comment: :string, nzb: :string,
    upload_key: :string, reader: :boolean,
    check_host: :string, check_port: :integer, check_tls: :string,
    check_tls_verify: :string, check_tls_ca_file: :string,
    check_username: :string, check_auth_file: :string,
    check_reader: :boolean, check_connections: :integer,
    repair_host: :string, repair_port: :integer, repair_tls: :string,
    repair_tls_verify: :string, repair_tls_ca_file: :string,
    repair_username: :string, repair_auth_file: :string,
    repair_reader: :boolean, repair_connections: :integer,
    reconnect_delay: :integer, message_id_domain: :string,
    tui: :boolean, verbose: :boolean,
    help: :boolean, version: :boolean
  ]

  @usage """
  Usage: geri upload [options] -- file1.bin [file2.bin ...]
         geri --help
         geri --version

  Posting:
    --host HOST              Posting server (required)
    --port PORT              NNTP port
    --tls MODE               implicit | starttls | none
    --tls-verify MODE        peer | none
    --tls-ca-file FILE       CA certificate file
    --username USER          Posting username
    --auth-file FILE         Authentication file (default ~/.authinfo or ~/.netrc)
    --reader / --no-reader   Reader mode
    --from ADDRESS           Bare email address (required)
    --name NAME              Sender display name (optional)
    --group GROUP            Newsgroup (repeatable, required)
    --encoding TYPE          yenc | uuencode | base64 (default yenc)
    --part-size SIZE         Bytes or K/M/G suffix (1024-based)
    --connections N          Posting connections (default 8)
    --comment TEXT           Subject comment
    --nzb FILE               NZB output
    --upload-key KEY         Fixed upload key; skip articles already on posting server

  Propagation checking:
    --check-host HOST        Enable ABB checking on this server
    --check-port PORT
    --check-tls MODE
    --check-tls-verify MODE
    --check-tls-ca-file FILE
    --check-username USER
    --check-auth-file FILE
    --check-reader / --no-check-reader
    --check-connections N

  Repair:
    --repair-host HOST       Separate repair server (default checking server)
    --repair-port PORT
    --repair-tls MODE
    --repair-tls-verify MODE
    --repair-tls-ca-file FILE
    --repair-username USER
    --repair-auth-file FILE
    --repair-reader / --no-repair-reader
    --repair-connections N

  General:
    --tui / --no-tui         TUI disabled by default; last flag wins
    --verbose                Debug logging
    --reconnect-delay MS
    --message-id-domain DOMAIN
    --help                   Show help
    --version                Show version

  Options must precede filenames. The -- separator is optional.

  TUI keys: p pause/resume; ` pause and inspect in IEx; q/Esc resume and hide the TUI.
  In IEx: resume.() returns to the TUI and resumes the upload.
  Ctrl-C cancels gracefully; a second Ctrl-C forces exit (geri.sh or TUI).

  Exit status: 0 success; 1 upload or repair failure; 2 inconclusive checking;
  130 cancelled.
  """

  def main(args) do
    handler = if System.get_env("GERI_SIGNAL_BRIDGE") == "1", do: Geri.Signals.install(), else: nil
    Process.put(:geri_signal_handler, handler)
    result = try do
      run(args)
    after
      Process.delete(:geri_signal_handler)
      if handler, do: Geri.Signals.uninstall(handler)
    end

    case result do
      :ok -> :ok
      {:error, {:cancelled, details}} ->
        IO.puts(:stderr, "geri: upload cancelled; upload key: #{details.upload_key}")
        System.halt(130)
      {:error, {:verification_inconclusive, summary}} ->
        IO.puts(:stderr, "geri: propagation verification inconclusive: #{verification_message(summary)}")
        System.halt(2)
      {:error, message} ->
        IO.puts(:stderr, "geri: #{message}\nTry 'geri --help'.")
        System.halt(1)
    end
  end

  def run(["--version"]) do
    version = Application.spec(:geri, :vsn) || ~c"unknown"
    IO.puts("Geri #{version}")
    :ok
  end

  def run(["--help"]) do
    IO.write(@usage)
    :ok
  end

  def run(["upload" | args]) do
    {before_separator, after_separator} = split_separator(args)

    with {:ok, opts, files} <- parse_options(before_separator, after_separator),
         :ok <- validate(opts, files) do
      if Keyword.get(opts, :help, false) do
        IO.write(@usage)
        :ok
      else
        if Keyword.get(opts, :version, false) do
          run(["--version"])
        else
          upload(files, opts)
        end
      end
    end
  end

  def run([]), do: {:error, "missing command"}
  def run([command | _]), do: {:error, "unknown command #{inspect(command)}"}

  defp split_separator(args) do
    {before, after_or_empty} = Enum.split_while(args, &(&1 != "--"))
    case after_or_empty do
      [] -> {before, nil}
      ["--" | files] -> {before, files}
    end
  end

  defp parse_options(args, separated_files) do
    {parsed, positional, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] -> {:error, "invalid option #{inspect(hd(invalid))}"}
      separated_files != nil and positional != [] ->
        {:error, "filenames must follow -- when a separator is used"}
      true ->
        groups = Keyword.get_values(parsed, :group)
        opts = parsed |> Keyword.delete(:group) |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse() |> Keyword.put(:newsgroups, groups)
        {:ok, opts, positional ++ (separated_files || [])}
    end
  end

  defp validate(opts, _files) do
    if Keyword.get(opts, :help, false) or Keyword.get(opts, :version, false) do
      :ok
    else
      with :ok <- validate_choice(opts, [:tls, :check_tls, :repair_tls],
             %{"implicit" => :implicit, "starttls" => :starttls, "none" => :none}),
           :ok <- validate_choice(opts, [:tls_verify, :check_tls_verify, :repair_tls_verify],
             %{"peer" => :peer, "none" => :none}),
           :ok <- validate_choice(opts, [:encoding],
             %{"uuencode" => :uuencode, "yenc" => :yenc, "base64" => :base64}),
           :ok <- validate_size(opts), do: :ok
    end
  end

  defp validate_choice(opts, keys, allowed) do
    Enum.reduce_while(keys, :ok, fn key, _ ->
      case Keyword.fetch(opts, key) do
        :error -> {:cont, :ok}
        {:ok, value} ->
          case Map.fetch(allowed, value) do
            {:ok, _atom} -> {:cont, :ok}
            :error -> {:halt, {:error, "invalid --#{cli_name(key)}: #{inspect(value)}"}}
          end
      end
    end)
  end

  defp validate_size(opts) do
    case Keyword.fetch(opts, :part_size) do
      :error -> :ok
      {:ok, size} ->
        if Regex.match?(~r/^[1-9][0-9]*[KMGkmg]?$/, size) do
          :ok
        else
          {:error, "invalid --part-size: #{inspect(size)}"}
        end
    end
  end

  defp upload(files, opts) do
    Logger.configure(
      level: if(Keyword.get(opts, :verbose, false), do: :debug, else: :info)
    )

    opts =
      opts
      |> Keyword.delete(:help)
      |> Keyword.delete(:version)
      |> Keyword.delete(:verbose)
      |> Keyword.put_new(:tui, false)
      |> Keyword.put(:signal_handler, Process.get(:geri_signal_handler))
      |> normalize_values()

    case Geri.upload(files, opts) do
      {:ok, _key} -> :ok
      :ok -> :ok
      {:error, {:cancelled, _details}} = error -> error
      {:error, {:verification_inconclusive, summary}} ->
        {:error, {:verification_inconclusive, summary}}
      {:error, {:verification_failed, summary, reasons}} ->
        {:error, "verification or repair failed: #{verification_message(summary)}; checking or repair errors: #{inspect(reasons)}"}
      {:error, {kind, reason, details}} when kind in [:upload_failed, :finalization_failed] ->
        {:error, "#{kind}: #{inspect(reason)}; upload key: #{details.upload_key}"}
      {:error, {:invalid_option, key, reason}} ->
        {:error, "--#{if(key == :newsgroups, do: "group", else: cli_name(key))} #{option_error(reason)}"}
      {:error, :files_required} -> {:error, "at least one file is required"}
      {:error, {:invalid_input, path, reason}} ->
        {:error, "invalid input #{inspect(path)}: #{input_error(reason)}"}
      {:error, {:file_stat_failed, path, reason}} ->
        {:error, "cannot inspect input #{inspect(path)}: #{:file.format_error(reason)}"}
      {:error, reason} -> {:error, "upload failed: #{inspect(reason)}"}
    end
  end

  defp input_error(:not_regular_file), do: "a regular file is required"
  defp input_error(:empty_file), do: "the file is empty"
  defp input_error(:invalid_filename), do: "the filename must be valid UTF-8 without line breaks or characters forbidden in XML"
  defp input_error(:path_required), do: "a filename is required"

  defp option_error(:email_address_required), do: "expects a bare ASCII email address; use --from \"geri@example.com\" --name \"Géri\""
  defp option_error(:header_text_required), do: "must be UTF-8 text without line breaks or NUL"
  defp option_error(:port_out_of_range), do: "must be an integer between 1 and 65535"
  defp option_error(:positive_integer_required), do: "must be a positive integer"
  defp option_error(:nonempty_text_required), do: "must be nonempty text without line breaks or NUL"
  defp option_error(:nonempty_groups_required), do: "requires at least one nonempty group"
  defp option_error(:checking_server_required), do: "requires --check-host"
  defp option_error(:unsupported_value), do: "has an unsupported value"
  defp option_error({:minimum_bytes, minimum}), do: "must be at least #{minimum} bytes for this encoding"

  defp verification_message(summary) do
    "upload key: #{summary.upload_key}; " <>
      "confirmed: #{summary.confirmed}, repaired: #{summary.repaired}, " <>
      "missing: #{summary.missing}, repair failed: #{summary.repair_failed}, " <>
      "inconclusive: #{summary.inconclusive}"
  end

  defp normalize_values(opts) do
    choices = [tls: %{"implicit" => :implicit, "starttls" => :starttls, "none" => :none},
               tls_verify: %{"peer" => :peer, "none" => :none},
               encoding: %{"uuencode" => :uuencode, "yenc" => :yenc, "base64" => :base64}]

    opts = Enum.reduce(choices, opts, fn {base, mapping}, acc ->
      keys = if base == :encoding, do: [base], else: [base, String.to_atom("check_#{base}"), String.to_atom("repair_#{base}")]
      Enum.reduce(keys, acc, fn key, inner ->
        case Keyword.fetch(inner, key) do
          {:ok, value} -> Keyword.put(inner, key, Map.fetch!(mapping, value))
          :error -> inner
        end
      end)
    end)

    case Keyword.fetch(opts, :part_size) do
      :error -> opts
      {:ok, size} ->
        {number, suffix} = Integer.parse(size)
        multiplier = case String.upcase(suffix) do
          "K" -> 1024
          "M" -> 1024 * 1024
          "G" -> 1024 * 1024 * 1024
          "" -> 1
        end
        Keyword.put(opts, :part_size, number * multiplier)
    end
  end

  defp cli_name(key), do: key |> Atom.to_string() |> String.replace("_", "-")
end
