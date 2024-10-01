defmodule ExUnit.Server do
  @moduledoc false
  @name __MODULE__
  @timeout :infinity

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  def add_module(name, {async, parameterize}) do
    dbg({:add_module, name, %{async: async, parameterize: parameterize}})

    modules =
      if parameterize do
        Enum.map(parameterize, &{name, &1})
      else
        [{name, %{}}]
      end

    case GenServer.call(@name, {:add, async, modules}, @timeout) do
      :ok ->
        :ok

      :already_running ->
        raise "cannot add module named #{inspect(name)} to test suite after the suite starts running"
    end
  end

  def modules_loaded(uniq?) do
    GenServer.call(@name, {:modules_loaded, uniq?}, @timeout)
  end

  def take_async_modules(count) do
    GenServer.call(@name, {:take_async_modules, count}, @timeout)
  end

  def take_sync_modules() do
    GenServer.call(@name, :take_sync_modules, @timeout)
  end

  def restore_modules(async_modules, sync_modules) do
    GenServer.call(@name, {:restore_modules, async_modules, sync_modules}, @timeout)
  end

  ## Callbacks

  def init(:ok) do
    # Table used by OnExitHandler
    :ets.new(__MODULE__, [:public, :named_table, read_concurrency: true, write_concurrency: true])

    state = %{
      loaded: System.monotonic_time(),
      waiting: nil,
      async_module_groups: %{},
      async_modules: :queue.new(),
      sync_modules: :queue.new()
    }

    {:ok, state}
  end

  # Called on demand until we are signaled all modules are loaded.
  def handle_call({:take_async_modules, count}, from, %{waiting: nil} = state) do
    {:noreply, take_modules(%{state | waiting: {from, count}})}
  end

  # Called once after all async modules have been sent and reverts the state.
  def handle_call(:take_sync_modules, _from, state) do
    %{waiting: nil, loaded: :done, async_modules: async_modules} = state
    0 = :queue.len(async_modules)

    {:reply, :queue.to_list(state.sync_modules),
     %{state | sync_modules: :queue.new(), loaded: System.monotonic_time()}}
  end

  # Called by the runner when --repeat-until-failure is used.
  def handle_call({:restore_modules, async_modules, sync_modules}, _from, state) do
    {:reply, :ok,
     %{
       state
       | loaded: :done,
         async_modules: :queue.from_list(async_modules),
         sync_modules: :queue.from_list(sync_modules)
     }}
  end

  def handle_call({:modules_loaded, _}, _from, %{loaded: :done} = state) do
    {:reply, 0, state}
  end

  def handle_call({:modules_loaded, uniq?}, _from, %{loaded: loaded} = state)
      when is_integer(loaded) do
    state =
      if uniq? do
        async_module_groups =
          state.async_module_groups
          |> Enum.map(fn {group_name, q} ->
            async_modules = :queue.to_list(q) |> Enum.uniq() |> :queue.from_list()
            {group_name, async_modules}
          end)
          |> Map.new()

        sync_modules = :queue.to_list(state.sync_modules) |> Enum.uniq() |> :queue.from_list()

        %{
          state
          | async_module_groups: async_module_groups,
            sync_modules: sync_modules
        }
      else
        state
      end

    diff = System.convert_time_unit(System.monotonic_time() - loaded, :native, :microsecond)
    {:reply, diff, take_modules(%{state | loaded: :done})}
  end

  def handle_call({:add, async, names}, _from, %{loaded: loaded} = state)
      when is_integer(loaded) and async not in [false, nil] do
    state =
      Enum.reduce(names, state, fn name, updated_state ->
        async_group =
          case async do
            true -> default_async_group(name)
            [{:group, group_name}] -> group_name
            other -> raise "async can be true or [group: <group_name>], got: #{inspect(other)}"
          end

        updated_state
        |> update_in([:async_module_groups], fn async_module_groups ->
          {_, async_module_groups} =
            Map.get_and_update(async_module_groups, async_group, fn
              nil ->
                {nil, :queue.from_list([name])}

              q ->
                {q, :queue.in(name, q)}
            end)

          async_module_groups
        end)
        |> update_in([:async_modules], fn q -> :queue.in(async_group, q) end)
      end)
      |> dbg()

    {:reply, :ok, take_modules(state)}
  end

  def handle_call({:add, false, names}, _from, %{loaded: loaded} = state)
      when is_integer(loaded) do
    state =
      update_in(state.sync_modules, &Enum.reduce(names, &1, fn name, q -> :queue.in(name, q) end))

    {:reply, :ok, state}
  end

  def handle_call({:add, _async?, _names}, _from, state),
    do: {:reply, :already_running, state}

  defp default_async_group({module, %{}}) do
    module
  end

  defp default_async_group({module, params}) do
    "#{module}_#{:erlang.phash2(params)}"
  end

  defp take_modules(%{waiting: nil} = state) do
    state
  end

  defp take_modules(%{waiting: {from, count}} = state) do
    has_async_modules? = not :queue.is_empty(state.async_modules)

    cond do
      not has_async_modules? and state.loaded == :done ->
        GenServer.reply(from, nil)
        %{state | waiting: nil}

      not has_async_modules? ->
        state

      true ->
        {modules, async_modules} = take_until(count, state.async_modules)
        GenServer.reply(from, modules)
        %{state | async_modules: async_modules, waiting: nil}
    end
  end

  # :queue.split fails if the provided count is larger than the queue size;
  # as we also want to return the values as a list later, we directly
  # return {list, queue} instead of {queue, queue}
  defp take_until(n, queue), do: take_until(n, queue, [])

  defp take_until(0, queue, acc), do: {Enum.reverse(acc), queue}

  defp take_until(n, queue, acc) do
    case :queue.out(queue) do
      {{:value, item}, queue} -> take_until(n - 1, queue, [item | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end
end
