Feature: Keeping notes
  Visitors keep a short list of notes and archive completed notes.

  Scenario: Create and archive a note
    Given I am viewing my notes
    When I save a note titled "Ship the release"
    Then I see the note "Ship the release"
    When I archive the note "Ship the release"
    Then I no longer see the note "Ship the release"
    And the note "Ship the release" is retained in the archive

  Scenario: Reject an empty title
    Given I am viewing my notes
    When I save a note titled ""
    Then I see a title validation error
    And no note has been saved
