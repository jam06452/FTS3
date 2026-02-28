defmodule S3 do
  def client(base_url, region, access_key_id, secret_access_key) do
    Req.new(
      base_url: base_url,
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

  def put_object(client, bucket, key, body) do
    client |> Req.put(url: "/#{bucket}/#{key}", body: body)
  end
end
