defmodule Fts3.DB do
  defp client do
    config = Application.get_env(:fts3, :s3)

    S3.client(
      config[:S3_BASE_URL],
      config[:S3_REGION],
      config[:S3_ACCESS_KEY_ID],
      config[:S3_SECRET_ACCESS_KEY]
    )
  end

  def test do
    {:ok, response} = S3.get_bucket_info(client(), "fts3")
    response.body
  end

  def test2 do
    {:ok, response} = S3.get_object(client(), "fts3", "6hodgw-3058468067.png")
    response.body
  end

  def upload(file_name, file_content) do
    {:ok, response} = S3.put_object(client(), "fts3", file_name, file_content)
    response.body
  end
end
