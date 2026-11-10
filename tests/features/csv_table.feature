Feature: Reading a CSV file as a table of rows, not a wall of commas
  A CSV response read whole is a wall of commas that `select_passages` cannot
  search and `path` cannot address. `fetch` renders it into the line grammar a
  JSON rendering already uses -- the first row names the columns, every record
  is printed under its own row path, and every path it prints is a `path` the
  server accepts -- so the shape-then-drill idiom works on a table with no new
  parameter. The scenarios run against the real MCP server over an in-memory
  transport, with a counting stub where the fetch stack would be and the disk
  page cache on, so what is pinned is the whole trip: the tool schema, the
  engine's structure read, and that shape-then-drill is **one download**.

  Scenario: the whole small table arrives, path-labelled
    Given a server whose fetch endpoint answers a CSV table
    When the agent fetches the file
    Then the response text names every row and its price column
    And the response carries no notice

  Scenario: the shape names the columns, and selecting one column costs no second download
    Given a server whose fetch endpoint answers a CSV table
    When the agent fetches its shape
    Then the shape names the columns and no cell value
    When the agent drills into one column the shape named
    Then the drill returns one line per row
    And the endpoint behind the page was asked for only once

  Scenario: a page that is not a table comes back as the page
    Given a server whose fetch endpoint answers prose
    When the agent fetches its shape
    Then the response text is the prose itself
    And the notice says the page is not one this server could read as either
