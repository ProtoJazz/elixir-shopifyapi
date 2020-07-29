defmodule ShopifyAPI.Bulk.Query do
  require Logger
  alias ShopifyAPI.AuthToken
  alias ShopifyAPI.Bulk.Cancel

  @type status_response :: map()
  @stream_http_timeout 5_000

  @polling_query """
  {
    currentBulkOperation {
      id
      status
      errorCode
      createdAt
      completedAt
      objectCount
      fileSize
      url
      partialDataUrl
    }
  }
  """

  @spec cancel(AuthToken.t(), String.t()) :: {:ok | :error, any()}
  def cancel(token, bulk_query_id) do
    query = """
    mutation {
      bulkOperationCancel(id: "#{bulk_query_id}") {
        bulkOperation {
          status
        }
        userErrors {
          field
          message
        }
      }
    }
    """

    # {
    #   "data": {
    #     "bulkOperationCancel": {
    #       "bulkOperation": {
    #         "status": "CANCELING"
    #       },
    #       "userErrors": []
    #     }
    #   },
    #   "extensions": {
    #     "cost": {
    #       "requestedQueryCost": 10,
    #       "actualQueryCost": 10,
    #       "throttleStatus": {
    #         "maximumAvailable": 1000.0,
    #         "currentlyAvailable": 990,
    #         "restoreRate": 50.0
    #       }
    #     }
    #   }
    # }

    case ShopifyAPI.graphql_request(token, query, 1) do
      {:ok, %{response: %{"bulkOperationCancel" => resp}}} -> {:ok, resp}
      error -> error
    end
  end

  @spec exec(AuthToken.t(), String.t(), list()) :: {:ok, String.t()} | {:error, any()}
  def exec(%AuthToken{} = token, query, opts) do
    with bulk_query <- bulk_query_string(query),
         {:ok, resp} <- ShopifyAPI.graphql_request(token, bulk_query, 10),
         :ok <- handle_errors(resp),
         bulk_query_id <- get_in(resp.response, ["bulkOperationRunQuery", "bulkOperation", "id"]),
         {:ok, url} <- poll(token, bulk_query_id, opts[:polling_rate], opts[:max_poll_count]) do
      {:ok, url}
    else
      {:error, :timeout, bulk_id} ->
        Cancel.perform(opts[:auto_cancel], token, bulk_id)

      error ->
        error
    end
  end

  # Shopify returns a single newline which gets stripped and we are left with garbage,
  # handle it nicely here.
  def fetch(nil), do: {:ok, ""}

  def fetch({:error, _} = error), do: error
  def fetch({:ok, url}), do: fetch(url)

  def fetch(url) when is_binary(url) do
    url
    |> HTTPoison.get()
    |> case do
      {:ok, %{body: jsonl}} -> {:ok, jsonl}
      error -> error
    end
  end

  @doc """
  Streams the HTTP GET of the passed in URL for JSONL decoding.

  Will raise a RuntimeError if HTTP response code is anything other then 200.

  Warning: Since HTTPoison spawns a seperate process which uses send/receive
  to stream HTTP fetches be careful where you use this.
  """
  @spec stream_fetch!(String.t() | {:ok, String.t()} | {:error, any()}) :: Enumerable.t()
  def stream_fetch!({:ok, url}), do: stream_fetch!(url)
  def stream_fetch!({:error, _} = error), do: error

  def stream_fetch!(url) when is_binary(url) do
    Logger.warn("HACKNEY_DEBUG: fetching #{inspect(url)}")
    url |> httpoison_streamed_get!() |> Stream.transform("", &transform_chunks_to_jsonl/2)
  end

  def parse_response!(""), do: []
  def parse_response!({:ok, jsonl}), do: parse_response!(jsonl)
  def parse_response!({:error, msg}), do: raise(ShopifyAPI.Bulk.QueryError, msg)

  def parse_response!(jsonl) when is_binary(jsonl),
    do: jsonl |> String.split("\n", trim: true) |> Enum.map(&ShopifyAPI.JSONSerializer.decode!/1)

  @spec status(AuthToken.t()) :: {:ok, status_response()} | {:error, any()}
  def status(%AuthToken{} = token) do
    token
    |> ShopifyAPI.graphql_request(@polling_query, 1)
    |> case do
      {:ok, %{response: %{"currentBulkOperation" => response}}} ->
        {:ok, response}

      {:error, _} = error ->
        error
    end
  end

  defp handle_errors(resp) do
    errors = get_in(resp.response, ["bulkOperationRunQuery", "userErrors"])

    case Enum.empty?(errors) do
      true -> :ok
      false -> {:error, fetch_first_error(errors)}
    end
  end

  defp bulk_query_string(query) do
    query_string = ShopifyAPI.JSONSerializer.encode!(query)

    """
    mutation {
      bulkOperationRunQuery(
        query: #{query_string}
      ) {
        bulkOperation {
          id
          status
        }
        userErrors {
          field
          message
        }
      }
    }
    """
  end

  defp fetch_first_error(errors) do
    errors
    |> List.first()
    |> Map.get("message")
  end

  defp poll(token, bulk_query_id, polling_rate, max_poll, depth \\ 0)

  defp poll(_token, bulk_query_id, _, max_poll, depth) when max_poll == depth,
    do: {:error, :timeout, bulk_query_id}

  defp poll(token, bulk_query_id, polling_rate, max_poll, depth) do
    Process.sleep(polling_rate)

    case status(token) do
      {:ok, %{"status" => "COMPLETED", "url" => url} = _response} -> {:ok, url}
      _ -> poll(token, bulk_query_id, polling_rate, max_poll, depth + 1)
    end
  end

  defp httpoison_streamed_get!(url) do
    Stream.resource(
      fn ->
        HTTPoison.get!(url, %{}, stream_to: self(), async: :once)
      end,
      fn %HTTPoison.AsyncResponse{id: id} = resp ->
        receive do
          %HTTPoison.AsyncStatus{id: ^id, code: 200} ->
            HTTPoison.stream_next(resp)
            {[], resp}

          %HTTPoison.AsyncStatus{id: ^id, code: code} ->
            raise("ShopifyAPI.Bulk stream fetch got non 200 code of: #{code}")

          %HTTPoison.AsyncHeaders{id: ^id, headers: _headers} ->
            HTTPoison.stream_next(resp)
            {[], resp}

          %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
            HTTPoison.stream_next(resp)
            {[chunk], resp}

          %HTTPoison.AsyncEnd{id: ^id} ->
            {:halt, resp}
        after
          @stream_http_timeout -> raise "receive timeout"
        end
      end,
      fn _resp -> :ok end
    )
  end

  defp transform_chunks_to_jsonl(element, acc) do
    # Our http chunks are not guaranteed to be on the line break, this splits up our
    # returned chunks by line break.
    element = acc <> element

    cond do
      # A nicely formatted jsonl line(s)
      # {\"test\":\"bar\"}\n{\"test\":\"baz\"}\n"
      String.ends_with?(element, "\n") ->
        {String.split(element, "\n", trim: true), ""}

      # Contains a jsonl line and then some
      # {\"test\":\"bar\"}\n{\"test\"
      String.contains?(element, "\n") ->
        {rem, e} =
          element
          |> String.split("\n", trim: true)
          |> List.pop_at(-1)

        {e, rem}

      # No complete jsonl document yet
      true ->
        {[], element}
    end
  end
end
