defmodule Geri.NZB do
  require Logger

  defstruct [
    :io,
    :path,
    :temp_path
  ]

  def open(path) do
    temp_path = path <> ".part"

    cond do
      File.exists?(path) ->
        {:error, {:nzb_exists, path}}

      File.exists?(temp_path) ->
        {:error, {:nzb_temp_exists, temp_path}}

      true ->
        Logger.info("creating NZB #{temp_path}")

        case File.open(
               temp_path,
               [:write, :binary]
             ) do
          {:ok, io} ->
            :ok =
              IO.binwrite(
                io,
                header()
              )

            {:ok,
             %__MODULE__{
               io: io,
               path: path,
               temp_path: temp_path
             }}

          {:error, reason} ->
            {:error, {:nzb_open_failed, reason}}
        end
    end
  end

  def write_file(
        %__MODULE__{} = nzb,
        file
      ) do
    Logger.debug(
      "writing NZB file #{file.file_number} " <>
        "with #{map_size(file.segments)} segments"
    )

    :ok =
      IO.binwrite(
        nzb.io,
        file_xml(file)
      )

    Logger.info(
      "NZB recorded file #{file.file_number} " <>
        "\"#{file.filename}\""
    )

    :ok
  end

  def finalize(%__MODULE__{} = nzb) do
    Logger.debug("finalizing NZB #{nzb.path}")

    :ok =
      IO.binwrite(
        nzb.io,
        "</nzb>\n"
      )

    with :ok <-
           File.close(nzb.io),
         :ok <-
           File.rename(
             nzb.temp_path,
             nzb.path
           ) do
      Logger.info("NZB finalized #{nzb.path}")

      :ok
    else
      {:error, reason} ->
        {:error, {:nzb_finalize_failed, reason}}
    end
  end

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
