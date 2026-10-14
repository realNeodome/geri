defmodule Geri.Header do
  @moduledoc false

  # Reserve room for the field name and continuation whitespace. Every word
  # contains complete UTF-8 codepoints and is at most 64 ASCII characters.
  @chunk_bytes 39

  def address(value) when is_binary(value) do
    case :binary.split(value, "@", [:global]) do
      [local, domain] when local != "" and domain != "" ->
        if not Enum.all?(:binary.bin_to_list(value), &(&1 in 33..126)) or
             String.contains?(value, ["<", ">", "(", ")", "[", "]", "\"", "\\", ",", ";", ":"]),
           do: {:error, :email_address_required},
           else: :ok

      _ ->
        {:error, :email_address_required}
    end
  end

  def address(_), do: {:error, :email_address_required}

  def text(value) when is_binary(value) do
    cond do
      String.contains?(value, ["\r", "\n", <<0>>]) -> {:error, :invalid_header}
      is_binary(:unicode.characters_to_binary(value, :utf8, :utf8)) -> :ok
      true -> {:error, :invalid_header}
    end
  end

  def text(_), do: {:error, :invalid_header}

  def encode_subject(value) do
    with :ok <- text(value), do: {:ok, encode_text(value)}
  end

  def encode_from(address, name \\ nil) do
    with :ok <- address(address),
         :ok <- optional_text(name) do
      case name do
        name when name in [nil, ""] ->
          {:ok, address}

        _ ->
          phrase = name_phrase(name)
          mailbox = "<" <> address <> ">"
          last_line = phrase |> String.split("\r\n") |> List.last()
          prefix = if String.contains?(phrase, "\r\n"), do: 0, else: 6

          separator =
            if prefix + byte_size(last_line) + 1 + byte_size(mailbox) > 76, do: "\r\n ", else: " "

          {:ok, phrase <> separator <> mailbox}
      end
    end
  end

  def display_from(address, name \\ nil) do
    if name in [nil, ""], do: address, else: quote_name(name) <> " <" <> address <> ">"
  end

  def unfold(value), do: String.replace(value, "\r\n ", " ")

  defp optional_text(nil), do: :ok
  defp optional_text(value), do: text(value)

  defp name_phrase(name) do
    if encoded?(name), do: encode_words(name), else: quote_name(name)
  end

  defp quote_name(name) do
    "\"" <> (name |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
  end

  defp encode_text(value) do
    if encoded?(value), do: encode_words(value), else: value
  end

  defp encoded?(value) do
    Regex.match?(~r/[^\x20-\x7e]/, value) or String.contains?(value, "=?")
  end

  defp encode_words(value) do
    value
    |> String.codepoints()
    |> Enum.chunk_while(
      "",
      fn point, chunk ->
        if byte_size(chunk) + byte_size(point) > @chunk_bytes,
          do: {:cont, chunk, point},
          else: {:cont, chunk <> point}
      end,
      fn
        "" -> {:cont, []}
        chunk -> {:cont, chunk, ""}
      end
    )
    |> Enum.map_join("\r\n ", &("=?UTF-8?B?" <> Base.encode64(&1) <> "?="))
  end
end
