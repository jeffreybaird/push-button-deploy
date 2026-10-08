defmodule __APP_MODULE__.GreetingSteps do
  use Cucumberex.DSL
  import ExUnit.Assertions

  when_ "I run the greeting command for {string}", fn world, recipient ->
    Map.put(world, :result, __APP_MODULE__.CLI.run([recipient]))
  end

  then_ "the command succeeds with {string}", fn world, expected ->
    assert world.result == {expected, 0}
    world
  end

  when_ "I request the unsupported format {string}", fn world, format ->
    Map.put(world, :result, __APP_MODULE__.CLI.run(["--format", format]))
  end

  then_ "the command reports a usage error", fn world ->
    assert {message, 2} = world.result
    assert message =~ "unknown format: xml"
    assert message =~ "Usage:"
    world
  end
end
