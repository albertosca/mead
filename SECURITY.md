# Security policy

`mead` holds conversations and can reach the tools of the person who runs it, so security reports are welcome and taken seriously.

## Reporting a vulnerability

Report it privately through [GitHub security advisories](https://github.com/albertosca/mead/security/advisories/new). Do not open a public issue, and never include a real token or API key in a report.

Please include what you found, the smallest way to reproduce it, and the version or commit you tested. This is a personal project, so there is no guaranteed response time, but a report is read as soon as possible.

## What is in scope

* Running an MCP tool the policy does not allow, or skipping a permission request.
* Reaching the MCP server or the deck endpoint without the bearer token.
* A token, an API key or a tool argument showing up in a log, an error message or the event log.
* A local turn being sent to a cloud provider.
