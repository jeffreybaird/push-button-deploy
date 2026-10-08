Feature: Notes
  Scenario: Create and display a note
    When I submit a note containing "A useful reminder"
    Then the note is saved and displayed

  Scenario: Reject an empty note
    When I submit an empty note
    Then the request is rejected without saving a note
