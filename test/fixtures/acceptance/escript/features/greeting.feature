Feature: Command line greetings
  Scenario: Greet a named recipient successfully
    When I run the greeting command for "Ada"
    Then the command succeeds with "hello Ada"

  Scenario: Reject an unsupported output format
    When I request the unsupported format "xml"
    Then the command reports a usage error
