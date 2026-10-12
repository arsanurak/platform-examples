# Issue tracker: GitHub

Issues for this repo live in its own public GitHub Issues (`arsanurak/platform-examples`). Use the `gh` CLI; inside a clone it infers the repo from `git remote -v`.

Everything posted here is public. Follow the rules in `CLAUDE.md`: generic names and placeholders only.

## Conventions

- **Create**: `gh issue create --title "..." --body "..." --label ready-for-agent`, with a heredoc for long bodies.
- **Read**: `gh issue view <number> --comments`.
- **List**: `gh issue list --state open --json number,title,labels`.
- **Comment**: `gh issue comment <number> --body "..."`.
- **Labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`.
- **Close**: `gh issue close <number> --comment "..."`.

## The map and its tickets

- The **Map** is one parent issue that lists every ticket.
- Tickets are linked to the map as GitHub sub-issues.
- Blocking uses GitHub's native issue dependencies: `gh api --method POST repos/arsanurak/platform-examples/issues/<child>/dependencies/blocked_by -F issue_id=<blocker database id>`. Get the database id with `gh api repos/arsanurak/platform-examples/issues/<n> --jq .id`.
- A ticket is ready when every ticket blocking it is closed. Take the first ready ticket in map order, and assign it to yourself before starting.

## Pull requests

PRs are not a request surface here. Every change lands through a PR that links its issue (`Closes #<n>`).
