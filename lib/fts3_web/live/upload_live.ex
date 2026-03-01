defmodule Fts3Web.UploadLive do
  use Fts3Web, :live_view

  alias Fts3.Upload

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    upload_id = generate_upload_id()

    socket =
      socket
      |> assign(:upload_id, upload_id)
      |> assign(:url, nil)
      |> assign(:uploading, false)
      |> assign(:progress, 0)
      |> assign(:total_chunks, 0)
      |> assign(:uploaded_chunks, 0)
      |> assign(:filename, "")
      |> assign(:file_size, 0)
      |> assign(:status, nil)
      |> assign(:error, nil)
      |> assign(:chunk_size, Upload.get_chunk_size())
      |> assign(:upload_start_time, nil)
      |> assign(:upload_speed_mbps, nil)

    {:ok, socket, layout: false}
  end

  @impl true
  def handle_event("file_selected", %{"_target" => ["file"]}, socket) do
    # File selection is handled by JavaScript in the hook
    # Just acknowledge the event
    {:noreply, socket}
  end

  @impl true
  def handle_event("file_info", %{"name" => filename, "size" => file_size}, socket) do
    total_chunks = calculate_chunks(file_size)

    {:noreply,
     socket
     |> assign(:filename, filename)
     |> assign(:file_size, file_size)
     |> assign(:total_chunks, total_chunks)
     |> assign(:error, nil)
     |> assign(:status, nil)}
  end

  @impl true
  def handle_event("start_upload", _params, socket) do
    filename = socket.assigns.filename

    case Upload.init_s3_upload(filename) do
      {:ok, s3_upload_id, s3_key} ->
        {:noreply,
         push_event(socket, "start_upload", %{s3_upload_id: s3_upload_id, s3_key: s3_key})}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Failed to initialize S3 upload: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("chunk_uploaded", %{"index" => index, "total" => total}, socket) do
    # Handle both string and integer values
    uploaded_int = if is_binary(index), do: String.to_integer(index), else: index
    total_int = if is_binary(total), do: String.to_integer(total), else: total

    uploaded = uploaded_int + 1
    progress = trunc(uploaded / total_int * 100)

    start_time = socket.assigns[:upload_start_time] || System.system_time(:millisecond)
    elapsed_ms = System.system_time(:millisecond) - start_time
    elapsed_s = max(elapsed_ms / 1000.0, 0.1)

    bytes_uploaded = min(uploaded * socket.assigns.chunk_size, socket.assigns.file_size)
    megabits = bytes_uploaded * 8 / 1_000_000
    speed_mbps = Float.round(megabits / elapsed_s, 2)

    socket =
      socket
      |> assign(:uploaded_chunks, uploaded)
      |> assign(:progress, progress)
      |> assign(:upload_speed_mbps, speed_mbps)

    new_socket =
      if uploaded == total_int do
        socket |> push_event("reassemble_and_upload", %{})
      else
        socket
      end

    {:noreply, new_socket}
  end

  @impl true
  def handle_event("upload_complete", params = %{"success" => true}, socket) do
    url = Map.get(params, "url")

    socket =
      socket
      |> assign(:uploading, false)
      |> assign(:progress, 100)
      |> assign(:status, "File uploaded to S3 successfully!")
      |> assign(:filename, "")
      |> assign(:file_size, 0)
      |> assign(:total_chunks, 0)
      |> assign(:uploaded_chunks, 0)
      |> assign(:progress, 0)
      |> assign(:upload_start_time, nil)
      |> assign(:upload_speed_mbps, nil)

    socket =
      if url do
        case shorten_url(url) do
          short_code when is_binary(short_code) ->
            assign(socket, :url, "https://url.jam06452.uk/#{short_code}")

          _ ->
            # Do not expose the long URL to the frontend. If shortening
            # fails, clear the URL so only the short URL
            # is ever shown in the UI.
            assign(socket, :url, nil)
        end
      else
        assign(socket, :url, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_complete", %{"success" => false, "error" => error}, socket) do
    {:noreply,
     socket
     |> assign(:uploading, false)
     |> assign(:error, error)}
  end

  @impl true
  def handle_event("upload_started", _, socket) do
    {:noreply,
     socket
     |> assign(:uploading, true)
     |> assign(:url, nil)
     |> assign(:upload_start_time, System.system_time(:millisecond))
     |> assign(:upload_speed_mbps, nil)}
  end

  @impl true
  def handle_event("copy_success", _params, socket) do
    {:noreply, socket |> put_flash(:info, "URL copied to clipboard!")}
  end

  defp calculate_chunks(file_size) do
    chunk_size = Upload.get_chunk_size()
    ceil(file_size / chunk_size)
  end

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_file_size(_), do: "0 B"

  defp generate_upload_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp extract_short_code(value) do
    cond do
      is_binary(value) ->
        case Regex.run(~r{url\.jam06452\.uk/([A-Za-z0-9_-]+)}, value) do
          [_, code] -> code
          _ -> if String.match?(value, ~r/^[A-Za-z0-9_-]{4,}$/), do: value, else: nil
        end

      is_map(value) ->
        value
        |> Map.values()
        |> Enum.find_value(nil, &extract_short_code/1)

      is_list(value) ->
        Enum.find_value(value, nil, &extract_short_code/1)

      true ->
        nil
    end
  end

  defp shorten_url(long_url) when is_binary(long_url) do
    try do
      resp = Req.post!("https://url.jam06452.uk/make_url", json: %{url: long_url, message: false})
      body = resp.body

      case extract_short_code(body) do
        nil ->
          if is_map(body) do
            Map.get(body, "code") || Map.get(body, "short") || Map.get(body, "short_url") ||
              Map.get(body, "short_code") || Map.get(body, "id")
          else
            nil
          end

        code ->
          code
      end
    rescue
      e ->
        Logger.error("URL shortening failed: #{inspect(e)}")
        nil
    end
  end
end
