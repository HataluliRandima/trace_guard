defmodule TraceGuard.TestApp.Pricing do
  @moduledoc false
  # A GenServer that opts in with `use TraceGuard.Server` and uses @impl.
  use GenServer
  use TraceGuard.Server

  alias TraceGuard.TestApp

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

  @impl true
  def init(name), do: {:ok, %{name: name, later: nil}}

  @impl true
  def handle_call({:quote, source, _secret}, _from, state) do
    TestApp.emit_query(source)
    {:reply, {:ok, source}, state}
  end

  def handle_call({:fail, source}, _from, state) do
    TestApp.emit_query(source)
    raise TestApp.BoomError, message: "pricing failed"
    {:reply, :never, state}
  end

  def handle_call({:block, test_pid}, _from, state) do
    send(test_pid, {:blocked, self()})

    receive do
      :go -> TestApp.emit_query("after_block")
    end

    {:reply, :released, state}
  end

  def handle_call({:throw_reply, value}, _from, state) do
    TestApp.emit_query("throw_reply")
    throw({:reply, value, state})
  end

  def handle_call({:nested, other, source}, _from, state) do
    TestApp.emit_query("outer_#{source}")
    {:reply, TraceGuard.call(other, {:quote, "inner_#{source}", nil}), state}
  end

  def handle_call({:reply_later, source}, from, state) do
    TestApp.emit_query("before_noreply_#{source}")
    send(self(), {:reply_now, from, source})
    {:noreply, state}
  end

  def handle_call(:plain, _from, state) do
    TestApp.emit_query("plain_call")
    {:reply, :plain, state}
  end

  def handle_call(:context, _from, state), do: {:reply, TraceGuard.Context.current(), state}

  @impl true
  def handle_cast(:background, state) do
    TestApp.emit_query("background_cast")
    {:noreply, state}
  end

  @impl true
  def handle_info({:reply_now, from, source}, state) do
    TestApp.emit_query("deferred_#{source}")
    GenServer.reply(from, {:ok, :later})
    {:noreply, state}
  end

  def handle_info(:background, state) do
    TestApp.emit_query("background_info")
    {:noreply, state}
  end
end

defmodule TraceGuard.TestApp.PlainServer do
  @moduledoc false
  # A GenServer that does NOT use TraceGuard.Server (and no @impl).
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
  def init(:ok), do: {:ok, nil}
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end
