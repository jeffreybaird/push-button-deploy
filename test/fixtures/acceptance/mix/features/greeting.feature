Feature: Library greetings
  Scenario: Greet a named recipient
    When I greet "Ada"
    Then the greeting is "hello Ada"
