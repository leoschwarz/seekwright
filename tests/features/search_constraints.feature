Feature: The filters a search can ask a provider for
  A filter a backend cannot apply is reported in `notice` rather than dropped
  silently, so an agent that asked for filtered results can tell what it got.

  Scenario: a provider that can filter adult content is asked to
    Given a server enabling scrappa
    When the agent searches with safe_search true
    Then scrappa receives safe "active"
    And the response carries no notice

  Scenario: a provider that cannot filter adult content says so
    Given a server enabling serper
    When the agent searches with safe_search true
    Then the response notice says safe-search was ignored

  Scenario: a language reaches the backend's own language parameter
    Given a server enabling tinyfish
    When the agent searches with language "de"
    Then tinyfish receives language "de"
    And the response carries no notice

  Scenario: a provider with no language parameter says so
    Given a server enabling algolia
    When the agent searches with language "de"
    Then the response notice says language was ignored

  Scenario: a regional tag is refused before anything is billed
    Given a server enabling scrappa
    When the agent searches with language "de-DE"
    Then the call comes back as an error
    And the error names language
