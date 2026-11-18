---
name: git-workflow
description: Standard git branching, commit messaging, and pull request workflows for autonomous coding agents. Use when creating branches, crafting commits, or opening PRs.
---

# Git Workflow & Clean Commits

When contributing changes to repositories, adhere strictly to the following standards:

## 1. Branching
* Always create a descriptive feature branch from `main`:
  `git checkout -b feature/<short-description>` or `fix/<short-description>`.
* Never push directly to `main` or `master`.

## 2. Commit Messages (Conventional Commits)
* Format: `<type>(<scope>): <short imperative summary>`
  * `feat`: A new feature or capability
  * `fix`: A bug fix
  * `docs`: Documentation updates only
  * `refactor`: Code change that neither fixes a bug nor adds a feature
  * `chore`: Maintenance, dependencies, or configuration changes
* Example: `feat(auth): add automated token refresh trap`
* Keep the summary concise (under 72 characters) and written in the imperative mood ("add", not "added" or "adds").

## 3. Pull Request Guidelines
* Run tests and linters before opening a PR.
* Write a clear PR description explaining:
  * **What:** The exact changes introduced.
  * **Why:** The motivation or problem solved.
  * **Verification:** How the changes were tested and verified.
* Use the GitHub CLI to open pull requests:
  `gh pr create --title "..." --body "..."`
