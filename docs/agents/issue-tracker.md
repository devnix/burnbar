# Issue tracker: GitHub Issues

Issues and PRDs for this repo live in GitHub Issues (`devnix/burnbar`). Use the `gh` CLI. Users outside the project also open issues here.

## Conventions

- A PRD is one issue. Its title starts with `PRD: `.
- Implementation issues are separate issues. The first line of the body is `Part of #<PRD number>`.
- Triage state is a label (see `triage-labels.md` for the role strings). Each issue has at most one triage label.
- Conversation goes in issue comments (`gh issue comment <number>`).

## When a skill says "publish to the issue tracker"

Run `gh issue create --title "<title>" --body-file <file> --label <triage label>`. Use the triage label that the skill asks for, or `needs-triage` when it asks for none. Report the issue URL to the user.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`. The user normally gives the issue number or URL.
