defmodule Vera.Queue.MessageProducer do
  use GenStage

  def start_link(initial_messages \\ []) do
    GenStage.start_link(__MODULE__, initial_messages, name: __MODULE__)
  end

  def init(messages) do
    {:producer, messages}
  end

  def handle_demand(demand, state) when demand > 0 do
    {to_dispatch, remaining} = Enum.split(state, demand)
    {:noreply, to_dispatch, remaining}
  end

  # Optionally, add a function to enqueue messages dynamically:
  def enqueue(message) do
    GenStage.cast(__MODULE__, {:enqueue, message})
  end

  def handle_cast({:enqueue, message}, state) do
    {:noreply, [], state ++ [message]}
  end
end
