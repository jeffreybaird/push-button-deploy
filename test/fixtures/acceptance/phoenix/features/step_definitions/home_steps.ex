defmodule __APP_MODULE__.HomeSteps do
  use Cucumberex.DSL
  import ExUnit.Assertions
  import Phoenix.ConnTest

  @endpoint __APP_MODULE__Web.Endpoint

  when_ "I visit the application home page", fn world ->
    Map.put(world, :response, get(build_conn(), "/"))
  end

  then_ "the application renders its welcome page", fn world ->
    assert html_response(world.response, 200) =~ "Peace of mind"
    world
  end
end
