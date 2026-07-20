---
tracker:
  kind: linear
  provider:
    team_key: "ENG"
    assignee: "me"
    required_comment: "symphony:ready"
  required_labels: []
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:upsmith-dev/upsmith.git .
agent:
  max_concurrent_agents: 10
  max_turns: 1
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

Work autonomously on the Linear issue below in the provided repository workspace.

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current state: {{ issue.state }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

This is a headless invocation. Never request interactive human input, approval, or
MCP elicitation. Use the available Linear tool for issue reads, comments,
attachments, and state changes.

## Invocation boundary

Invoke exactly one of `pr-plan` or `pr-deliver` during this invocation. You may do
everything that the selected skill requires, including its required audits and
reviews, but you must not invoke the other top-level skill in the same invocation.
After the selected skill reaches its terminal result, end this invocation normally.

Determine the phase from durable Linear state:

1. Read the issue, its current state, comments, links, and attachments.
2. If the issue is in `Todo`, move it to `In Progress` and invoke `pr-plan`.
   `Todo` is authoritative for a fresh planning run. If a `symphony:restart`
   comment is present, do not resume superseded local execution state.
3. If the issue is in `In Progress`:
   - Invoke `pr-deliver` when the issue has a finalized, internally valid PR Plan
     contract bundle and ready marker.
   - Otherwise invoke `pr-plan`, allowing it to begin or resume planning from the
     issue's durable comments and attachments.
4. Do not perform work for any other issue state.

## Planning invocation

Invoke `pr-plan` in unattended mode with the Linear issue URL. Perform only the planning phase.
Planning is complete only when the finalized contract, execution log, proof packet,
and authenticated ready marker required by the skill are attached to the issue and
can be read back successfully. Leave the issue in `In Progress` and end the
invocation. Do not begin delivery.

## Delivery invocation

Invoke `pr-deliver` with the Linear issue URL. Perform only the delivery phase,
including its required implementation, verification, review, PR publication, CI,
and feedback handling. Do not merge or deploy. When the skill establishes that the
PR is merge-ready and its final Linear handoff is synchronized, move the issue to
`In Review` and end the invocation.

## Blocking protocol

If the selected phase cannot continue without human input or an external state
change:

1. Do not call `requestUserInput` and do not wait for an interactive response.
2. Post one detailed Linear comment before changing state. Include:
   - selected phase and exact point where execution stopped;
   - work completed and durable artifacts or commits already produced;
   - the precise blocker and supporting evidence;
   - remediation already attempted;
   - the exact answer, permission, secret, access, or external change required;
   - precise instructions for resuming without repeating completed work.
3. Resolve the `Blocked` workflow-state ID from the issue's team and move the issue
   to `Blocked`.
4. End the invocation.

The operator resumes work by answering in a Linear comment and moving the issue
back to `In Progress`. On the next invocation, recover the phase and progress from
the issue's durable state and the preserved workspace.
