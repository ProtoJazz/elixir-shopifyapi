defmodule ShopifyAPI.Plugs.WebhookTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Plug.Conn
  alias Plug.RequestId
  alias ShopifyAPI.Plugs.Webhook
  alias ShopifyAPI.{App, AppServer, JSONSerializer, Shop, ShopServer}

  @app %App{name: "test"}
  @shop %Shop{domain: "test-shop.example.com"}
  @req_body %{app: @app.name, shop: @shop.domain}

  def webhook_callback(v) do
    send(self(), {:webhook_callback, v})
  end

  setup do
    Application.put_env(:shopify_api, :webhook_filter, {__MODULE__, :webhook_callback, []})
    ShopServer.set(@shop)
    AppServer.set(@app)
  end

  test "401s with invalid hmac" do
    # Create a test connection
    conn =
      :post
      |> conn("/webhook/#{@app.name}", JSONSerializer.encode!(@req_body))
      |> Conn.put_req_header("x-shopify-hmac-sha256", "invalid")
      |> Conn.put_req_header("x-shopify-shop-domain", @shop.domain)

    # Invoke the plug
    conn = Webhook.call(conn, mount: "/webhook")

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 401
    assert conn.resp_body == "Not Authorized"
  end

  test "fires callback and 200s with valid hmac" do
    # Create a test connection
    conn =
      :post
      |> conn("/webhook/#{@app.name}?", JSONSerializer.encode!(@req_body))
      |> Conn.fetch_query_params()
      |> Conn.put_req_header(
        "x-shopify-hmac-sha256",
        "VsxCOHbZ+BlpaPvV4cpAiBk4v2Zc35BpRBP3bYiuiog="
      )
      |> Conn.put_req_header("x-shopify-shop-domain", @shop.domain)

    # Invoke the plug
    conn = Webhook.call(conn, mount: "/webhook")

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
    assert conn.resp_body == "ok."

    expected_event = %ShopifyAPI.EventPipe.Event{
      action: nil,
      app: @app,
      assigns: %{},
      callback: nil,
      destination: "client",
      object: %{"app" => @app.name, "shop" => @shop.domain},
      shop: @shop,
      token: %{}
    }

    assert_receive({:webhook_callback, ^expected_event})
  end

  test "includes Logger metadata in Event metadata" do
    request_id = "abcdefghijk1234567890"

    # Create a test connection
    conn =
      :post
      |> conn("/webhook/#{@app.name}?", JSONSerializer.encode!(@req_body))
      |> Conn.fetch_query_params()
      |> Conn.put_req_header(
        "x-shopify-hmac-sha256",
        "VsxCOHbZ+BlpaPvV4cpAiBk4v2Zc35BpRBP3bYiuiog="
      )
      |> Conn.put_req_header("x-shopify-shop-domain", @shop.domain)
      |> Conn.put_req_header("x-request-id", request_id)

    # Add RequestId to Logger metadata
    conn = RequestId.call(conn, "x-request-id")

    # Invoke the plug
    conn = Webhook.call(conn, mount: "/webhook")

    # Assert the Event metadata has request_id
    assert conn.state == :sent
    assert conn.status == 200

    expected_event = %ShopifyAPI.EventPipe.Event{
      action: nil,
      app: @app,
      assigns: %{},
      callback: nil,
      destination: "client",
      object: %{"app" => @app.name, "shop" => @shop.domain},
      shop: @shop,
      metadata: %{request_id: request_id},
      token: %{}
    }

    assert_receive({:webhook_callback, ^expected_event})
  end
end
