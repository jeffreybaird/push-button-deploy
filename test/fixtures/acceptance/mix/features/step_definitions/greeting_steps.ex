defmodule __APP_MODULE__.GreetingSteps do
  use Cucumberex.DSL
  import ExUnit.Assertions

  when_ "I greet {string}", fn world, recipient ->
    Map.put(world, :greeting, __APP_MODULE__.greet([recipient]))
  end

  then_ "the greeting is {string}", fn world, expected ->
    assert world.greeting == expected
    world
  end
end
