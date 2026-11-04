# Why is my SQL slow?

Sometimes a slow query is not doing expensive work. It is waiting for another
session to release a lock.

This demo gives an agent a small set of SQL tools to explain that situation:
find the waiting request, follow it to the head blocker, and identify the owner.
If a DBA explicitly approves termination, the agent can request it and check
whether blocking cleared.

**SQL procedures -> Data API builder -> MCP -> your agent.**

## Five tools, one story

| Tool | Purpose |
|---|---|
| `active_requests` | What is running, and what is it waiting for? |
| `blocking_chain` | Which session is at the head of the blocking chain? |
| `session_details` | Who owns that session, and does it have an open transaction? |
| `kill_session` | After explicit approval, disconnect the identified session and initiate rollback. |
| `cause_problem` | Create a bounded blocking scenario on a dedicated demo table. |

All procedures are in [database.sql](solution/database.sql). A private permission helper
is not exposed as an MCP tool. [dab-config.json](solution/dab-config.json) exposes only
these five named tools; generic DML, REST and GraphQL are disabled.

## Run it

Prerequisites: PowerShell 7.3+, Docker with Linux containers and Docker Compose, with free local
ports 1234 (SQL) and 5678 (DAB). No host SQL Server, sqlcmd,
DAB, or Node.js installation is required. Use VS Code with GitHub Copilot
to talk to the demo through MCP.

Create a gitignored `.env` in this directory with your local demo password:

```dotenv
MSSQL_SA_PASSWORD=<your local demo password>
```

Then run from the repository root:

```powershell
.\solution\run.ps1
```

[run.ps1](solution/run.ps1) uses [compose.yaml](solution/compose.yaml) and the password from the root `.env`,
starts SQL Server 2025, deploys [database.sql](solution/database.sql) into `McpDbaDemo`
using SQL Server's bundled sqlcmd,
and starts DAB 2.1.5 under the **agentic-dba** Compose group.
Containers are `agentic-dba-sql-database` and `agentic-dba-mcp-server`,
with no setup containers or custom images.
The network and SQL data volume also use the `agentic-dba-` prefix.
SQL and DAB readiness checks gate startup. Use [run.ps1](solution/run.ps1), not
`docker compose up`, for initial startup and schema updates.
The script resolves its files independently of the terminal's working directory;
from `solution`, use `.\run.ps1`. Keep `.env` at the repository root.
Rerunning the command reuses the SQL data volume. Keep the same password while
reusing that volume; changing `.env` alone does not change an existing SQL login.

The same command verifies the five tools,
diagnoses a real blocker and waiter, checks confirmation and stale-session
guards, terminates the demo blocker, and verifies rollback and cleanup.
It also checks natural rollback without termination. Unrelated containers and
application objects are not removed.

## Connect your agent

Open this directory in VS Code. In the Command Palette, run **MCP: List Servers**
and start the `dba` server defined in [.vscode/mcp.json](.vscode/mcp.json).
Approve the workspace server if prompted. In Copilot Chat, use **Agent** mode
and enable the five `dba` tools in the tools picker.

Ask Copilot to check active SQL requests. Empty results are normal when there
is no running request. For a real blocking scenario, use the conversation below.

## Try the conversation

```powershell
.\solution\run.ps1 -Demo
```

Leave that terminal open. Once it prints **Demo ready**, start or restart the
`dba` MCP server defined in [.vscode/mcp.json](.vscode/mcp.json), then ask:

> Why is my SQL slow? Is a request blocked?

Follow with:

> Who owns the head blocker, and what are my options?

The scenario uses two concurrent MCP calls: `cause_problem(role=blocker)`
holds a transaction lock; `cause_problem(role=waiter)` waits for that lock.
Both affect only `dba.DemoLock` and roll back. The blocker holds the lock for
120 seconds in interactive mode; the waiter has a 120-second lock timeout.
This is a **running blocker**, not an idle connection with an abandoned
transaction. The diagnostic tools can also identify idle head blockers in
real incidents.

SQL is available at `127.0.0.1,1234`; the MCP endpoint is
`http://127.0.0.1:5678/mcp`. The matching agent workflow is
[dba-blocking](.github/skills/dba-blocking/SKILL.md).

## DBA judgment still matters

Prefer the owning application completing or rolling back its transaction.
Terminating a session disconnects it and can cause application errors; rollback
may take time. SQL Server `KILL` targets a session, not an individual query.

`kill_session` requires confirmation and a fresh `login_time` identity token,
rejects the caller and non-user sessions, and returns `termination_requested`.
That is not proof that rollback finished. Recheck blocking afterward.

Live observations change, session IDs can be reused, and last cached SQL is not
necessarily the statement holding the lock. A bounded chain can be incomplete,
especially with multiple requests per session. Negative blocker codes are not
sessions to terminate. These tools diagnose current blocking, not every cause
of slow SQL.

**Local demo only:** both published ports bind to loopback. DAB's
port 5678 is the MCP connection for VS Code. All five tools share
anonymous execute access and use a demo SQL administrator. Confirmation is an
intent check, not an authorization boundary. Do not expose this package publicly
or use its credentials as a production access pattern.

## Sources

The three diagnostic procedures adapt
[Microsoft Tiger Toolbox's usp_WhatsUp](https://github.com/microsoft/tigertoolbox/blob/fe47c31ec2f7979a994520d546c7abf0b246c832/usp_WhatsUp/usp_whatsup.sql).
The blocking-chain walk, termination and demo logic are original implementations.
Each procedure includes its source or Microsoft Learn reference at the top;
Microsoft's MIT notice is retained in [license.md](license.md).
