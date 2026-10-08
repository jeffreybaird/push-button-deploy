Feature: Strict undefined regression
  Scenario: Undefined steps fail the acceptance gate
    Given a deliberately undefined acceptance step
