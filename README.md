# redline.nvim

**Review a diff without leaving the file.** Redline paints changed lines, shows
removed code, brings in PR review comments, and tracks what you have read.
The overlay uses live buffers, including unsaved edits.

## Install

Requires Neovim 0.10+ and Git. With lazy.nvim:

```lua
{ "Sushants-Git/redline.nvim", event = "VeryLazy", cmd = "Redline", opts = {} }
```

Optional: `nvim-telescope/telescope.nvim` for the native action picker and fuzzy
file overview; `nvim-tree/nvim-web-devicons` for overview icons. Without Telescope,
actions use `vim.ui.select` and the overview uses a split. GitHub features require
the logged-in `gh` CLI; local review works without it.

## Review

`<leader>ho` or `:Redline` chooses a context, enables the overlay, and opens files:

| Context | Base | Includes |
| --- | --- | --- |
| Uncommitted | `HEAD` | uncommitted changes |
| Latest commit | `HEAD~1` | latest commit plus uncommitted changes |
| Branch / PR diff | merge-base with the default branch | committed branch work plus uncommitted changes |

The default branch is detected from `origin/HEAD`, with main/master fallbacks.
If the merge-base is `HEAD`, branch mode shows only uncommitted work. The first
commit uses the empty tree in Latest commit mode.

In the Telescope **file overview**, Enter opens a file; Ctrl-a or normal `a`
opens it and then offers actions; normal `?` opens help. The split uses Enter,
`a`, `?`, and `q`. Missing/deleted files open the read-only repo disk diff, not an
empty editable file; file mutations are unavailable there. Overview diff stats
come from disk, not unsaved buffers.

### Default Keys

| Key | Normal mode | Visual mode |
| --- | --- | --- |
| `<leader>ho` | choose context, then files | |
| `<leader>ha` | actions for the whole file | actions for selected lines |
| `<leader>hc` | add/edit a whole-file note | add/edit a selection note |
| `<leader>hv` | toggle viewed for changed lines in the whole file | toggle viewed for selected changed lines |
| `<leader>hb` | back to Changes after opening a file | |
| `<leader>hs` | side-by-side diff, or back to unified | |
| `]h` / `[h` | next / previous changed location | |
| `<leader>h?` | help | |

Redline does not set your leader. Set `keymaps = false` to disable default maps.
The `hb` and `hs` mappings are added only if they do not conflict with existing mappings.
Without it, use `:lua require('redline').back_to_review()`.
Selections are line-based, including characterwise and blockwise selections.

### Side by Side

The overlay is **unified** by default: removed code is drawn inline, above the
lines that replaced it. `<leader>hs` (or action `t`, or `:Redline layout`)
switches to **side by side**: the base version opens read-only in a window on
the left and Vim's diff mode lines the two up. The right side is still the live
buffer, unsaved edits included, with Redline's staged/viewed/note marks; inline
removed code is hidden meanwhile. The left window follows whichever file you
open on the right, and each tab gets its own pair.

Press `<leader>hs` again, or close the left window, to go back to unified.
Opening a review resets the layout to the `layout` option. `:Redline split` and
`:Redline unified` set it directly.

## Actions

`<leader>ha` opens a **native Telescope picker in Normal mode**, with visible
`[letter]` shortcuts. Press a letter to run immediately, or `/` to enter fuzzy
search and Enter to run the selected row. Esc closes in either mode; normal `q`
also closes. `/` searches actions; it does not open the diff.

| Key | Scope | Action |
| --- | --- | --- |
| `s` | selection, otherwise file | Stage |
| `u` | selection, otherwise file | Unstage |
| `c` | selection, otherwise file | Comment (local note) |
| `v` | selection, otherwise file | Toggle viewed |
| `y` | selection, otherwise file | Copy (live buffer lines) |
| `h` | file, at cursor | Select chunk at cursor (file) |
| `t` | session | Toggle side-by-side / unified diff |
| `f` | repo | Show changed files |
| `d` | repo | Read changes (all files) |
| `n` | repo saved notes | Read saved notes (all files) |
| `a` | selection, otherwise current file | Copy for AI |
| `C` | repo index | Commit staged changes (all files) |
| `P` | repo branch | Push this branch |
| `p` | repo | Open pull request |
| `z` | session, not just this file/repo | Undo last review action |

Stage, Unstage, Comment, Toggle viewed, and Copy labels show `file` or
`selected lines X-Y`. Local actions, copying, and undo have **no confirmation
step**. Comment asks for note text; empty input deletes the note at that range's
start.

To act on a chunk, put the cursor inside it, open `<leader>ha`, press `h`, then
open **Visual `<leader>ha`** and choose an action. `h` only selects; it does not
stage or comment. Normal `<leader>hc` and `<leader>hv` still target the whole file,
not the chunk under the cursor.

### Staging Limits

Both file and selection staging use the **live buffer without saving it**.
Selection staging includes only selected added/replacement lines, even in
untracked files. Replacements pair old/new lines by position in fresh index
hunks; unselected old lines remain. Surplus removed lines stage only when the
entire replacement's new side is selected.

Whole-file staging applies Git's path-specific clean conversion (including
`.gitattributes` filters/LFS) and records executable-bit changes when
`core.fileMode` is enabled. Ignored untracked files are refused in both scopes.
Partial staging refuses filtered/encoded files or patches requiring clean
conversion; use whole-file staging instead. Neither scope saves the buffer.

Selected unstage maps live lines back to the index. If the selection overlaps
an unstaged replacement, that mapping is ambiguous: Redline refuses the action
without changing the index and asks you to use whole-file unstage. Newly inserted
unstaged lines have no index counterpart. Unstage leaves the buffer and disk alone.

Pure deletions are virtual text, not selectable buffer lines. `h` cannot select
them, and selected stage/unstage cannot target them. Use normal `<leader>ha`
then `s` or `u` for the whole existing file. An entirely missing/deleted file is
read-only in this workflow; handle its index changes with Git outside this menu.

### Publishing

`C` shows the repo's staged summary and asks **only for a commit message**. It
commits the entire repo index, never auto-stages, and adds no confirmation dialog.

`P` pushes `HEAD` only to the same branch name. If the current branch tracks a
different name (for example, `topic` tracks `origin/main`), it refuses to push;
configure a matching upstream with Git first. Remote selection honors
`branch.<name>.pushRemote`, then `remote.pushDefault`, then `branch.<name>.remote`.
Without that configuration, it uses the sole remote or asks which remote when
several exist. It does not ask for a destination or confirmation and never
force-pushes.

The single `p` action opens the existing PR in the foreground browser, or opens
GitHub's PR creation form if no PR exists. Complete creation in the browser, not
in local title/body/confirmation prompts. Lookup/auth/network errors are reported,
not treated as a missing PR. **It never pushes automatically**; use `P` separately
when needed. Commit, push, and PR operations cannot be undone by Redline.

## Notes, Viewed, and Diff

Notes are saved in `<repo>/.comments.txt` as `path:line: text` or
`path:start-end: text`. Ranges follow buffer edits and update on save; one note
can exist per start line. Concurrent instances preserve other paths' notes,
but simultaneous edits to the same path are last-writer-wins.

Viewed marks track individual changed-line occurrences, follow edits, and
invalidate when content changes. Saved marks restore only for a matching file
snapshot; external changes may require another review.

PR review comments fetch in the background, with one automatic attempt per repo
per session. No PR is silent; outdated comments are retained. `github = false`
disables GitHub features, including the `p` action.

`:Redline diff` (or `d`, **Read changes (all files)**) opens Changes in a read-only,
full-screen tab. It compares saved files with the review base, includes untracked
files and no-final-newline markers, and leaves out `.comments.txt` and unsaved
edits. Use it to read long deletions cut short in the overlay.

- `/` searches text; `n` / `N` move between matches.
- `]h` / `[h` move to the next / previous diff hunk.
- Enter maps the saved diff line to its live source position. If that line was
  changed or deleted, it uses a nearby surviving line and warns **Approximate
  location**. It also warns when binary or encoded text cannot be mapped safely.
  Missing or deleted files stay in the diff.
- Changes stays open in its tab. Use `<leader>hb` to return directly from the
  source file. It prefers the last review used from that source window, then the
  most recently visited open review. `gt` / `gT` still cycle through tabs.
- `?` opens Help. Changes and Help preserve your existing splits; `q` or Esc
  means **Back**, closing that view and returning to where you opened it.

Action `y`, **Copy**, copies live buffer lines only, not removed text or comments.
Action `a`, **Copy for AI**, copies changes from the review base to the live
buffer, plus local notes and currently loaded PR review comments. It covers only
the selected lines or the current file, never the whole repo. A selection also
includes its live code; whole-file copy leaves out unchanged code.

Copy for AI reads fresh saved notes, including external edits, and uses their
tracked live positions when available. It does not save code or write notes.
Selection copy includes overlapping notes and PR comments that can be matched
to those lines, and reports any omitted because their positions are uncertain.
Whole-file copy includes them, with saved or unavailable positions marked.
Both copy actions use the unnamed register and try the clipboard. Copy for AI
does not run an agent or send anything automatically. Check for secrets before
sharing.

Action `z` undoes the session's last index, note, or viewed change, even if it was
in another file/repo. Normal Vim `u` only undoes buffer edits, not these actions.

## Setup

```lua
require("redline").setup({
  mode = "worktree",     -- "worktree" | "commit" | "branch"
  enabled = false,       -- overlay off until requested
  keymaps = true,
  deletions = "all",     -- "all" | "cursor" | "off"; reset when opening review
  deleted_max = "auto",  -- inline deletion cap; number, or 0 for no cap
  layout = "unified",    -- "unified" | "split" (side by side); reset when opening review
  comments = "cursor",  -- "off" | "cursor" | "all"; PR comment bodies
  github = true,
})
```

`:Redline` equals `:Redline open`. Command completion exposes only `open`,
`actions`, `diff`, `layout`, and `help`. Historical subcommands and Lua APIs remain
available for existing configurations; their no-argument scopes may differ from
the default mappings.

Highlights: `RedlineAdd`, `RedlineChange`, `RedlineDelete`, `RedlineStaged`,
`RedlineViewed`, `RedlineNote`, and `RedlineGh`, with `Ln` background and `Virt`
virtual-line variants. Override them like normal highlight groups.

## License

MIT
