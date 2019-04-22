defmodule ShopifyAPI.AppServer do
  use GenServer
  require Logger

  @name :shopify_api_app_server

  def start_link(_opts) do
    Logger.info(fn -> "Starting #{__MODULE__}..." end)

    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def all, do: GenServer.call(@name, :all)

  def get(name), do: GenServer.call(@name, {:get, name})

  @spec count :: integer
  def count, do: GenServer.call(@name, :count)

  @spec set(%{:name => any, any => any} | String.t(), boolean | %{}) :: atom
  def set(value, call_persist \\ true)
  def set(%{name: name} = new_values, call_persist) when is_boolean(call_persist), do: set(name, new_values, call_persist)
  def set(name, new_values) when is_binary(name) and is_map(new_values), do: set(name, new_values, true)

  @spec set(String.t(), %{:name => any, any => any}, boolean) :: atom
  def set(name, new_values, true) do
    set(name, new_values, false)

    # TODO should this be in a seperate process? It could tie up the GenServer
    persist(app_server_config(:persistance), name, new_values)
  end

  def set(name, new_values, false), do: GenServer.cast(@name, {:set, name, new_values})

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
      |> app_server_config()
      |> call_initializer()
      |> Enum.reduce(state, &Map.put(&2, &1.name, &1))

    {:noreply, new_state}
  end

  @impl true
  @callback handle_cast(map, map) :: tuple
  def handle_cast({:set, name, new_values}, %{} = state) do
    new_state =
      update_in(state, [name], fn t ->
        case t do
          nil -> Map.merge(%ShopifyAPI.App{}, new_values)
          _ -> Map.merge(t, new_values)
        end
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:all, _caller, state), do: {:reply, state, state}

  @impl true
  def handle_call({:get, name}, _caller, state), do: {:reply, Map.fetch(state, name), state}

  @impl true
  def handle_call(:count, _caller, state), do: {:reply, Enum.count(state), state}

  defp app_server_config(key), do: Application.get_env(:shopify_api, ShopifyAPI.AppServer)[key]

  defp call_initializer({module, function, _}) when is_atom(module) and is_atom(function),
    do: apply(module, function, [])

  defp call_initializer(_), do: []

  defp persist({module, function, _}, key, value) when is_atom(module) and is_atom(function),
    do: apply(module, function, [key, value])

  defp persist(_, _, _), do: nil
end
