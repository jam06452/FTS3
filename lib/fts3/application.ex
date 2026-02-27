defmodule Fts3.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Fts3Web.Telemetry,
      {DNSCluster, query: Application.get_env(:fts3, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fts3.PubSub},
      # Start a worker by calling: Fts3.Worker.start_link(arg)
      # {Fts3.Worker, arg},
      # Start to serve requests, typically the last entry
      Fts3Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fts3.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Fts3Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
