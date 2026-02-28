# Resolving Merge Conflicts (VS Code + Git Beginner Guide)

Sometimes after the pipeline creates a pull request (PR), it can't automatically merge your export branch into `main` because of a **merge conflict**. This guide explains what that means and how to fix it in VS Code.

---

## What Is a Merge Conflict?

A merge conflict happens when Git doesn't know which version of a file to keep because two branches both changed the same lines.

**Example of what causes this:** Your export branch was created from `main` on Monday. On Tuesday, someone else merged their changes into `main`. On Wednesday, the pipeline tries to merge your branch — but `main` now has content that conflicts with your changes. Git can't automatically pick a winner, so it flags it and asks you to decide.

**In Azure DevOps:** You'll see a message like:
> *"This pull request has conflicts that need to be resolved before it can be completed."*

Or the auto-complete option may say it was blocked due to conflicts.

---

## Step 1: Open the Repo in VS Code

If the repo isn't already open, open VS Code → **File → Open Folder...** and select the repo folder.

---

## Step 2: Switch to Your Export Branch

You need to be on your export branch — not `main`.

1. Click the **branch name** at the bottom-left of VS Code.
2. In the menu, click your export branch (e.g., `export/2026-02-28-quarterly-release`).

If you don't see it in the list, type the name and VS Code will let you check it out.

---

## Step 3: Pull the Latest `main` into Your Branch

The fix for most conflicts is to bring the latest `main` changes into your export branch, then resolve any conflicts VS Code finds.

1. Open the **Terminal** in VS Code: press `` Ctrl+` `` (the backtick key, usually top-left of keyboard).
2. Run this command:
   ```bash
   git pull origin main
   ```
3. If there are no conflicts, this succeeds and you can skip to [Step 7: Push](#step-7-push-your-branch).
4. If there are conflicts, Git will print something like:
   ```
   CONFLICT (content): Merge conflict in exports/2026-02-28-quarterly-release/build.json
   Automatic merge failed; fix conflicts and then commit the result.
   ```
   Continue to Step 4.

---

## Step 4: Find the Conflicting Files

VS Code shows conflict indicators in two places:

- **Explorer panel** (left sidebar): conflicted files have a red **C** badge or **!** icon.
- **Source Control panel** (`Ctrl+Shift+G`): conflicted files appear under **Merge Changes**.

Click any conflicted file to open it.

---

## Step 5: Resolve the Conflict in VS Code

VS Code's built-in merge editor highlights exactly what's in conflict. When you open a conflicted file you'll see sections that look like this:

```
<<<<<<< HEAD (Current Change)
  "version": "1.2.0.0",
=======
  "version": "1.1.0.0",
>>>>>>> main
```

- **Current Change** (`HEAD`) = what's on your export branch
- **Incoming Change** (`main`) = what came in from `main`

### Using the Merge Editor (Recommended)

VS Code shows a banner at the top of the file:

> *"Accept Current Change | Accept Incoming Change | Accept Both Changes | Compare Changes"*

Click the option that's right for your situation:

| Option | When to use |
|--------|-------------|
| **Accept Current Change** | Keep your export branch version; ignore main's change |
| **Accept Incoming Change** | Keep main's version; discard your change |
| **Accept Both Changes** | Append both versions one after the other (for lists) |
| **Compare Changes** | Open a side-by-side diff to inspect before deciding |

### What to pick for export branch files

The files in your `exports/{date}/` folder (like `build.json`) are specific to your export run. In most cases:

- **`build.json`** — this is unique to your export. Use **Accept Current Change** unless you intentionally want something from `main`.
- **Solution zip files** (`.zip`) — binary files. Take whichever version the pipeline actually needs. Usually **Accept Current Change**.
- **Files outside your `exports/` folder** — these are shared. Read both versions carefully before deciding. When in doubt, ask a teammate.

> **Tip:** Click **Compare Changes** to see a clear side-by-side view before making a decision.

---

## Step 6: Mark the File as Resolved

After accepting changes in a file, you must tell Git it's resolved.

**In VS Code:**
1. Save the file (`Ctrl+S`).
2. Open the **Source Control** panel (`Ctrl+Shift+G`).
3. Under **Merge Changes**, hover over the file and click the **+** icon to stage it.

Repeat Steps 5–6 for every conflicted file. Once all files are staged, you're ready to commit.

---

## Step 7: Commit the Conflict Resolution

1. In the **Source Control** panel, make sure all resolved files are staged (listed under **Staged Changes**).
2. In the **Message** box, type something like:
   ```
   Resolve merge conflict with main
   ```
3. Press `Ctrl+Enter` (or click the checkmark **Commit** button).

---

## Step 8: Push Your Branch

1. In the Source Control panel, click the `...` menu → **Push**.
2. The push updates your export branch in Azure DevOps.

---

## Step 9: Check the PR in Azure DevOps

1. Go to Azure DevOps → **Repos → Pull Requests**.
2. Open your PR.
3. The conflict warning should now be gone and the PR should be ready to complete (auto-complete or manual merge).

If the PR still shows conflicts, repeat from [Step 3](#step-3-pull-the-latest-main-into-your-branch) — it's possible `main` got another update while you were resolving.

---

## Merge Conflict Cheat Sheet

```
<<<<<<< HEAD        ← your branch's version starts here
  your code
=======             ← divider
  their code
>>>>>>> main        ← main's version ends here
```

Delete the conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) and keep only the final version you want. VS Code does this automatically when you click "Accept."

---

## Tips to Avoid Conflicts in the Future

- **Create your export branch from an up-to-date `main`.** Before branching, always pull the latest main (see [CREATING-EXPORT-BRANCH.md](./CREATING-EXPORT-BRANCH.md#step-3-get-the-latest-code-from-main)).
- **Don't let export branches sit for days.** The longer a branch lives, the more `main` diverges from it.
- **Merge export PRs promptly.** After the pipeline creates the PR and QA/Stage/Prod are approved, merge it quickly to keep `main` clean.

---

## Still Stuck?

If the conflict is in a file you don't recognize or the side-by-side view doesn't make sense, take a screenshot of the conflicted file and ask a teammate before accepting either side. Getting it wrong means losing someone else's changes.
