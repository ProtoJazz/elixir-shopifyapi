defmodule ShopifyAPI.Application do
  use Application

  alias ShopifyAPI.Availability

  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    Availability.RESTTracker.init()

    # Define workers and child supervisors to be supervised
    children = []

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ShopifyAPI.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
