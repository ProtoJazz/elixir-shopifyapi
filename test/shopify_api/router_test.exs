defmodule ShopifyApi.RouterTest do
  use ExUnit.Case
  use Plug.Test
  import Test.Util

  @app_name "test"
  @redirect_uri "example.com"
  @shop_domain "shop.example.com"

  setup do
    ShopifyApi.AppServer.set(@app_name, %{
      name: @app_name,
      auth_redirect_uri: @redirect_uri,
      scope: "nothing"
    })

    ShopifyApi.ShopServer.set(%{domain: @shop_domain})
  end

  describe "/install" do
    test "with a valid app it redirects" do
      conn =
        conn(:get, "/install?app=#{@app_name}&shop=#{@shop_domain}")
        |> conn_parse()
        |> ShopifyApi.Router.call(%{})

      assert conn.status == 302

      {"location", redirect_uri} =
        Enum.find(conn.resp_headers, fn h -> elem(h, 0) == "location" end)

      parsed = URI.parse(redirect_uri)
      assert parsed.host == @shop_domain
    end

    test "without a valid app it errors" do
      conn =
        conn(:get, "/install?app=not-an-app")
        |> conn_parse()
        |> ShopifyApi.Router.call(%{})

      assert conn.status == 404
    end
  end

  describe "/authorized" do
    @code "testing"
    @token %{access_token: "test-token"}

    setup _contxt do
      bypass = Bypass.open()
      shop_domain = "localhost:#{bypass.port}"
      ShopifyApi.ShopServer.set(%{domain: shop_domain})

      {:ok, %{bypass: bypass, shop_domain: shop_domain}}
    end

    test "fetches the token", %{bypass: bypass, shop_domain: shop_domain} do
      Bypass.expect_once(bypass, "POST", "/admin/oauth/access_token", fn conn ->
        {:ok, body} = Poison.encode(@token)
        Plug.Conn.resp(conn, 200, body)
      end)

      conn =
        conn(:get, "/authorized/#{@app_name}?shop=#{shop_domain}&code=#{@code}&timestamp=1234")
        |> conn_parse()
        |> ShopifyApi.Router.call(%{})

      assert conn.status == 200
      {:ok, %{token: auth_token}} = ShopifyApi.AuthTokenServer.get(shop_domain, @app_name)
      assert auth_token == @token.access_token
    end

    test "fails without a valid app", %{bypass: bypass, shop_domain: shop_domain} do
      conn =
        conn(:get, "/authorized/invalid-app?shop=#{shop_domain}&code=#{@code}&timestamp=1234")
        |> conn_parse()
        |> ShopifyApi.Router.call(%{})

      assert conn.status == 404
    end

    test "fails without a valid shop", %{bypass: bypass} do
      conn =
        conn(:get, "/authorized/#{@app_name}?shop=invalid-shop&code=#{@code}&timestamp=1234")
        |> conn_parse()
        |> ShopifyApi.Router.call(%{})

      assert conn.status == 404
    end
  end
end
