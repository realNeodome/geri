defmodule Geri.Article do
  @moduledoc """
  Builds NNTP articles and their deterministic identities from encoded parts.

  Encoders return `part/0` maps. The orchestrator adds file ordinals, offset,
  and a finalized subject before queueing. Body bytes determine identity along
  with reconstruction metadata; display truncation never changes these values.
  `t/0` holds the complete article before dot stuffing, plus unfolded encoded
  header values used for NZB output.
  """

  defstruct [:message_id, :data, :from, :subject]

  @type encoding :: :yenc | :base64 | :uuencode
  @typedoc "SHA-256 of source bytes, stored as 32 raw bytes rather than hexadecimal text."
  @type source_hash :: <<_::256>>
  @type crc32 :: 0..0xFFFFFFFF
  @typedoc "Protocol Message-ID including its angle brackets."
  @type message_id :: binary()

  @typedoc """
  Encoded part metadata, shared by encoder output and prepared posting items.
  File and part ordinals start at one; sizes and offset count unencoded bytes.
  Batch file ordinals and zero-based offset are added during preparation.
  yEnc positions are one-based inclusive; its subject starts nil and is assigned
  by the orchestrator. CRC/position fields are encoding-specific.
  """
  @type part :: %{
          required(:encoding) => encoding(),
          required(:filename) => binary(),
          required(:file_size) => pos_integer(),
          required(:part) => pos_integer(),
          required(:total) => pos_integer(),
          required(:source_hash) => source_hash(),
          required(:source_size) => pos_integer(),
          required(:subject) => binary() | nil,
          required(:body) => binary(),
          optional(:file_number) => pos_integer(),
          optional(:file_total) => pos_integer(),
          optional(:offset) => non_neg_integer(),
          optional(:begin) => pos_integer(),
          optional(:end) => pos_integer(),
          optional(:pcrc32) => crc32(),
          optional(:crc32) => crc32()
        }

  @type t :: %__MODULE__{
          message_id: message_id(),
          data: binary(),
          from: binary(),
          subject: binary()
        }

  @spec build(part(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(part, opts) do
    from = Keyword.fetch!(opts, :from)
    newsgroups = Keyword.fetch!(opts, :newsgroups)

    message_id =
      Keyword.get_lazy(opts, :message_id, fn ->
        generate_message_id(part, opts)
      end)

    with {:ok, from} <- Geri.Header.encode_from(from, Keyword.get(opts, :name)),
         {:ok, newsgroups} <- format_newsgroups(newsgroups),
         {:ok, subject} <- Geri.Header.encode_subject(part.subject),
         :ok <- validate_header(message_id) do
      date =
        DateTime.utc_now()
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")

      data =
        [
          "From: #{from}",
          "Newsgroups: #{newsgroups}",
          "Subject: #{subject}",
          "Message-ID: #{message_id}",
          "Date: #{date}"
        ]
        |> Enum.join("\r\n")
        |> Kernel.<>("\r\n\r\n")
        |> Kernel.<>(part.body)

      {:ok,
       %__MODULE__{
         message_id: message_id,
         data: data,
         from: Geri.Header.unfold(from),
         subject: Geri.Header.unfold(subject)
       }}
    end
  end

  defp generate_message_id(part, opts) do
    key = Keyword.fetch!(opts, :upload_key)

    domain =
      case part do
        %{encoding: :yenc, crc32: crc32} ->
          crc32_hex(crc32) <> ".geri"

        _ ->
          Keyword.get(opts, :message_id_domain, "geri.invalid")
      end

    identity =
      [
        # Version the identity: earlier builds hashed only source bytes and
        # could reuse an ID for parts with different reconstruction metadata.
        "GERI2",
        <<encoding_id(part.encoding)::8>>,
        <<byte_size(part.filename)::unsigned-big-32>>,
        part.filename,
        <<part.part::unsigned-big-64>>,
        <<part.total::unsigned-big-64>>,
        :crypto.hash(:sha256, part.body)
      ]
      |> IO.iodata_to_binary()

    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        identity
      )

    "<#{Base.url_encode64(digest, padding: false)}@#{domain}>"
  end

  defp format_newsgroups(groups) when is_list(groups) do
    case Enum.find(groups, &(validate_header(&1) != :ok)) do
      nil ->
        {:ok, Enum.join(groups, ",")}

      _ ->
        {:error, :invalid_header}
    end
  end

  defp format_newsgroups(groups) when is_binary(groups) do
    with :ok <- validate_header(groups) do
      {:ok, groups}
    end
  end

  defp validate_header(value) when is_binary(value) do
    if String.contains?(value, ["\r", "\n", <<0>>]) do
      {:error, :invalid_header}
    else
      :ok
    end
  end

  defp crc32_hex(crc) do
    crc
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  defp encoding_id(:uuencode), do: 1
  defp encoding_id(:base64), do: 2
  defp encoding_id(:yenc), do: 3
end
