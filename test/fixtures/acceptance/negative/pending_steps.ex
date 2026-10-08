defmodule AcceptancePendingSteps do
  use Cucumberex.DSL

  then_ "an acceptance step is pending", fn _world ->
    pending()
  end
end
