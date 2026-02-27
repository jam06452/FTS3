defmodule Fts3Web.UploadController do
  use Fts3Web, :controller

  require Logger

  # ============================================================================
  # FILE UPLOAD FLOW:
  # 1. Client chunks large files (5MB chunks) and sends each chunk to backend
  # 2. Backend receives each chunk and stores it temporarily on disk
  # 3. When all chunks received, backend assembles them into a single file
  # 4. Backend uploads the complete assembled file to Supabase Storage as one
  # 5. Cleanup: Remove temporary chunk files and assembled file from backend
  # ============================================================================

  @chunk_dir Path.join(System.tmp_dir!(), "fts3_uploads")
  # 10MB per chunk
  @max_chunk_size 10 * 1024 * 1024

  def create(conn, params) do
    try do
      upload_id = params["upload_id"]
      chunk_number = String.to_integer(params["chunk_number"])
      total_chunks = String.to_integer(params["total_chunks"])
      filename = params["filename"]

      with :ok <- validate_params(upload_id, chunk_number, total_chunks, filename),
           {:ok, chunk_data} <- extract_chunk_data(params["chunk"]),
           :ok <- validate_chunk_size(chunk_data),
           :ok <- ensure_chunk_dir(),
           :ok <- save_chunk(upload_id, chunk_number, chunk_data),
           response <- check_and_assemble(upload_id, total_chunks, filename) do
        send_json_response(conn, 200, response)
      else
        {:error, reason} ->
          Logger.error("Upload error for #{upload_id}: #{inspect(reason)}")
          cleanup_on_error(upload_id, total_chunks)
          send_json_response(conn, 400, %{"error" => inspect(reason)})
      end
    rescue
      e ->
        Logger.error("Upload exception: #{inspect(e)}")
        send_json_response(conn, 500, %{"error" => "Server error: #{inspect(e)}"})
    end
  end

  defp validate_params(upload_id, chunk_number, total_chunks, filename) do
    cond do
      not is_binary(upload_id) or upload_id == "" ->
        {:error, "Invalid upload_id"}

      chunk_number < 0 or total_chunks <= 0 or chunk_number >= total_chunks ->
        {:error, "Invalid chunk_number or total_chunks"}

      not is_binary(filename) or filename == "" ->
        {:error, "Invalid filename"}

      String.contains?(filename, ["/", "\\", "\0"]) ->
        {:error, "Invalid characters in filename"}

      String.length(filename) > 255 ->
        {:error, "Filename too long"}

      true ->
        :ok
    end
  end

  defp validate_chunk_size(chunk_data) when is_binary(chunk_data) do
    size = byte_size(chunk_data)

    if size > @max_chunk_size do
      {:error, "Chunk size #{size} exceeds maximum #{@max_chunk_size}"}
    else
      :ok
    end
  end

  defp extract_chunk_data(%Plug.Upload{path: path}) do
    File.read(path)
  end

  defp extract_chunk_data(data) when is_binary(data) do
    {:ok, data}
  end

  defp extract_chunk_data(_) do
    {:error, "Invalid chunk data"}
  end

  defp ensure_chunk_dir do
    File.mkdir_p(@chunk_dir)
  end

  defp save_chunk(upload_id, chunk_number, chunk_data) do
    chunk_path = chunk_filepath(upload_id, chunk_number)

    with :ok <- File.write(chunk_path, chunk_data) do
      Logger.debug("Saved chunk #{chunk_number} for upload #{upload_id}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to save chunk: #{inspect(reason)}")
        {:error, "Failed to save chunk: #{inspect(reason)}"}
    end
  end

  defp chunk_filepath(upload_id, chunk_number) do
    Path.join(@chunk_dir, "#{upload_id}_chunk_#{chunk_number}")
  end

  defp final_filepath(upload_id, filename) do
    Path.join(@chunk_dir, "#{upload_id}_final_#{filename}")
  end

  defp check_and_assemble(upload_id, total_chunks, filename) do
    chunk_files = get_chunk_files(upload_id, total_chunks)
    received_count = Enum.count(chunk_files)

    Logger.debug("Upload #{upload_id}: #{received_count}/#{total_chunks} chunks received")

    if received_count == total_chunks do
      Logger.info("All chunks received for #{upload_id}, assembling into single file...")

      case assemble_and_upload(upload_id, total_chunks, filename) do
        {:ok, response} ->
          Logger.info(
            "Upload #{upload_id} complete: #{filename} successfully uploaded to Supabase"
          )

          response

        {:error, reason} ->
          Logger.error("Assembly/upload failed for #{upload_id}: #{inspect(reason)}")
          %{"error" => inspect(reason)}
      end
    else
      %{
        "status" => "chunk_received",
        "chunks_received" => received_count,
        "total_chunks" => total_chunks,
        "upload_id" => upload_id
      }
    end
  end

  defp get_chunk_files(upload_id, total_chunks) do
    Enum.filter(0..(total_chunks - 1), fn i ->
      File.exists?(chunk_filepath(upload_id, i))
    end)
  end

  defp assemble_and_upload(upload_id, total_chunks, filename) do
    final_path = final_filepath(upload_id, filename)

    Logger.debug("Starting assembly of #{total_chunks} chunks for #{filename}")

    try do
      with {:ok, _} <- assemble_chunks(upload_id, total_chunks, final_path),
           {:ok, response} <- upload_to_supabase(final_path, filename) do
        Logger.info("Uploading complete file to Supabase: #{filename}")
        cleanup_chunks(upload_id, total_chunks, final_path)
        {:ok, response}
      else
        {:error, reason} ->
          cleanup_chunks(upload_id, total_chunks, final_path)
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Exception during assembly/upload: #{inspect(e)}")
        cleanup_chunks(upload_id, total_chunks, final_path)
        {:error, "Assembly error: #{inspect(e)}"}
    end
  end

  defp assemble_chunks(upload_id, total_chunks, final_path) do
    try do
      with {:ok, file} <- File.open(final_path, [:write, :binary]) do
        try do
          Logger.info("Assembling #{total_chunks} chunks into: #{final_path}")

          total_size =
            Enum.reduce_while(0..(total_chunks - 1), 0, fn chunk_num, acc ->
              chunk_path = chunk_filepath(upload_id, chunk_num)

              case File.read(chunk_path) do
                {:ok, chunk_data} ->
                  IO.binwrite(file, chunk_data)
                  new_size = acc + byte_size(chunk_data)

                  Logger.debug(
                    "Assembled chunk #{chunk_num + 1}/#{total_chunks} (accumulated: #{new_size} bytes)"
                  )

                  {:cont, new_size}

                {:error, reason} ->
                  Logger.error("Failed to read chunk #{chunk_num}: #{inspect(reason)}")
                  {:halt, {:error, "Missing chunk #{chunk_num}"}}
              end
            end)

          case total_size do
            {:error, reason} ->
              {:error, reason}

            size ->
              Logger.info(
                "Assembly complete: #{Path.basename(final_path)} (#{size} bytes) - Ready for single upload to Supabase"
              )

              {:ok, size}
          end
        after
          File.close(file)
        end
      end
    rescue
      e ->
        Logger.error("Assembly exception: #{inspect(e)}")
        {:error, "Assembly failed: #{inspect(e)}"}
    end
  end

  defp upload_to_supabase(file_path, filename) do
    with :ok <- validate_file_exists(file_path),
         {:ok, file_data} <- read_file_safely(file_path),
         file_size <- byte_size(file_data),
         timestamped_filename <- add_timestamp_to_filename(filename),
         :ok <- log_upload_start(timestamped_filename, file_size),
         {:ok, _response} <- upload_with_retry(file_data, timestamped_filename, 0) do
      public_url = build_public_url(timestamped_filename)
      shortened_url = shorten_url(public_url)

      {:ok,
       %{
         "status" => "success",
         "filename" => timestamped_filename,
         "message" => "File uploaded successfully",
         "public_url" => shortened_url
       }}
    else
      {:error, reason} ->
        Logger.error("Upload to supabase failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp add_timestamp_to_filename(filename) do
    # Get current datetime
    now = DateTime.now!("Etc/UTC")
    timestamp = Calendar.strftime(now, "%Y%m%d_%H%M%S")

    # Split filename into name and extension
    case String.split(filename, ".", parts: 2) do
      [name, ext] ->
        "#{name}_#{timestamp}.#{ext}"

      [name] ->
        "#{name}_#{timestamp}"
    end
  end

  defp read_file_safely(file_path) do
    case File.read(file_path) do
      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        Logger.error("Failed to read file #{file_path}: #{inspect(reason)}")
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp log_upload_start(filename, file_size) do
    # Log file info for debugging
    Logger.info("Starting upload: #{filename} (#{file_size} bytes)")
    :ok
  end

  defp validate_file_exists(file_path) do
    if File.exists?(file_path) do
      :ok
    else
      {:error, "Assembled file not found at #{file_path}"}
    end
  end

  defp upload_with_retry(file_data, filename, attempt) when attempt < 3 do
    Logger.debug("Upload attempt #{attempt + 1}/3 for #{filename}")

    case upload_to_storage(file_data, filename) do
      {:ok, response} ->
        Logger.info("Upload successful on attempt #{attempt + 1}")
        {:ok, response}

      {:error, reason} ->
        if attempt < 2 do
          wait_time = 1000 * (attempt + 1)

          Logger.warning(
            "Upload failed on attempt #{attempt + 1}, retrying in #{wait_time}ms: #{inspect(reason)}"
          )

          Process.sleep(wait_time)
          upload_with_retry(file_data, filename, attempt + 1)
        else
          Logger.error("Upload failed after 3 attempts: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  defp upload_to_storage(file_data, filename) do
    # Get Supabase config
    config = Application.get_env(:fts3, :supabase)
    base_url = config[:url]
    api_key = config[:key]
    bucket_name = config[:bucket]

    # URL-encode the filename to handle spaces and special characters
    encoded_filename = URI.encode(filename, &URI.char_unreserved?/1)

    # Construct the upload URL
    upload_url = "#{base_url}/storage/v1/object/#{bucket_name}/#{encoded_filename}"

    # Detect content type based on file extension
    content_type = get_content_type(filename)

    file_size = byte_size(file_data)

    Logger.info(
      "Single file upload to Supabase: #{filename} (#{file_size} bytes) as #{content_type}"
    )

    Logger.debug("Upload URL: #{upload_url}")

    try do
      # Upload the complete assembled file as a single request
      case Req.put(
             upload_url,
             body: file_data,
             headers: [
               {"Authorization", "Bearer #{api_key}"},
               {"Content-Type", content_type}
             ],
             receive_timeout: 600_000
           ) do
        {:ok, response} when response.status >= 200 and response.status < 300 ->
          Logger.info("Successfully uploaded to Supabase: #{filename} (HTTP #{response.status})")

          Logger.debug("Upload response headers: #{inspect(response.headers)}")
          {:ok, %{"filename" => filename}}

        {:ok, response} ->
          Logger.error(
            "Supabase upload failed for #{filename} (#{file_size} bytes): HTTP #{response.status}"
          )

          Logger.debug("Error response body: #{inspect(response.body)}")
          Logger.debug("Error response headers: #{inspect(response.headers)}")
          {:error, "Upload failed with HTTP #{response.status}"}

        {:error, reason} ->
          Logger.error(
            "Supabase upload failed for #{filename} (#{file_size} bytes): #{inspect(reason)}"
          )

          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Upload to Supabase exception: #{inspect(e)}")
        Logger.error("Exception stacktrace: #{inspect(__STACKTRACE__)}")
        {:error, "Upload error: #{inspect(e)}"}
    end
  end

  defp get_content_type(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".txt" -> "text/plain"
      ".csv" -> "text/csv"
      ".json" -> "application/json"
      ".zip" -> "application/zip"
      ".mp4" -> "video/mp4"
      ".mp3" -> "audio/mpeg"
      _ -> "application/octet-stream"
    end
  end

  defp build_public_url(filename) do
    config = Application.get_env(:fts3, :supabase)
    public_url = config[:public_url]
    bucket = config[:bucket]
    "#{public_url}/storage/v1/object/public/#{bucket}/#{filename}"
  end

  defp shorten_url(long_url) do
    try do
      case Req.post("https://url.jam06452.uk/make_url",
        json: %{"url" => long_url, "message" => false}
      ) do
        {:ok, response} ->
          case response.body do
            %{"encoded" => shortcode} ->
              "https://url.jam06452.uk/#{shortcode}"
            _ ->
              Logger.warning("Unexpected response from URL shortener: #{inspect(response.body)}")
              long_url
          end
        {:error, reason} ->
          Logger.warning("Failed to shorten URL: #{inspect(reason)}")
          long_url
      end
    rescue
      e ->
        Logger.warning("Exception when shortening URL: #{inspect(e)}")
        long_url
    end
  end

  defp cleanup_chunks(upload_id, total_chunks, final_path \\ nil) do
    Task.start(fn ->
      try do
        # Remove individual chunks
        Enum.each(0..(total_chunks - 1), fn chunk_num ->
          chunk_path = chunk_filepath(upload_id, chunk_num)

          case File.rm(chunk_path) do
            :ok ->
              :ok

            {:error, :enoent} ->
              # File already deleted
              :ok

            {:error, reason} ->
              Logger.warning("Failed to delete chunk #{chunk_num}: #{inspect(reason)}")
          end
        end)

        # Remove final file if specified
        if final_path && File.exists?(final_path) do
          case File.rm(final_path) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("Failed to delete final file: #{inspect(reason)}")
          end
        end

        Logger.debug("Cleaned up upload #{upload_id}")
      rescue
        e ->
          Logger.error("Cleanup error for #{upload_id}: #{inspect(e)}")
      end
    end)
  end

  defp cleanup_on_error(upload_id, total_chunks) do
    cleanup_chunks(upload_id, total_chunks)
  end

  defp send_json_response(conn, status, data) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  def uploader(conn, _params) do
    render(conn, :uploader)
  end
end
