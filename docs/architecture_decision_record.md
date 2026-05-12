# ADR Guide for AI Agents
## What is an ADR?
An Architecture Decision Record (ADR) documents a significant architectural
decision: the context that led to it, the decision itself, and its consequences.
## When to Create an ADR
Create an ADR when making decisions that:
- Are hard to reverse
- Affect multiple parts of the system
- Involve meaningful tradeoffs
- Future developers (or agents) would wonder "why was this done this way?"
## File Naming
Use a zero-padded sequence number and a short kebab-case title:
`docs/adr/0001-short-description-of-decision.md`
## Template
```markdown
# ADR-XXXX: Title
## Status
Proposed | Accepted | Deprecated | Superseded by ADR-XXXX
## Date
YYYY-MM-DD
## Context
What situation or problem prompted this decision?
## Decision
What was decided?
## Consequences
- **Good:** ...
- **Bad:** ...
- **Neutral:** ...
Rules
- Never edit a past ADR. If a decision changes, write a new ADR and mark
  the old one as Superseded by ADR-XXXX.
- Keep ADRs short and factual. Avoid lengthy justifications.
- Commit ADRs alongside the code they relate to.
- Maintain an index in docs/adr/README.md listing all ADRs and their status.