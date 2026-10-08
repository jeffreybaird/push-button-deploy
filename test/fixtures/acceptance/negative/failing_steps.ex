defmodule AcceptanceFailureSteps do
  use Cucumberex.DSL
  import ExUnit.Assertions

  then_ "an intentional acceptance assertion fails", fn world ->
    assert 1 == 2
    world
  end
end
