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
logged in) is needed for PR comments — everything else works without it.

## Getting started

One key. `<leader>hh` asks what you want to look at:

```
1. PR diff        vs main
2. Latest commit  vs HEAD~1
3. Uncommitted    vs HEAD
```

Pick one and the marks come on, removed code included. Press `<leader>hh` again to turn it
off. That is the whole entry point — there is no second mode key.

`<leader>h?` lists every mapping, in nvim, at any time.

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

## Mappings

### diff

| key | |
| --- | --- |
| `<leader>hh` | on (asks PR / latest commit / uncommitted), press again for off |
| `<leader>hD` | hide / show removed code — it is on whenever you open a diff |
| `<leader>hO` | overview: every changed file, note and PR comment in one list |
| `]h` `[h` | next / previous hunk — including pure deletions |
| `<leader>hs` | legend and counts on the message line |
| `<leader>hr` | reload after committing, rebasing, or staging outside nvim |
| `<leader>hU` | undo the last redline action |
| `<leader>h?` | help |

### stage

| key | |
| --- | --- |
| `<leader>hS` | stage the hunk under the cursor (visual: every hunk selected) |
| `<leader>hA` | stage the whole file |
| `<leader>hu` | unstage the whole file |

Staged content comes from the buffer, so what you see marked is what lands in the index even
if the file is not written yet.

### viewed

| key | |
| --- | --- |
| `<leader>hv` | tick off the hunk under the cursor (visual: the selection) |
| `<leader>hV` | clear in this file |
| `<leader>hZ` | clear in the whole repo |

"Viewed" is keyed on the hash of the line's **text**, not its number. It follows the line
around as you edit above it, and quietly un-ticks itself the moment the line itself changes —
which is what you want while reviewing.

### github

| key | |
| --- | --- |
| `<leader>hg` | PR comments off / on |
| `<leader>hG` | open / close the comments panel |
| `<leader>hC` | comment bodies: off / under cursor / all |

Comments are fetched **automatically** in the background the first time you open a diff in a
repo — one `gh` call per repo per session, never blocking, with a spinner in the corner. A
repo with no PR is silent, not an error. `<leader>hg` is the off switch.

Comments ride on extmarks, so they drift with your edits like everything else. A comment
whose line has since changed comes back from the API with no line number; it is kept and
shown as outdated rather than dropped.

### notes

| key | |
| --- | --- |
| `<leader>hc` | add / edit a note on this line (empty input deletes) |
| `<leader>hd` | delete the note on this line |
| `<leader>hl` | list every note in the repo (quickfix) |
| `<leader>ho` | open `.comments.txt` |
| `<leader>hX` | delete all notes |

Notes live in `<repo>/.comments.txt` as `path:line: text` — exactly the shape an agent can
read back. They follow the line while you edit and the file is rewritten with fresh line
numbers on every save. Two nvim instances in the same repo will not clobber each other: each
write is authoritative only for the paths it owns and re-reads the rest from disk.

### copy

`<leader>hy` copies whatever applies where you are standing:

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

## Undo

`u` cannot reach any of this — none of it is buffer text. `<leader>hU` steps back through the
redline actions that touched the git index, `.comments.txt`, or the viewed store: staging,
unstaging, viewed ticks, notes. Index undo snapshots `git ls-files --stage` beforehand and
restores through `update-index`, including the "was not staged at all" state.

## Setup options

```lua
require("redline").setup({
  mode      = "worktree",  -- "worktree" | "commit" | "branch"
  enabled   = false,       -- true to have marks on from the moment nvim starts
  deletions = "all",       -- "all" | "cursor" | "off" — what opening a diff resets to
  github    = true,        -- false stops it shelling out to gh entirely
})
```

## Commands

`:Redline <action>`, with completion:

```
toggle pick undo yank yanknotes overview overviewsplit
gh ghsync ghpanel ghclear comments commentsoff commentscursor commentsall
worktree commit branch reload refresh status legend help notes
deletions deloff delcursor delall
stage stagefile unstage viewed clearviewed clearviewedall
```

## Colours

Four clearly different hues plus neutrals, rather than saturation variants of one colour —
"green vs slightly-duller green" is the one distinction the eye cannot make while scanning.
Shape carries add/change/delete, colour carries staged/viewed, so neither channel has to do
both jobs and it survives colourblindness. Every group is a normal highlight you can override:
`RedlineAdd`, `RedlineChange`, `RedlineDelete`, `RedlineStaged`, `RedlineViewed`,
`RedlineNote`, `RedlineGh`, each with an `…Ln` line variant.

## License

MIT
