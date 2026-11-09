Feature: Reading a JSON document's shape, then drilling into it
  A large JSON response fills the context when it is read whole, and `path`
  cannot help a caller who does not know what to ask for yet. `structure=true`
  returns one line per path -- arrays and objects with their sizes, leaves with
  their types, no values -- and every path it prints is a `path` the server
  accepts. The scenarios run against the real MCP server over an in-memory
  transport, with a counting stub where the fetch stack would be and the disk
  page cache on, so what is pinned is the whole trip: the tool schema, the
  engine's one-axis rule, and that shape-then-drill is **one download**.

  Scenario: the shape read names what to drill, and the drill costs no second download
    Given a server whose fetch endpoint answers a JSON document
    When the agent fetches its shape
    Then the response text names each array and object with its size
    And the response text never carries a value from the document
    When the agent drills into the field the shape named
    Then the drill returns the match at that path
    And the endpoint behind the page was asked for only once

  Scenario: a shape read shares its read with nothing else
    Given a server whose fetch endpoint answers a JSON document
    When the agent fetches its shape with `path` set too
    Then the call comes back as an error naming `structure`
    And the endpoint behind the page was never asked for

  Scenario: a page that is not JSON comes back as the page, not a schema
    Given a server whose fetch endpoint answers prose
    When the agent fetches its shape
    Then the response text is the prose itself
    And the notice says the page is not one this server could read as JSON
