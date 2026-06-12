## AGENTS.md

Read 'docs/architecture_overview.md' when not in context yet.

## Architecture

- The architecture files are the source of truth, if there is a discrepancy between what is written in the architecture files and what is implemented, the architecture files take precedent. In such a case, point this discrepancy out before changing anything, and ask what the right course of action should be to fix it.

## Workflow

- Plan before building. When asked to change something, double check if it changes or contradicts anything in the architecture documents. If so, suggest a sensible change to the architecture documents first.

- When a new request comes in to change something, and you're still on the main branch, create a new branch describing the request.

- '/docs/todos.md' should be empty when creating a new branch, and should be empty again when creating a PR to merge the branch back in. 
- '/docs/todos.md' is your working document that lists tasks that need to be done within this branch, this is useful for when a session breaks in the middle of a task, and the next session can pick up the work where the broken one left it.
- After having planned a change, add the steps to '/docs/todos.md' to be dealt with one by one.
- Once a task has been successfully finished (and tested), remove the task from the list.
- Only when '/docs/todos.md' is empty, should you go ahead with the rest of the '/docs/implementation_plan_MODULE.md' documents. The '/docs/implementation_plan_MODULE.md' files will be scoped by phase as outlined in '/docs/architecture_overview.md'. The phases inside '/docs/implementation_plan_MODULE.md' are sub-phases. Work on things sub-phase by sub-phase (new branch per sub-phase).
- If a phase has been successfully implemented, add a tag with the phase name to the commit that archives the implementation plan documents into '/docs/archived' and summarises the phase into a phase summary document.