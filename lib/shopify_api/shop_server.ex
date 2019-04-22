defmodule ShopifyAPI.ShopServer do
  use GenServer

  require Logger

  alias ShopifyAPI.Shop

  @name :shopify_api_shop_server

  def start_link(_opts) do
    Logger.info(fn -> "Starting #{__MODULE__}..." end)

    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def all, do: GenServer.call(@name, :all)

  def get(domain), do: GenServer.call(@name, {:get, domain})

  @spec count :: integer
  def count, do: GenServer.call(@name, :count)

  def set(new_values, call_persist \\ true)

  @spec set(%{:domain => any, any => any}, boolean) :: atom
  def set(%{domain: domain} = new_values, false), do: GenServer.cast(@name, {:set, domain, new_values})

  def set(%{domain: domain} = new_values, true) do
    set(new_values, false)

    # TODO should this be in a seperate process? It could tie up the GenServer
    persist(shop_server_config(:persistance), domain, new_values)
  end

  #
  # Callbacks
  #

  @impl true
  def init(state), do: {:ok, state, {:continue, :initialize}}

  @impl true
  @callback handle_continue(atom, map) :: tuple
  def handle_continue(:initialize, state) do
    new_state =
      :initializer
      |> shop_server_config()
      |> call_initializer()
      |> Enum.reduce(state, &Map.put(&2, &1.domain, &1))

    {:noreply, new_state}
  end

  @impl true
  @callback handle_cast(map, map) :: tuple
  def handle_cast({:set, domain, new_values}, %{} = state) do
    new_state = Map.update(state, domain, %Shop{domain: domain}, &Map.merge(&1, new_values))

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:all, _caller, state), do: {:reply, state, state}

  @impl true
  def handle_call({:get, domain}, _caller, state), do: {:reply, Map.fetch(state, domain), state}

  @impl true
  def handle_call(:count, _caller, state), do: {:reply, Enum.count(state), state}

  defp shop_server_config(key), do: Application.get_env(:shopify_api, ShopifyAPI.ShopServer)[key]

  defp call_initializer({module, function, _}) when is_atom(module) and is_atom(function),
    do: apply(module, function, [])

  defp call_initializer(_), do: []

  defp persist({module, function, _}, key, value) when is_atom(module) and is_atom(function),
    do: apply(module, function, [key, value])

  defp persist(_, _, _), do: nil
end
