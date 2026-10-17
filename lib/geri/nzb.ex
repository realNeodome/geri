defmodule Geri.NZB do
  @moduledoc """
  Serializes NZB file blocks and publishes completed output without replacement.

  JobState owns the writer and buffers file metadata. Expected file/device
  failures return tagged errors here; callers do not need to recognize writer
  exceptions. Invalid metadata is a programming error and is not rescued.
  Finalization closes the writer, hard-links the completed temporary file to
  the final path, then removes the temporary name. Failed publication retains
  the temporary file and never overwrites an occupied destination.
  """

  require Logger

  defstruct [
    :io,
    :path,
    :temp_path
  ]

  @type t :: %__MODULE__{io: pid(), path: binary(), temp_path: binary()}

  @typedoc "A successful segment: bytes count the complete article before dot stuffing."
  @type segment :: %{bytes: non_neg_integer(), message_id: binary()}

  @typedoc """
  Per-file output metadata buffered by JobState. Subject is nil until part one
  completes; write_file requires that subject and all planned segments exist.
  Poster/subject contain unfolded MIME-encoded header values; serialization
  applies XML escaping. Segment Message-IDs have no angle brackets.
  """
  @type file_metadata :: %{
          file_number: pos_integer(),
          filename: binary(),
          total_parts: pos_integer(),
          poster: binary(),
          date: integer(),
          subject: binary() | nil,
          groups_used: MapSet.t(binary()),
          segments: %{pos_integer() => segment()}
        }

  @type open_error ::
          {:nzb_exists, binary()} | {:nzb_temp_exists, binary()} | {:nzb_open_failed, term()}
  @type write_error :: {:nzb_write_failed, {:error, term()}}
  @type finalize_error :: {:nzb_finalize_failed, term()}

  @spec open(binary()) :: {:ok, t()} | {:error, open_error()}
  def open(path) do
    temp_path = path <> ".part"

    cond do
      match?({:ok, _}, File.lstat(path)) ->
        {:error, {:nzb_exists, path}}

      true ->
        Logger.info("creating NZB #{temp_path}")

        case File.open(
               temp_path,
               [:write, :binary, :exclusive]
             ) do
          {:ok, io} ->
            case :file.write(io, header()) do
              :ok ->
                {:ok, %__MODULE__{io: io, path: path, temp_path: temp_path}}

              {:error, reason} ->
                File.close(io)
                {:error, {:nzb_open_failed, reason}}
            end

          {:error, :eexist} ->
            {:error, {:nzb_temp_exists, temp_path}}

          {:error, reason} ->
            {:error, {:nzb_open_failed, reason}}
        end
    end
  end

  @doc "Writes one complete file block; failed writes leave the writer for caller cleanup."
  @spec write_file(t(), file_metadata()) :: :ok | {:error, write_error()}
  def write_file(
        %__MODULE__{} = nzb,
        file
      ) do
    Logger.debug(
      "writing NZB file #{file.file_number} " <>
        "with #{map_size(file.segments)} segments"
    )

    case :file.write(nzb.io, file_xml(file)) do
      :ok ->
        Logger.info("NZB recorded file #{file.file_number} \"#{file.filename}\"")
        :ok

      {:error, _reason} = error ->
        # Retain the established file-block error envelope used in job results.
        {:error, {:nzb_write_failed, error}}
    end
  end

  @spec finalize(t()) :: :ok | {:error, finalize_error()}
  def finalize(%__MODULE__{} = nzb) do
    Logger.debug("finalizing NZB #{nzb.path}")

    with :ok <- :file.write(nzb.io, "</nzb>\n"),
         :ok <- File.close(nzb.io),
         :ok <-
           File.ln(
             nzb.temp_path,
             nzb.path
           ),
         :ok <-
           File.rm(nzb.temp_path) do
      Logger.info("NZB finalized #{nzb.path}")

      :ok
    else
      {:error, reason} ->
        # Close after a footer/close failure too. A second close may fail, but
        # must not replace the original publication error or remove .part.
        File.close(nzb.io)
        {:error, {:nzb_finalize_failed, reason}}
    end
  end

  @spec abort(t()) :: :ok
  def abort(%__MODULE__{} = nzb) do
    File.close(nzb.io)

    Logger.warning("NZB incomplete; leaving #{nzb.temp_path}")

    :ok
  end

  defp file_xml(file) do
    [
      "  <file poster=\"",
      escape_attribute(file.poster),
      "\" date=\"",
      Integer.to_string(file.date),
      "\" subject=\"",
      escape_attribute(file.subject),
      "\">\n",
      "    <groups>\n",
      groups_xml(file.groups_used),
      "    </groups>\n",
      "    <segments>\n",
      segments_xml(file.segments),
      "    </segments>\n",
      "  </file>\n"
    ]
  end

  defp groups_xml(groups) do
    groups
    |> Enum.sort()
    |> Enum.map(fn group ->
      [
        "      <group>",
        escape_text(group),
        "</group>\n"
      ]
    end)
  end

  defp segments_xml(segments) do
    segments
    |> Enum.sort_by(fn {number, _segment} ->
      number
    end)
    |> Enum.map(fn {number, segment} ->
      [
        "      <segment bytes=\"",
        Integer.to_string(segment.bytes),
        "\" number=\"",
        Integer.to_string(number),
        "\">",
        escape_text(segment.message_id),
        "</segment>\n"
      ]
    end)
  end

  defp escape_attribute(value) do
    value
    |> escape_text()
    |> String.replace(
      "\"",
      "&quot;"
    )
    |> String.replace(
      "'",
      "&apos;"
    )
  end

  defp escape_text(value) do
    value
    |> String.replace(
      "&",
      "&amp;"
    )
    |> String.replace(
      "<",
      "&lt;"
    )
    |> String.replace(
      ">",
      "&gt;"
    )
  end

  defp header do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">
    <nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
    """
  end
end
