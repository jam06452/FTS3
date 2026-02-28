defmodule Fts3.Upload do
  @moduledoc """
  Handles chunked file uploads, reassembly, and S3 integration.
  """

  require Logger

  # 5MB is the minimum allowed for S3 multipart uploads
  @chunk_size 5 * 1024 * 1024

  def get_chunk_size, do: @chunk_size

  defp get_s3_config do
    case Application.get_env(:fts3, :s3, %{}) do
      %{} = cfg when map_size(cfg) == 0 ->
        nil

      cfg ->
        client =
          S3.client(
            cfg[:base_url] || "https://s3.amazonaws.com",
            cfg[:region] || "us-east-1",
            cfg[:access_key_id],
            cfg[:secret_access_key]
          )

        bucket = cfg[:bucket] || "default-bucket"
        %{client: client, bucket: bucket}
    end
  end

  @doc """
  Initiates a new S3 multipart upload.
  """
  def init_s3_upload(filename) do
    case get_s3_config() do
      nil ->
        Logger.warning("S3 configuration not found. Skipping upload to S3.")
        {:error, "S3 not configured"}

      %{client: client, bucket: bucket} ->
        s3_key = "uploads/#{filename}"
        Logger.info("Initiating multipart upload of #{s3_key} to S3 bucket #{bucket}")

        case S3.create_multipart_upload(client, bucket, s3_key) do
          {:ok, s3_upload_id} -> {:ok, s3_upload_id, s3_key}
          error -> error
        end
    end
  end

  @doc """
  Uploads a single chunk part directly to S3.
  """
  def upload_chunk_to_s3(s3_key, s3_upload_id, part_number, file_path) do
    case get_s3_config() do
      nil ->
        {:error, "S3 not configured"}

      %{client: client, bucket: bucket} ->
        S3.upload_part(client, bucket, s3_key, s3_upload_id, part_number, file_path)
    end
  end

  @doc """
  Completes the S3 multipart upload with all uploaded parts.
  """
  def complete_s3_upload(s3_key, s3_upload_id, parts) do
    # Map parts JSON or maps to correctly ordered tuples
    tuple_parts =
      Enum.map(parts, fn map ->
        p = Map.get(map, "part_number") || Map.get(map, :part_number)
        e = Map.get(map, "etag") || Map.get(map, :etag)
        p = if is_binary(p), do: String.to_integer(p), else: p
        {p, e}
      end)

    sorted_parts = Enum.sort_by(tuple_parts, fn {p, _} -> p end)

    case get_s3_config() do
      nil ->
        {:error, "S3 not configured"}

      %{client: client, bucket: bucket} ->
        Logger.info("Completing multipart upload to S3 for #{s3_key}")

        case S3.complete_multipart_upload(client, bucket, s3_key, s3_upload_id, sorted_parts) do
          {:ok, _} ->
            Logger.info("Successfully completed multipart upload to S3")
            {:ok, s3_key}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
