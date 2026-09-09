# redline.nvim

**Review a diff without leaving the file.** Gitsigns marks the gutter; redline paints the
whole line, shows you the code that was removed, pulls in the PR's review comments, and keeps
track of what you have already read.

```
  ┃ a line you added                            green
  ╏ a line you changed                          blue
  ▁ old text                                    red, drawn where it was deleted
  ┃ a line already in the index                 amber — staged, or committed on this branch
  ✓ a line you have ticked off                  grey, un-ticks itself the moment you edit it
  󰆉 a note you left for an agent                purple
  󰊤 a review comment from the PR                teal
```

Everything is off until you ask for it. While disabled the plugin does not run a single git
command.

## Install

lazy.nvim:

```lua
{ "Sushants-Git/redline.nvim", event = "VeryLazy", cmd = "Redline", opts = {} }
```

Optional: `nvim-telescope/telescope.nvim` and `nvim-tree/nvim-web-devicons` give you the
fuzzy overview; without them the overview falls back to a split panel. `gh` (the GitHub CLI,
logged in) is needed for PR comments and PR creation/opening; local review works without it.

## Getting started

`<leader>ho` (Space ho when your leader is Space) or `:Redline` asks what you want to review:

```
1. Uncommitted    vs HEAD
2. Latest commit + uncommitted vs HEAD~1
3. Branch / PR diff vs <actual default branch>
```

Pick a context and the overview opens with the overlay enabled, removed code included.
In Telescope, Enter opens the selected file; Ctrl-a (or normal-mode `a`) closes the picker,
opens that file, then offers contextual actions. Normal-mode `?` opens help.
The split fallback uses Enter, `a`, `?`, and `q`. Deleted/missing files open the searchable
disk diff instead of an empty editable file; file mutations are unavailable there.

`<leader>ha` opens actions. `<leader>h?` shows the current compact help.

### Default keys

| key | action |
| --- | --- |
| `<leader>ho` | choose context, then overview |
| `<leader>ha` | actions, normal or visual |
| `<leader>hc` | add/edit note, normal or visual (`add_note(first, last)`) |
| `<leader>hv` | toggle viewed, normal or visual |
| `]h` / `[h` | next / previous hunk |
| `<leader>h?` | help |

Set `keymaps = false` to install no default mappings. Redline does not set your leader.
Staging, unstaging, notes, peek, refresh, settings, undo, copying and GitHub operations
live in the action menu instead of separate default shortcuts.

### Search and handoff

`:Redline diff` opens a read-only scratch diff. Use normal `/`, `n`, and `N` to search
added and removed text, and `q` to close. It includes untracked disk files and preserves
Git's no-final-newline markers. It is clearly labeled a **disk snapshot**: unsaved buffer
edits are excluded, unlike the live overlay. Overview statistics also come from disk.

The **Copy AI handoff** action confirms before copying saved `.comments.txt` notes,
review context, base and the disk diff to the unnamed register and available clipboard.
It is provider-neutral and never runs an agent. Review for secrets before sharing.

### Publish explicitly

Actions include **Commit staged changes**, **Push branch**, **Create PR**, and **Open PR**.
Commit asks for a message and confirmation of the staged summary; it never stages files.
Push asks for a remote, destination branch and confirmation, without force.
PR creation asks for title, body, base, draft/ready status and final confirmation.
It uses an explicit head branch and never pushes: push separately first.
Network operations run asynchronously with argv arrays, not interpolated shell commands.
Commit, push and PR creation are not part of Redline undo. `github = false` disables PR actions.

## What each mode diffs against

| mode | base | what you see |
| --- | --- | --- |
| PR diff | merge-base with the default branch | the whole branch: committed work *and* uncommitted edits |
| Latest commit | `HEAD~1` | your last commit, plus anything dirty on top of it |
| Uncommitted | `HEAD` | only what you have not committed |

The default branch is read from `git symbolic-ref refs/remotes/origin/HEAD` — whatever your
repo actually uses, not a guess at `main`. On the default branch itself the merge-base *is*
`HEAD`, so PR mode would show nothing; redline says so once instead of rendering an empty
diff.

## Review Actions

### stage

Use actions to stage the cursor hunk, visual selection, or whole file, or to unstage
the file. Staging and unstaging ask for confirmation.

Staged content comes from the buffer, so what you see marked is what lands in the index even
if the file is not written yet.

Visual staging includes only selected added or replacement lines, including in
untracked files, without writing the buffer. Replacements pair old and new lines
by position within each fresh index hunk; unselected old lines remain. Surplus
deleted lines in a replacement stage only when its entire new side is selected.
Pure deletions have no buffer lines to select: use **Stage hunk** at the deletion
anchor (normal cursor staging always stages the whole hunk), or stage the file.
Selections are line-based, even when made characterwise or blockwise.

### viewed

Use `<leader>hv` or **Toggle viewed** in actions for the hunk or selection.

Viewed marks track individual changed-line occurrences, so identical blank lines or code
do not share marks. Positions follow edits in an open buffer; changed content invalidates
the mark. Saved marks restore only when the file snapshot matches. External changes may
require reviewing again rather than risk marking the wrong occurrence. Legacy text-only
marks are discarded on upgrade. Viewed history never adds unchanged files to the overview.

### github

Settings offers GitHub comment toggling, syncing, and comment body visibility.

Comments are fetched **automatically** in the background the first time you open a diff in a
repo, with one automatic fetch attempt per repo per session, never blocking, with a spinner. A
repo with no PR is silent, not an error. Settings offers the off switch.

Comments ride on extmarks, so they drift with your edits like everything else. A comment
whose line has since changed comes back from the API with no line number; it is kept and
shown as outdated rather than dropped.

### notes

Use `<leader>hc` to add/edit a note, or actions to add/edit, delete, and read notes.

Notes live in `<repo>/.comments.txt` as `path:line: text` or `path:start-end: text`.
Normal `<leader>hc` comments the current chunk, or edits the note under the cursor;
visual `<leader>hc` comments the selected lines. Range endpoints follow buffer edits
and update on save. Legacy single-line notes still load. Deletion-only chunks attach
to a surviving line; one note can exist per start line. Concurrent instances preserve
other paths' notes, but simultaneous edits to the same path are last-writer-wins.

### copy

**Copy contextual code/comments** offers whatever applies where you are standing:

```
Removed code here  (3 lines)
All removed code in this file  (10 lines)
PR comment on this line
PR comments in this file  (1)
All PR comments on #412  (7)
Notes  (.comments.txt)
```

Removed code is drawn with `virt_lines` and comments with `virt_text` — neither is buffer
text, so `y` cannot reach them. This is the way out. One block copies as bare code ready to
paste back; a whole file gets `@@ path:line @@` headers. In the panels, `y` copies the entry
under the cursor (the *whole* comment, not the one wrapped line) and `Y` copies everything.

### long deletions

Neovim counts `virt_lines` as **fill** lines, the same as diff filler. Measured behaviour:
`<C-e>` steps through them one at a time, but `j` and `<C-d>` jump the whole block. So a
removed block taller than your window is, in practice, unreachable — which is why a
page-sized deletion reads as "it doesn't scroll".

Blocks are therefore truncated to what fits the window, with a footer:

```
  ▁ removed line 14
  ▁ removed line 15
  ▁ … 185 more removed lines   actions: Peek removed code
```

**Peek removed code** opens the whole block in a float. That is a normal scratch buffer holding real
lines, so `j`, `<C-d>` and `G` all work, and it inherits the file's filetype so the removed
code is syntax-highlighted. `y` copies the block, `q` / `<Esc>` / `<CR>` closes.

When several removed blocks land on the same line — imports stripped from the top *and* a body
removed below both anchor at line 1 — Peek picks the one that was truncated, since
reading those is the entire reason the float exists. Set `deleted_max = 0` to draw
everything inline regardless.

## Undo

`u` cannot reach any of this — none of it is buffer text. **Undo last Redline action** steps back through the
redline actions that touched the git index, `.comments.txt`, or the viewed store: staging,
unstaging, viewed ticks, notes. Index undo snapshots `git ls-files --stage` beforehand and
restores through `update-index`, including the "was not staged at all" state.

## Setup options

```lua
require("redline").setup({
  mode      = "worktree",  -- "worktree" | "commit" | "branch"
  enabled   = false,       -- true to have marks on from the moment nvim starts
  keymaps   = true,        -- false: install no default mappings
  deletions = "all",       -- "all" | "cursor" | "off" — what opening a diff resets to
  deleted_max = "auto",    -- longest block drawn inline; a number, or 0 for no cap
  github    = true,        -- false stops it shelling out to gh entirely
})
```

## Commands

`:Redline` is equivalent to `:Redline open`. Completion exposes only:

```
open actions diff help
```

Previously shipped subcommands remain hidden aliases for existing configurations.

## Colours

Four clearly different hues plus neutrals, rather than saturation variants of one colour —
"green vs slightly-duller green" is the one distinction the eye cannot make while scanning.
Shape carries add/change/delete, colour carries staged/viewed, so neither channel has to do
both jobs and it survives colourblindness. Every group is a normal highlight you can override:
`RedlineAdd`, `RedlineChange`, `RedlineDelete`, `RedlineStaged`, `RedlineViewed`,
`RedlineNote`, `RedlineGh`, each with an `…Ln` line variant.

## License

MIT
