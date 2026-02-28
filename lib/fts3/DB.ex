defmodule Fts3.DB do

  defp client do
  config = Application.get_env(:fts3, :S3)
  S3.client(config[:base_url], config[:region], config[:access_key_id], config[:secret_access_key])
  end

  def test do
    {:ok, response} = S3.get_bucket_info(client(), "fts3")
    response.body
  end

  def test2 do
    {:ok, response} = S3.get_object(client(), "fts3", "walter.txt")
    response.body
  end

  def test3 do
    {:ok, response} = S3.put_object(client(), "fts3", "test2.txt", "Hello, World!")
    response
  end
end
