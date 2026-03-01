defmodule S3 do
  require Logger

  def client(base_url, region, access_key_id, secret_access_key) do
    Req.new(
      base_url: base_url,
      decode_body: false,
      aws_sigv4: [
        service: :s3,
        region: region,
        access_key_id: access_key_id,
        secret_access_key: secret_access_key
      ]
    )
  end

  def get_bucket_info(client, bucket) do
    client |> Req.get(url: "/#{bucket}")
  end

  def get_object(client, bucket, key) do
    client |> Req.get(url: "/#{bucket}/#{key}")
  end

  def put_object(client, bucket, key, body, opts \\ []) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 5 * 60_000)
    file_size = Keyword.get(opts, :file_size, nil)

    headers = if file_size, do: [{"content-length", to_string(file_size)}], else: []

    try do
      resp =
        client
        |> Req.put!(
          url: "/#{bucket}/#{key}",
          body: body,
          receive_timeout: receive_timeout,
          headers: headers
        )

      if resp.status in 200..299 do
        {:ok, resp}
      else
        {:error, "S3 returned status #{resp.status}: #{inspect(resp.body)}"}
      end
    rescue
      e ->
        Logger.error("Error uploading to S3: #{inspect(e)}")
        {:error, e}
    end
  end

  def create_multipart_upload(client, bucket, key) do
    resp = client |> Req.post!(url: "/#{bucket}/#{key}?uploads")

    if resp.status in 200..299 do
      upload_id = Regex.run(~r/<UploadId>(.*?)<\/UploadId>/, resp.body) |> Enum.at(1)
      {:ok, upload_id}
    else
      {:error, "Failed to initiate multipart upload: #{resp.status} - #{inspect(resp.body)}"}
    end
  end

  def upload_part(client, bucket, key, upload_id, part_number, file_path) do
    try do
      stream = File.stream!(file_path, [], 64 * 1024)
      # ensure it exists and get size
      %File.Stat{size: size} = File.stat!(file_path)

      resp =
        client
        |> Req.put!(
          url: "/#{bucket}/#{key}?partNumber=#{part_number}&uploadId=#{upload_id}",
          body: stream,
          headers: [{"content-length", to_string(size)}],
          receive_timeout: :infinity
        )

      if resp.status in 200..299 do
        etag = Req.Response.get_header(resp, "etag") |> hd()
        {:ok, etag}
      else
        {:error, "Failed to upload part #{part_number}: #{resp.status} - #{inspect(resp.body)}"}
      end
    rescue
      e ->
        Logger.error("Error uploading part #{part_number}: #{inspect(e)}")
        {:error, e}
    end
  end

  def complete_multipart_upload(client, bucket, key, upload_id, parts) do
    xml = """
    <CompleteMultipartUpload>
    #{parts |> Enum.map(fn {part_number, etag} -> "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>" end) |> Enum.join("")}
    </CompleteMultipartUpload>
    """

    resp =
      client
      |> Req.post!(
        url: "/#{bucket}/#{key}?uploadId=#{upload_id}",
        body: xml,
        headers: [{"content-type", "application/xml"}]
      )

    if resp.status in 200..299 do
      {:ok, resp}
    else
      {:error, "Failed to complete multipart upload: #{resp.status} - #{inspect(resp.body)}"}
    end
  end
end
