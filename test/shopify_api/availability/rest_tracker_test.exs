defmodule ShopifyAPI.Availability.RESTTrackerTest do
  use ExUnit.Case

  alias HTTPoison.Response
  alias ShopifyAPI.AuthToken
  alias ShopifyAPI.Availability.RESTTracker

  describe "api_hit_limit/2" do
    test "returns a 2000 ms delay" do
      call_limit_header = {"X-Shopify-Shop-Api-Call-Limit", "50/50"}
      retry_after_header = {"Retry-After", "2.0"}

      response = %Response{headers: [{"foo", "bar"}, call_limit_header, retry_after_header]}
      token = %AuthToken{app_name: "test", shop_name: "shop"}

      assert {0, 2000} == RESTTracker.api_hit_limit(token, response)
    end
  end

  describe "update_api_call_limit/2" do
    test "back off for 1000 ms when 0 is left" do
      call_limit_header = {"X-Shopify-Shop-Api-Call-Limit", "50/50"}

      response = %Response{headers: [{"foo", "bar"}, call_limit_header]}
      token = %AuthToken{app_name: "test", shop_name: "shop"}

      assert {0, 1000} == RESTTracker.update_api_call_limit(token, response)
    end

    test "does not back off if there is a limit left" do
      call_limit_header = {"X-Shopify-Shop-Api-Call-Limit", "40/50"}

      response = %Response{headers: [{"foo", "bar"}, call_limit_header]}
      token = %AuthToken{app_name: "test", shop_name: "shop"}

      assert {10, 0} == RESTTracker.update_api_call_limit(token, response)
    end
  end

  describe "get/1" do
    test "handles get without having set" do
      now = ~U[2020-01-01 12:00:00.000000Z]
      token = %AuthToken{app_name: "empty", shop_name: "empty"}

      assert {40, 0} == RESTTracker.get(token, now)
    end

    test "returns with a sleep after hitting limit" do
      call_limit_header = {"X-Shopify-Shop-Api-Call-Limit", "50/50"}
      retry_after_header = {"Retry-After", "2.0"}
      response = %Response{headers: [{"foo", "bar"}, call_limit_header, retry_after_header]}
      token = %AuthToken{app_name: "hit_limit", shop_name: "hit_limit"}

      hit_time = ~U[2020-01-01 12:00:00.000000Z]

      assert {0, 2000} == RESTTracker.api_hit_limit(token, response, hit_time)

      assert {0, 2000} == RESTTracker.get(token, hit_time)

      wait_a_second = ~U[2020-01-01 12:00:01.100000Z]

      assert {0, 900} == RESTTracker.get(token, wait_a_second)

      wait_two_seconds = ~U[2020-01-01 12:00:02.100000Z]

      assert {0, 0} == RESTTracker.get(token, wait_two_seconds)
    end
  end
end
