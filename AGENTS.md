# restics backup sistem based on shell scripts

## Working style
- I give precise instructions. Work only on the files and scope I name;
  do not explore the repo beyond what the task needs.
- If a request is ambiguous, ask one short question before acting.
- Never run commands inside Docker containers, or any command that changes
  state outside the repo, without asking first.
  Allowed without asking: <!-- TODO: e.g. test commands -->

## Features and refactors: BMAD
Applies to new features, refactors and planning. Skip it for small fixes
(single-file edits, CSS, renames, typos) and just do them.
1. Brief: restate requirements and context. No code.
2. Models: define interfaces, DTOs, data models, following the project's
   base classes.
3. Architecture: list files to create/modify and which base/core pieces
   are used.
4. Delivery: write implementation only after I say "PROCEDI" or "OK".

For a new feature, check for a `TODO.md` in the target directory first.
If missing, ask me to run the Analysis Phase to create it. Follow it in
order and tick steps as done.
