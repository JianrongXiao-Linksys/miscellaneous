# CLAUDE.md

Project-specific instructions for Claude Code.

## Post-Edit Workflow (ALWAYS follow these steps after any code change)

1. Run any existing tests or linting (`pytest`, `eslint`, `python -m py_compile`) to verify changes work
2. Update the README.md if any behavior, schedule, interface, or dependency changed — check the entire file, not just one section
3. `git add` only the files in this repo (never .claude/ or files outside the repo root)
4. `git commit` with a conventional commit message (feat/fix/docs/chore)
5. `git push origin main`
6. Confirm the push succeeded and print a summary of what was committed

Never wait for me to ask you to commit. If you edited files, you commit and push.

## Python Conventions

- Always use Python 3.9 compatible syntax
- Never use `X | Y` union type annotations — use `typing.Union` instead

## Git Automation

- After code changes, always auto-commit and push unless otherwise specified
- Do not wait to be asked

## Documentation Sync

- When changing code logic (e.g., cron schedules), update README in the same commit

## GitHub Wiki Limitations

- GitHub Wiki does not support inline CSS
- Use emojis for status colors: 🟢 🟡 🔴
