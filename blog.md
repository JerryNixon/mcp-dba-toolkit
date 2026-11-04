# Why Is My SQL Slow? Give Your Agent a Few Tools

Your application is waiting. The query looks stuck.

Before changing an index or blaming the execution plan, a DBA asks a simpler
question: **is the query actually running, or is it blocked?**

That is a useful place to start with an agent, too.

## One investigation

Give the agent three tools:

- `active_requests`: find the request and its wait.
- `blocking_chain`: follow the wait to the head blocker.
- `session_details`: identify the application, login and open transaction.

Here is an illustrative conversation:

> **You:** Why is my SQL slow?
>
> **Agent:** Your request is waiting for a lock held by another session.
>
> **You:** Who owns that session?
>
> **Agent:** Here are its application, host and login. It has an open transaction.
> The available SQL text is evidence, not proof of which statement acquired the lock.
>
> **You:** What should we do?
>
> **Agent:** Have the owner finish or roll back the transaction. If that is not
> possible, a DBA can consider terminating the session.

The result is not "AI fixed SQL."

It is **an actionable explanation of why the request is waiting**.

## An action, not an automatic reaction

A fourth tool, `kill_session`, makes termination possible after explicit approval.
It checks the observed session identity again before requesting termination.

That operation disconnects the session and initiates transaction rollback.
Rollback can take time, and the application can see errors. The agent must
explain those effects, get approval, and check whether blocking cleared afterward.
Killing the waiting request does not remove its blocker.

## Make the idea visible

The demo also includes `cause_problem`. One call holds a lock on a dedicated
demo table; a concurrent call waits for it. The blocker is bounded, and both
transactions roll back.

That gives the agent something real to investigate without touching application
tables. It demonstrates a running blocker; an idle connection with an open
transaction is another real-world situation the diagnostic tools can reveal.

[One PowerShell command](solution/run.ps1) starts SQL Server, deploys the schema, and then
starts Data API builder using [Docker Compose](solution/compose.yaml). Only two containers
are needed, and the command verifies the blocking flow.
Open the demo in VS Code and start the `dba` connection from
[the workspace MCP configuration](.vscode/mcp.json). Ask Copilot in Agent mode
why SQL is slow, and let it follow the evidence through the five tools.
The demo uses SQL port 1234 and DAB 2.1.5 on port 5678. All SQL lives in
[one file](solution/database.sql).

## Take the pattern

You do not need to adopt this demo to use the idea:

**Put a few deliberate SQL procedures behind named MCP tools. Let the agent
follow the evidence. Keep consequential decisions with the DBA.**

The value is not a large tool catalog. It is a small, understandable path from
"SQL is slow" to "this request is waiting on that session, and here are our options."

See the [demo README](readme.md) for the runnable example and source credits.
