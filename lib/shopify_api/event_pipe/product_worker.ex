defmodule ShopifyApi.EventPipe.ProductWorker do
  @moduledoc """
  Worker for procecessing Products
  """
  use Toniq.Worker, max_concurrency: 10
  require Logger
  import ShopifyApi.EventPipe.Worker
  alias ShopifyApi.Rest.Product

  def perform(%{action: _, object: _, token: _} = event) do
    Logger.info(fn -> "#{__MODULE__} is processing an event: #{inspect(event)}" end)

    event
    |> Map.put(:response, call_shopify(event))
    |> fire_callback
  end

  defp call_shopify(%{action: :create, object: product} = event) do
    case fetch_token(event) do
      {:ok, token} ->
        Product.create(token, product)

      msg ->
        msg
    end
  end

  defp call_shopify(%{action: :update, object: product} = event) do
    case fetch_token(event) do
      {:ok, token} ->
        Product.update(token, product)

      msg ->
        msg
    end
  end

  defp call_shopify(%{action: action}), do: {:error, "Unhandled action #{action}"}
end