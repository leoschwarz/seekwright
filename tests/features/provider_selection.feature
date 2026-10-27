Feature: Choosing a search provider
  The tool schema lists every adapter this package ships, not the subset a
  deployment enabled, so an agent can always ask for a provider that is not
  there. Nothing is billed when it does -- the failure happens before dispatch
  -- so what matters is that a single error is enough to recover from.

  Scenario: naming a provider this deployment does not have
    Given a server enabling serper
    When the agent searches with provider "linkup"
    Then the call comes back as an error
    And the error names serper as available
    And the error tells the agent to retry with an available provider

  Scenario: naming a provider no adapter implements
    Given a server enabling serper
    When the agent searches with provider "google"
    Then the call comes back as an error
    And the error names every provider the schema accepts

  Scenario: omitting the provider where the server has no default
    Given a server enabling serper, linkup
    When the agent searches without naming a provider
    Then the call comes back as an error
    And the error names serper as available
    And the error names linkup as available
    And the error tells the agent to name a provider

  Scenario: omitting the provider where the server has a default
    Given a server enabling serper
    When the agent searches without naming a provider
    Then serper runs the search

  Scenario: the default provider fails over to the configured fallback
    Given a server whose default serper fails, falling back to linkup
    When the agent searches without naming a provider
    Then linkup runs the search and the notice names the substitute

  Scenario: a named provider failure stays an error even with a ladder
    Given a server whose default serper fails, falling back to linkup
    When the agent searches with provider "serper"
    Then the call comes back as an error
    And linkup does not run

  Scenario: every fallback fails too
    Given a server whose default serper fails, and so does every fallback
    When the agent searches without naming a provider
    Then the call comes back as an error
    And the error names the original failure and the failed fallbacks

  Scenario: a free-only search that also names a provider
    Given a server enabling serper, exa:free
    When the agent searches with provider "serper" and mode "free"
    Then the call comes back as an error
    And the error refuses the pair, naming `provider` and `mode`

  Scenario: a free-only search runs no paid provider even when every free fallback fails
    Given a server enabling serper, exa:free, tinyfish where every free provider fails
    When the agent searches with mode "free"
    Then the call comes back as an error
    And serper runs no search
    And the error names the failed free fallbacks
    And the error says no paid provider was tried

  Scenario: naming a provider the operator's allow-list refuses
    Given a server enabling serper, linkup and permitting only linkup
    When the agent searches with provider "serper"
    Then the call comes back as an error
    And the error names serper as not permitted
    And the error names linkup as permitted
    And the agent retries with provider "linkup" and the search runs
