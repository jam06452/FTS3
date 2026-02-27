defmodule Fts3Web.PageController do
  use Fts3Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
