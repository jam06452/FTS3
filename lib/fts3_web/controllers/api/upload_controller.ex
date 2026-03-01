defmodule Fts3Web.API.UploadController do
  use Fts3Web, :controller

  alias Fts3.Upload

  require Logger

  @doc """
  Handle chunk upload.
  Expects:
    - upload_id: unique identifier for this upload session
    - chunk_index: 0-based index of the chunk
    - chunk_data: the actual chunk data
    - s3_upload_id: the S3 multipart upload ID
    - s3_key: S3 object key
  """
  def upload_chunk(
        conn,
        %{
          "upload_id" => _upload_id,
          "chunk_index" => chunk_index,
          "s3_upload_id" => s3_upload_id,
          "s3_key" => s3_key
        } = params
      ) do
    case params do
      %{"chunk_data" => %Plug.Upload{path: path}} ->
        chunk_index_int = String.to_integer(chunk_index)
        part_number = chunk_index_int + 1

        case Upload.upload_chunk_to_s3(s3_key, s3_upload_id, part_number, path) do
          {:ok, etag} ->
            File.rm(path)
            json(conn, %{success: true, index: chunk_index_int, etag: etag})

          {:error, reason} ->
            File.rm(path)
            Logger.error("Failed to save chunk to S3: #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{success: false, error: "Failed to save chunk to S3"})
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: "Missing chunk_data"})
    end
  end

  def upload_chunk(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{success: false, error: "Missing required parameters"})
  end

  @doc """
  Finalize upload by reassembling chunks and uploading to S3.
  Expects:
    - upload_id: unique identifier for this upload session
    - filename: original filename
    - file_size: total file size in bytes
    - s3_upload_id: S3 multipart upload ID
    - s3_key: S3 object key
    - parts: JSON encoded list of part ETags [{"part_number": 1, "etag": "..."}]
  """
  def finalize_upload(conn, %{
        "upload_id" => _upload_id,
        "filename" => filename,
        "file_size" => file_size,
        "s3_upload_id" => s3_upload_id,
        "s3_key" => s3_key,
        "parts" => parts
      }) do
    file_size_int = if is_binary(file_size), do: String.to_integer(file_size), else: file_size

    Logger.info(
      "Starting finalization for s3_key #{s3_key}, filename: #{filename}, size: #{file_size_int}"
    )

    case Upload.complete_s3_upload(s3_key, s3_upload_id, parts) do
      {:ok, _s3_key} ->
        url =
          "https://seaweed.jam06452.uk/buckets/fts3/uploads/" <>
            URI.encode(filename)

        json(conn, %{
          success: true,
          url: url
        })

      {:error, reason} ->
        Logger.error("S3 upload failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: "S3 upload failed: #{inspect(reason)}"})
    end
  end

  def finalize_upload(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{success: false, error: "Missing required parameters"})
  end
end
