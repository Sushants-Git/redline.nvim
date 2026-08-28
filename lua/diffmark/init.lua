-- diffmark: gitsigns, but the whole line gets painted (like <leader>mm marks a
-- bookmark) instead of a thin bar in the gutter.
--
-- Two diff modes, toggled at runtime:
--   worktree -- everything not committed yet (buffer vs HEAD)
--   branch   -- the whole PR: buffer vs the merge-base with main, so committed
--               work AND uncommitted edits both show up
--
-- Each changed line carries three independent bits of state, split across two
-- channels so neither has to be read against a near-identical shade:
--   gutter glyph  ┃ added   ╏ changed   ▁ removed   ✓ viewed
--   line colour   green unstaged / amber already in the index / grey viewed
--
-- "viewed" is keyed on the hash of the line's text, not its number, so it
-- follows the line around and quietly un-marks itself the moment the line
-- changes again -- which is what you want while reviewing.
--
-- On top of that: line notes. Drop a temporary note on any line, it is stored
-- in <repo>/.comments.txt as "path:line: text", which is exactly the shape an
-- agent can read back later. Notes follow the line while you edit (extmarks)
-- and the file is rewritten with fresh line numbers on every save.

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local ns_diff = api.nvim_create_namespace("diffmark")
local ns_note = api.nvim_create_namespace("diffmark_notes")
-- deleted code lives in its own namespace so it can be redrawn on cursor
-- movement without recomputing the diff
local ns_del = api.nvim_create_namespace("diffmark_deleted")
-- review comments pulled from the PR: separate from your own notes so a
-- refetch never has to touch .comments.txt
local ns_gh = api.nvim_create_namespace("diffmark_github")
-- the expanded comment body, in its own namespace for the same reason the
-- deleted code is: it is redrawn on cursor movement, the signs are not
local ns_ghx = api.nvim_create_namespace("diffmark_github_body")

local NOTES_FILE = ".comments.txt"
local NOTES_HEADER = {
    "# temp notes for the agent -- format: path:line: note",
    "# written by nvim diffmark; line numbers are kept in sync on save",
}

local state = {
    -- off until you ask for it: while disabled nothing here runs a single
    -- git command or diff, the autocmds all bail out immediately
    enabled = false,
    mode = "worktree", -- "worktree" | "commit" | "branch"
    show_deleted = "all", -- "off" | "cursor" | "all"
    -- what turning deletions back on means, and what opening a diff resets to.
    -- Removed code is the half of a review you cannot reconstruct from the
    -- buffer, so it is on unless you configure otherwise.
    deletions_default = "all",
    roots = {},        -- bufnr -> root path | false
    base = {},         -- bufnr -> { rev = string, text = string }
    index = {},        -- bufnr -> string (contents of the file in the index)
    rev = {},          -- root -> { [mode] = rev }
    hunks = {},        -- bufnr -> sorted list of marked line numbers
    index_hunks = {},  -- bufnr -> raw vim.diff hunks of index -> buffer
    deletions = {},    -- bufnr -> list of removed-code blocks (see render_diff)
    del_key = {},      -- bufnr -> which block was expanded last, to skip redraws
    counts = {},       -- bufnr -> { changed, staged, viewed }
    notes = {},        -- root -> { [relpath] = { [lnum] = text } }
    note_ids = {},     -- bufnr -> { [extmark_id] = text }
    viewed = nil,      -- root -> { [relpath] = { [linehash] = true } }
    timers = {},       -- bufnr -> timer
    default_branch = {}, -- root -> ref name | false
    notes_mtime = {},  -- root -> mtime of .comments.txt when we last read it
    undo = {},         -- bounded stack of { desc, fn } inverse operations
    gh = {},           -- root -> { pr, title, url, items = { ... } }
    gh_enabled = true, -- PR comments come along with the overlay unless you turn them off
    show_comments = "cursor", -- "off" | "cursor" | "all" -- how much of a comment body to unfold
    ghx_key = {},      -- bufnr -> which comment was unfolded last, to skip redraws
    gh_fetched = {},   -- root -> true once auto-fetch has run (or failed) this session
    gh_ids = {},       -- bufnr -> { [extmark_id] = item }
    warned_on_base = {}, -- root -> true, so the "you are on main" note fires once
}

-- git's hash of the empty tree; the base for a diff that has no parent commit
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

-- ─────────────────────────────
-- colors
-- ─────────────────────────────

local palette = {
    -- Four clearly different hues plus one neutral, rather than saturation
    -- variants of the same colour -- "green vs slightly-duller green" is the
    -- one distinction the eye cannot make while scanning.
    dark = {
        add    = { line = "#183d26", sign = "#4ade80" }, -- green
        change = { line = "#12324d", sign = "#60a5fa" }, -- blue
        delete = { line = "#4a1d22", sign = "#f87171" }, -- red
        staged = { line = "#463713", sign = "#fbbf24" }, -- amber
        viewed = { line = "#33302d", sign = "#a1a1aa" }, -- warm neutral, equidistant from all four hues
        note   = { line = "#3a2450", sign = "#d8b4fe" }, -- purple
        gh     = { line = "#0d3b40", sign = "#2dd4bf" }, -- teal, for PR review comments
    },
    light = {
        add    = { line = "#c7f0d4", sign = "#15803d" },
        change = { line = "#c8e0fb", sign = "#1d4ed8" },
        delete = { line = "#fbd0d3", sign = "#b91c1c" },
        staged = { line = "#fbeec2", sign = "#a16207" },
        viewed = { line = "#e6e3df", sign = "#6b7280" },
        note   = { line = "#e9d5ff", sign = "#7e22ce" },
        gh     = { line = "#c8ecec", sign = "#0f766e" },
    },
}

-- add -> DiffMarkAdd / DiffMarkAddLn
local function hl_name(kind)
    return "DiffMark" .. kind:gsub("^%l", string.upper)
end

local function apply_highlights()
    local c = palette[vim.o.background] or palette.dark
    for kind, col in pairs(c) do
        local name = hl_name(kind)
        api.nvim_set_hl(0, name .. "Ln", { bg = col.line })
        api.nvim_set_hl(0, name, { fg = col.sign, bold = true })
        -- for glyphs drawn *inside* a painted virtual line
        api.nvim_set_hl(0, name .. "Virt", { fg = col.sign, bg = col.line, bold = true })
    end
end

-- shape carries add/change/delete, colour carries staged/viewed -- so neither
-- channel has to do both jobs (and it survives colourblindness)
local GLYPH = { add = "┃", change = "╏", delete = "▁", viewed = "✓", gh = "󰊤" }

-- ─────────────────────────────
-- git plumbing
-- ─────────────────────────────

local function git(root, args)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { text = true }):wait()
    if res.code ~= 0 then return nil, res.stderr end
    return res.stdout or ""
end

-- `git diff --no-index` exits 1 when the files differ, which is the normal
-- case, so git() above would read it as a failure.
local function git_diff(root, args)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { text = true }):wait()
    if res.code > 1 then return nil end
    return res.stdout or ""
end

local function get_root(bufnr)
    local cached = state.roots[bufnr]
    if cached ~= nil then return cached or nil end

    local name = api.nvim_buf_get_name(bufnr)
    if name == "" then
        state.roots[bufnr] = false
        return nil
    end
    local dir = vim.fn.fnamemodify(name, ":h")
    local res = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
    if res.code ~= 0 then
        state.roots[bufnr] = false
        return nil
    end
    local root = vim.trim(res.stdout)
    state.roots[bufnr] = root
    return root
end

-- The panels are nofile buffers ("diffmark://overview"), so get_root cannot
-- find a repo from them -- which meant opening one panel while standing in
-- another silently did nothing. Fall back to the cwd.
local function current_root()
    local root = get_root(api.nvim_get_current_buf())
    if root then return root end
    local res = vim.system({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" },
        { text = true }):wait()
    if res.code ~= 0 then return nil end
    return vim.trim(res.stdout)
end

local function relpath(root, bufnr)
    local name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":p")
    if name:sub(1, #root + 1) ~= root .. "/" then return nil end
    return name:sub(#root + 2)
end

-- ─────────────────────────────
-- undo
-- ─────────────────────────────

-- Every diffmark action that touches something outside the buffer (the git
-- index, .comments.txt, the viewed store) pushes the inverse of itself here.
-- `u` cannot reach any of it -- these are not buffer edits -- so without this
-- a mis-aimed <leader>hS or <leader>hZ is simply gone.
local UNDO_MAX = 50

local function push_undo(desc, fn)
    state.undo[#state.undo + 1] = { desc = desc, fn = fn }
    if #state.undo > UNDO_MAX then table.remove(state.undo, 1) end
end

-- The index entry for one path: mode, blob sha. `false` means "not staged at
-- all", which is a state we have to be able to restore too.
local function index_entry(root, rel)
    local out = git(root, { "ls-files", "--stage", "--", rel })
    if not out or vim.trim(out) == "" then return false end
    local mode, sha = out:match("^(%d+)%s+(%x+)")
    if not mode then return false end
    return { mode = mode, sha = sha }
end

local function restore_index(root, rel, snap)
    if snap == false then
        return git(root, { "update-index", "--force-remove", "--", rel }) ~= nil
    end
    -- --add, because the path may have been removed from the index entirely
    return git(root, { "update-index", "--add", "--cacheinfo",
        string.format("%s,%s,%s", snap.mode, snap.sha, rel) }) ~= nil
end

-- The repo's actual default branch, asked for rather than guessed: the remote
-- HEAD symref is what `git clone` wrote down, so it is right on repos that use
-- develop/trunk/whatever. The guess list is only the fallback for a repo with
-- no remote (or a stale symref).
local function default_branch(root)
    if state.default_branch[root] ~= nil then return state.default_branch[root] end

    local ref
    local out = git(root, { "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" })
    if out and vim.trim(out) ~= "" then
        ref = vim.trim(out):gsub("^refs/remotes/", "")
    end
    if not ref then
        for _, cand in ipairs({ "origin/main", "main", "origin/master", "master" }) do
            if git(root, { "rev-parse", "--verify", "--quiet", cand .. "^{commit}" }) then
                ref = cand
                break
            end
        end
    end
    state.default_branch[root] = ref or false
    return state.default_branch[root]
end

-- The rev we diff against, per mode.
--   worktree -- HEAD, so only what you have not committed
--   commit   -- HEAD~1, so your latest commit plus anything dirty on top
--   branch   -- the merge-base with the default branch, so you see the whole
--               PR rather than the diff against wherever main happens to be
local function base_rev(root)
    state.rev[root] = state.rev[root] or {}
    local cached = state.rev[root][state.mode]
    if cached then return cached end

    local rev
    if state.mode == "worktree" then
        rev = "HEAD"
    elseif state.mode == "commit" then
        -- a root commit has no parent: diff against the empty tree so the
        -- first commit reads as entirely added instead of erroring out
        rev = git(root, { "rev-parse", "--verify", "--quiet", "HEAD~1^{commit}" })
        rev = rev and vim.trim(rev) ~= "" and vim.trim(rev) or EMPTY_TREE
    else
        local ref = default_branch(root)
        if ref then
            local out = git(root, { "merge-base", "HEAD", ref })
            if out and vim.trim(out) ~= "" then rev = vim.trim(out) end
        end
        if not rev then
            vim.notify("diffmark: no default branch to diff against -- showing uncommitted instead",
                vim.log.levels.WARN)
            rev = "HEAD"
        else
            -- On the default branch itself the merge-base *is* HEAD, so a
            -- "PR diff" renders nothing and reads as broken. Say so once.
            local head = git(root, { "rev-parse", "HEAD" })
            if head and vim.trim(head) == rev and not state.warned_on_base[root] then
                state.warned_on_base[root] = true
                vim.notify(("diffmark: you are on %s -- branch mode shows only uncommitted work here")
                    :format(ref), vim.log.levels.WARN)
            end
        end
    end
    state.rev[root][state.mode] = rev
    return rev
end

local function base_text(bufnr, root, rel)
    local rev = base_rev(root)
    local cached = state.base[bufnr]
    if cached and cached.rev == rev then return cached.text end

    -- cat-file, NOT `git show`: if the path is missing at this rev *and*
    -- contains glob characters (a Next.js "[slug]" route, say), `git show`
    -- decides the argument was a pathspec, falls back to HEAD and prints a
    -- whole commit -- header, message and all -- with exit code 0. That commit
    -- text then becomes the "old file" and the entire buffer reads as changed.
    -- cat-file has no pathspec fallback, so it just fails like it should.
    --
    -- missing in the base rev == brand new file, so everything counts as added
    local out = git(root, { "cat-file", "blob", rev .. ":" .. rel }) or ""
    state.base[bufnr] = { rev = rev, text = out }
    return out
end

-- What git has staged for this file right now. Empty string for a file that is
-- not in the index at all (untracked).
local function index_text(bufnr, root, rel)
    local cached = state.index[bufnr]
    if cached then return cached end
    local out = git(root, { "cat-file", "blob", ":" .. rel }) or ""
    state.index[bufnr] = out
    return out
end

local function buf_text(bufnr)
    return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
end

local function split(text)
    return vim.split(text, "\n", { plain = true })
end

-- ─────────────────────────────
-- viewed state (line-hash based, persisted outside the repo)
-- ─────────────────────────────

local function viewed_path()
    return vim.fn.stdpath("data") .. "/diffmark-viewed.json"
end

local function load_viewed()
    if state.viewed then return state.viewed end
    local fd = io.open(viewed_path(), "r")
    if not fd then
        state.viewed = {}
        return state.viewed
    end
    local ok, decoded = pcall(vim.json.decode, fd:read("*a"))
    fd:close()
    state.viewed = (ok and type(decoded) == "table") and decoded or {}
    return state.viewed
end

local function save_viewed()
    local fd = io.open(viewed_path(), "w")
    if not fd then return end
    fd:write(vim.json.encode(state.viewed or {}))
    fd:close()
end

local function line_hash(text)
    return vim.fn.sha256(text):sub(1, 16)
end

local function viewed_for(root, rel)
    local v = load_viewed()
    return (v[root] or {})[rel] or {}
end

-- ─────────────────────────────
-- rendering the diff
-- ─────────────────────────────

-- Removed code is drawn as virt_lines: display rows that are not buffer lines,
-- so line numbers, motions and :w are all untouched and the buffer stays as
-- editable as it was. That is the whole point -- a diff you can type into.
--
--   off     nothing, just the gutter glyph (as before)
--   cursor  only the block the cursor is sitting in unfolds
--   all     every removed block, for reading a branch top to bottom
local function render_deletions(bufnr)
    if not api.nvim_buf_is_valid(bufnr) then return end
    api.nvim_buf_clear_namespace(bufnr, ns_del, 0, -1)
    if not state.enabled or state.show_deleted == "off" then return end

    local blocks = state.deletions[bufnr] or {}
    if #blocks == 0 then return end

    -- in cursor mode only the focused window has a meaningful cursor, so a
    -- buffer shown elsewhere simply gets nothing
    local cur
    if state.show_deleted == "cursor" then
        local win = api.nvim_get_current_win()
        if api.nvim_win_get_buf(win) ~= bufnr then return end
        cur = api.nvim_win_get_cursor(win)[1]
    end

    local total = api.nvim_buf_line_count(bufnr)
    local ts = vim.bo[bufnr].tabstop
    for _, b in ipairs(blocks) do
        if (not cur or (cur >= b.lo and cur <= b.hi)) and b.row >= 0 and b.row < total then
            -- virt_text does not expand tabs, and an unpadded chunk paints only
            -- as wide as its text -- pad to the widest line so it reads as a block
            local expanded, width = {}, 0
            for i, l in ipairs(b.lines) do
                local text = l:gsub("\t", string.rep(" ", ts))
                expanded[i] = text
                width = math.max(width, vim.fn.strdisplaywidth(text))
            end
            local virt = {}
            for i, text in ipairs(expanded) do
                virt[i] = {
                    { GLYPH.delete .. " ", "DiffMarkDeleteVirt" },
                    { text .. string.rep(" ", width - vim.fn.strdisplaywidth(text) + 1), "DiffMarkDeleteLn" },
                }
            end
            pcall(api.nvim_buf_set_extmark, bufnr, ns_del, b.row, 0, {
                virt_lines = virt,
                virt_lines_above = b.above,
                priority = 5,
            })
        end
    end
end

local function render_diff(bufnr)
    if not api.nvim_buf_is_valid(bufnr) then return end
    api.nvim_buf_clear_namespace(bufnr, ns_diff, 0, -1)
    api.nvim_buf_clear_namespace(bufnr, ns_del, 0, -1)
    state.hunks[bufnr] = {}
    state.index_hunks[bufnr] = {}
    state.deletions[bufnr] = {}
    state.del_key[bufnr] = nil
    state.counts[bufnr] = { changed = 0, staged = 0, viewed = 0 }

    if not state.enabled then return end
    if vim.bo[bufnr].buftype ~= "" then return end

    local root = get_root(bufnr)
    if not root then return end
    local rel = relpath(root, bufnr)
    if not rel then return end

    local cur = buf_text(bufnr)
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local total = #lines

    -- vim.diff, not `git diff`, so unsaved changes are marked as you type
    local opts = { result_type = "indices", algorithm = "histogram" }
    local vs_base = vim.diff(base_text(bufnr, root, rel), cur, opts) or {}
    local vs_index = vim.diff(index_text(bufnr, root, rel), cur, opts) or {}
    state.index_hunks[bufnr] = vs_index

    -- anything still differing from the index is unstaged; everything else the
    -- base diff turned up must already be in the index
    local unstaged = {}
    for _, h in ipairs(vs_index) do
        local new_start, new_count = h[3], h[4]
        if new_count == 0 then
            unstaged[math.max(new_start, 1)] = true
        else
            for i = 0, new_count - 1 do unstaged[new_start + i] = true end
        end
    end

    local marked = {}
    local deletions = {}
    local base_lines -- only split the base blob if something was actually removed
    for _, h in ipairs(vs_base) do
        local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
        local kind = (new_count == 0 and "delete") or (old_count == 0 and "add") or "change"
        if kind == "delete" then
            marked[#marked + 1] = { math.max(new_start, 1), kind }
        else
            for i = 0, new_count - 1 do marked[#marked + 1] = { new_start + i, kind } end
        end

        if old_count > 0 then
            base_lines = base_lines or split(base_text(bufnr, root, rel))
            local removed = {}
            for i = old_start, old_start + old_count - 1 do
                removed[#removed + 1] = base_lines[i] or ""
            end

            -- row is 0-indexed. lo/hi is the buffer range that counts as "the
            -- cursor is in this block" for cursor mode.
            local row, above, lo, hi
            if new_count == 0 then
                -- pure deletion: new_start is the line the removed text sat
                -- *after*, and 0 means it was removed from the top of the file
                if new_start < 1 then
                    row, above = 0, true
                else
                    row, above = new_start - 1, false
                end
                lo = math.max(new_start, 1)
                hi = lo + 1 -- either side of the gap counts
            else
                -- a change: put the old text directly above the new, so the
                -- block reads top-to-bottom like a real diff
                row, above = new_start - 1, true
                lo, hi = new_start, new_start + new_count - 1
            end
            deletions[#deletions + 1] = { row = row, above = above, lines = removed, lo = lo, hi = hi }
        end
    end
    state.deletions[bufnr] = deletions

    local seen = viewed_for(root, rel)
    local counts = state.counts[bufnr]

    for _, m in ipairs(marked) do
        local lnum, kind = m[1], m[2]
        if lnum >= 1 and lnum <= total then
            local is_staged = not unstaged[lnum]
            local is_viewed = seen[line_hash(lines[lnum])] == true

            local group, glyph
            if is_viewed then
                group, glyph = "viewed", GLYPH.viewed
            elseif is_staged then
                group, glyph = "staged", GLYPH[kind]
            else
                group, glyph = kind, GLYPH[kind]
            end
            local name = hl_name(group)

            pcall(api.nvim_buf_set_extmark, bufnr, ns_diff, lnum - 1, 0, {
                sign_text = glyph,
                sign_hl_group = name,
                -- a deleted line has no line left to paint, only the gutter marks it
                line_hl_group = (kind ~= "delete" or is_viewed) and (name .. "Ln") or nil,
                -- below bookmarks (8) so <leader>mm always wins the line
                priority = 6,
            })
            table.insert(state.hunks[bufnr], lnum)
            counts.changed = counts.changed + 1
            if is_staged then counts.staged = counts.staged + 1 end
            if is_viewed then counts.viewed = counts.viewed + 1 end
        end
    end
    table.sort(state.hunks[bufnr])
    render_deletions(bufnr)
end

-- ─────────────────────────────
-- notes (.comments.txt)
-- ─────────────────────────────

local function notes_path(root)
    return root .. "/" .. NOTES_FILE
end

-- The file on disk is shared with every other nvim running against this repo,
-- so it is the source of truth and our copy is only a cache. Re-read whenever
-- the mtime moves.
local function read_notes_file(root)
    local notes = {}
    local fd = io.open(notes_path(root), "r")
    if fd then
        for line in fd:lines() do
            if not line:match("^%s*#") and vim.trim(line) ~= "" then
                local rel, lnum, text = line:match("^([^:]+):(%d+):%s?(.*)$")
                if rel then
                    notes[rel] = notes[rel] or {}
                    notes[rel][tonumber(lnum)] = text
                end
            end
        end
        fd:close()
    end
    return notes
end

local function notes_mtime(root)
    local st = uv.fs_stat(notes_path(root))
    if not st then return 0 end
    return st.mtime.sec * 1000000000 + st.mtime.nsec
end

local function load_notes(root)
    local mt = notes_mtime(root)
    if state.notes[root] and state.notes_mtime[root] == mt then
        return state.notes[root]
    end
    state.notes[root] = read_notes_file(root)
    state.notes_mtime[root] = mt
    return state.notes[root]
end

-- `owned` is the set of paths this write is authoritative for. Everything else
-- is taken from whatever is on disk *right now*, not from the snapshot we
-- loaded -- otherwise a second nvim that added a note since we started would
-- have it silently erased the next time we saved a buffer. Pass nil only for
-- deliberately destructive rewrites (clear all).
local function write_notes(root, owned)
    local mem = state.notes[root] or {}
    local notes
    if owned then
        notes = read_notes_file(root)
        for rel in pairs(owned) do notes[rel] = mem[rel] end
    else
        notes = mem
    end

    local rels = vim.tbl_keys(notes)
    table.sort(rels)

    local lines = vim.deepcopy(NOTES_HEADER)
    local count = 0
    for _, rel in ipairs(rels) do
        local lnums = vim.tbl_keys(notes[rel])
        table.sort(lnums)
        for _, lnum in ipairs(lnums) do
            lines[#lines + 1] = string.format("%s:%d: %s", rel, lnum, notes[rel][lnum])
            count = count + 1
        end
    end

    state.notes[root] = notes

    local path = notes_path(root)
    if count == 0 then
        os.remove(path)
        state.notes_mtime[root] = notes_mtime(root)
        return
    end
    local fd = io.open(path, "w")
    if not fd then
        vim.notify("diffmark: cannot write " .. path, vim.log.levels.ERROR)
        return
    end
    fd:write(table.concat(lines, "\n"), "\n")
    fd:close()
    state.notes_mtime[root] = notes_mtime(root)
end

local function render_notes(bufnr)
    if not api.nvim_buf_is_valid(bufnr) then return end
    api.nvim_buf_clear_namespace(bufnr, ns_note, 0, -1)
    state.note_ids[bufnr] = {}

    local root = get_root(bufnr)
    if not root then return end
    local rel = relpath(root, bufnr)
    if not rel then return end

    local notes = load_notes(root)[rel]
    if not notes then return end

    local total = api.nvim_buf_line_count(bufnr)
    for lnum, text in pairs(notes) do
        if lnum >= 1 and lnum <= total then
            local ok, id = pcall(api.nvim_buf_set_extmark, bufnr, ns_note, lnum - 1, 0, {
                sign_text = "󰆉",
                sign_hl_group = "DiffMarkNote",
                line_hl_group = "DiffMarkNoteLn",
                virt_text = { { "  " .. text, "DiffMarkNote" } },
                virt_text_pos = "eol",
                priority = 9,
            })
            if ok then state.note_ids[bufnr][id] = text end
        end
    end
end

-- Notes are anchored to extmarks, so after edits their real line numbers have
-- drifted. Pull the positions back out before writing the file.
local function sync_notes(bufnr)
    local root = get_root(bufnr)
    if not root then return end
    local rel = relpath(root, bufnr)
    if not rel then return end
    local ids = state.note_ids[bufnr]
    if not ids or vim.tbl_isempty(ids) then return end

    local fresh = {}
    for id, text in pairs(ids) do
        local pos = api.nvim_buf_get_extmark_by_id(bufnr, ns_note, id, {})
        if pos and pos[1] then fresh[pos[1] + 1] = text end
    end
    local notes = load_notes(root)
    notes[rel] = next(fresh) and fresh or nil
    write_notes(root, { [rel] = true })
end

local function note_at_cursor(bufnr, lnum)
    local marks = api.nvim_buf_get_extmarks(bufnr, ns_note, { lnum - 1, 0 }, { lnum - 1, -1 }, {})
    local ids = state.note_ids[bufnr] or {}
    for _, m in ipairs(marks) do
        if ids[m[1]] then return m[1], ids[m[1]] end
    end
end


-- ─────────────────────────────
-- github review comments
-- ─────────────────────────────

-- defined further down, next to the rest of the render scheduling
local ensure_enabled
-- unfolds a comment body; defined below render_gh but called from it
local render_gh_body
-- the mode -> human label map, declared with the rest of the legend below
local MODE_LABEL

-- A spinner parked in the bottom-right corner. The fetch itself is async --
-- gh over the network is far too slow to block the editor on -- so this is the
-- only signal that anything is happening.
local spin = {
    frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    timer = nil, win = nil, buf = nil, i = 1, text = "",
}

local function spin_stop()
    if spin.timer then
        spin.timer:stop()
        spin.timer:close()
        spin.timer = nil
    end
    if spin.win and api.nvim_win_is_valid(spin.win) then
        api.nvim_win_close(spin.win, true)
    end
    spin.win, spin.buf = nil, nil
end

local function spin_draw()
    if not (spin.buf and api.nvim_buf_is_valid(spin.buf)) then return end
    local line = " " .. spin.frames[spin.i] .. " " .. spin.text .. " "
    api.nvim_buf_set_lines(spin.buf, 0, -1, false, { line })
    api.nvim_buf_add_highlight(spin.buf, -1, "DiffMarkGh", 0, 0, -1)
    if spin.win and api.nvim_win_is_valid(spin.win) then
        api.nvim_win_set_config(spin.win, {
            relative = "editor",
            width = vim.fn.strdisplaywidth(line),
            height = 1,
            row = vim.o.lines - 3,
            col = math.max(0, vim.o.columns - vim.fn.strdisplaywidth(line) - 1),
            style = "minimal",
        })
    end
end

local function spin_start(text)
    spin_stop()
    spin.text, spin.i = text, 1
    spin.buf = api.nvim_create_buf(false, true)
    vim.bo[spin.buf].bufhidden = "wipe"
    local width = vim.fn.strdisplaywidth(" " .. spin.frames[1] .. " " .. text .. " ")
    spin.win = api.nvim_open_win(spin.buf, false, {
        relative = "editor",
        width = width,
        height = 1,
        row = vim.o.lines - 3,
        col = math.max(0, vim.o.columns - width - 1),
        style = "minimal",
        border = "none",
        focusable = false,
        zindex = 200,
    })
    vim.wo[spin.win].winhl = "Normal:DiffMarkGhLn"
    spin_draw()
    spin.timer = uv.new_timer()
    spin.timer:start(80, 80, vim.schedule_wrap(function()
        spin.i = spin.i % #spin.frames + 1
        spin_draw()
    end))
end

-- Comments live on line numbers from the PR head commit. Once you have edited
-- the file those numbers drift, exactly like notes do -- so they get extmarks
-- too, and the panel reads positions back out of them.
local function render_gh(bufnr)
    if not api.nvim_buf_is_valid(bufnr) then return end
    api.nvim_buf_clear_namespace(bufnr, ns_gh, 0, -1)
    state.gh_ids[bufnr] = {}

    local root = get_root(bufnr)
    if not root then return end
    local data = state.gh[root]
    if not data then return end
    local rel = relpath(root, bufnr)
    if not rel then return end

    local total = api.nvim_buf_line_count(bufnr)
    for _, item in ipairs(data.items) do
        if item.path == rel and item.line and item.line >= 1 and item.line <= total then
            local head = item.body:gsub("%s+", " ")
            if #head > 60 then head = head:sub(1, 59) .. "…" end
            local ok, id = pcall(api.nvim_buf_set_extmark, bufnr, ns_gh, item.line - 1, 0, {
                sign_text = GLYPH.gh,
                sign_hl_group = "DiffMarkGh",
                virt_text = { { "  @" .. item.author .. ": " .. head, "DiffMarkGh" } },
                virt_text_pos = "eol",
                priority = 8,
            })
            if ok then state.gh_ids[bufnr][id] = item end
        end
    end
    render_gh_body(bufnr)
end

-- Greedy wrap; comment bodies are prose and a review paragraph is routinely
-- wider than the window.
local function wrap(text, width)
    local out = {}
    for _, para in ipairs(vim.split(text:gsub("\r", ""), "\n")) do
        if vim.trim(para) == "" then
            out[#out + 1] = ""
        else
            local line = ""
            for word in para:gmatch("%S+") do
                if line == "" then
                    line = word
                elseif #line + #word + 1 <= width then
                    line = line .. " " .. word
                else
                    out[#out + 1] = line
                    line = word
                end
            end
            if line ~= "" then out[#out + 1] = line end
        end
    end
    return out
end

-- The eol virt_text is only ever a one-line preview. This unfolds the whole
-- body underneath the line as a padded block, the same way removed code is
-- shown -- off / under the cursor / all, on the same three-way switch.
function render_gh_body(bufnr)
    if not api.nvim_buf_is_valid(bufnr) then return end
    api.nvim_buf_clear_namespace(bufnr, ns_ghx, 0, -1)
    if not state.enabled or state.show_comments == "off" then return end

    local ids = state.gh_ids[bufnr]
    if not ids or vim.tbl_isempty(ids) then return end

    local cur
    if state.show_comments == "cursor" then
        local win = api.nvim_get_current_win()
        if api.nvim_win_get_buf(win) ~= bufnr then return end
        cur = api.nvim_win_get_cursor(win)[1]
    end

    local width = math.max(40, math.min(90, api.nvim_win_get_width(0) - 12))
    for id, item in pairs(ids) do
        local pos = api.nvim_buf_get_extmark_by_id(bufnr, ns_gh, id, {})
        if pos and pos[1] and (not cur or cur == pos[1] + 1) then
            local body = wrap(item.body, width)
            local head = "@" .. item.author .. (item.line and "" or "  (outdated)")
            local rows = { head }
            vim.list_extend(rows, body)

            local w = 0
            for _, l in ipairs(rows) do w = math.max(w, vim.fn.strdisplaywidth(l)) end

            local virt = {}
            for i, text in ipairs(rows) do
                virt[i] = {
                    { i == 1 and (GLYPH.gh .. " ") or "   ", "DiffMarkGhVirt" },
                    { text .. string.rep(" ", w - vim.fn.strdisplaywidth(text) + 1), "DiffMarkGhLn" },
                }
            end
            pcall(api.nvim_buf_set_extmark, bufnr, ns_ghx, pos[1], 0, {
                virt_lines = virt,
                priority = 6,
            })
        end
    end
end

local function render_gh_all()
    for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) then render_gh(b) end
    end
end

-- ── side panels ──
--
-- Two of these: the PR comment list and the repo-wide overview. They differ
-- only in what they put in the buffer, so the window plumbing is shared and
-- each one owns a `render(P)` that fills in lines/targets/highlights.

local function new_panel(name, width)
    return { win = nil, buf = nil, targets = {}, copies = {}, name = name, width = width }
end

local gh_panel = new_panel("github", 62)
local ov_panel = new_panel("overview", 56)

local function panel_close(P)
    if P.win and api.nvim_win_is_valid(P.win) then
        api.nvim_win_close(P.win, true)
    end
    P.win, P.buf = nil, nil
end

local function panel_jump(P)
    local target = P.targets[api.nvim_win_get_cursor(0)[1]]
    if not target then return end
    -- back to whatever window we came from, rather than opening the file
    -- inside the panel itself
    local prev
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        if w ~= P.win and w ~= gh_panel.win and w ~= ov_panel.win then prev = w break end
    end
    if not prev then return end
    api.nvim_set_current_win(prev)
    vim.cmd("edit " .. vim.fn.fnameescape(target.file))
    pcall(api.nvim_win_set_cursor, 0, { target.line, 0 })
    vim.cmd("normal! zz")
end

-- `y` on a comment copies the whole comment, not the one wrapped line the
-- cursor happens to sit on. Falls back to the visible line when a row does not
-- stand for anything bigger.
local function panel_copy(P, whole)
    local text
    if whole then
        text = table.concat(api.nvim_buf_get_lines(P.buf, 0, -1, false), "\n")
    else
        local row = api.nvim_win_get_cursor(0)[1]
        text = P.copies[row] or api.nvim_buf_get_lines(P.buf, row - 1, row, false)[1] or ""
    end
    text = vim.trim(text)
    if text == "" then return end
    vim.fn.setreg("+", text)
    vim.fn.setreg('"', text)
    local n = #vim.split(text, "\n")
    M.legend(string.format("copied %d line%s", n, n == 1 and "" or "s"))
end

local function panel_fill(P, lines, targets, hls, copies)
    P.targets = targets
    -- what `y` on a given row puts on the clipboard, when the row stands for
    -- something richer than the single line you can see
    P.copies = copies or {}
    vim.bo[P.buf].modifiable = true
    api.nvim_buf_set_lines(P.buf, 0, -1, false, lines)
    vim.bo[P.buf].modifiable = false
    api.nvim_buf_clear_namespace(P.buf, ns_gh, 0, -1)
    for lnum, hl in pairs(hls) do
        pcall(api.nvim_buf_add_highlight, P.buf, ns_gh, hl, lnum - 1, 0, -1)
    end
end

-- `focus` only for the explicit toggle: an automatic sync should drop the panel
-- beside you and leave the cursor in the code you were reading.
local function panel_open(P, render, root, focus)
    if P.win and api.nvim_win_is_valid(P.win) then
        render(P, root)
        if focus then api.nvim_set_current_win(P.win) end
        return
    end
    local from = api.nvim_get_current_win()
    P.buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(P.buf, "diffmark://" .. P.name)
    vim.bo[P.buf].buftype = "nofile"
    vim.bo[P.buf].bufhidden = "wipe"
    vim.bo[P.buf].filetype = "diffmark-" .. P.name

    vim.cmd("vsplit")
    P.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(P.win, P.buf)
    api.nvim_win_set_width(P.win, P.width)
    vim.wo[P.win].number = false
    vim.wo[P.win].relativenumber = false
    vim.wo[P.win].signcolumn = "no"
    vim.wo[P.win].wrap = true
    vim.wo[P.win].winfixwidth = true

    vim.keymap.set("n", "q", function() panel_close(P) end, { buffer = P.buf, desc = "close" })
    vim.keymap.set("n", "<CR>", function() panel_jump(P) end, { buffer = P.buf, desc = "jump" })
    vim.keymap.set("n", "y", function() panel_copy(P) end, { buffer = P.buf, desc = "copy this entry" })
    vim.keymap.set("n", "Y", function() panel_copy(P, true) end, { buffer = P.buf, desc = "copy the whole panel" })

    render(P, root)
    if not focus and api.nvim_win_is_valid(from) then api.nvim_set_current_win(from) end
end

-- ── the PR comment list ──

local function gh_render(P, root)
    local data = state.gh[root]
    local lines, targets, hls, copies = {}, {}, {}, {}

    if not data then
        lines = { " no comments fetched yet", "", " <leader>hg to sync" }
    else
        lines[#lines + 1] = string.format(" %s PR #%d  %s", GLYPH.gh, data.pr, data.title or "")
        hls[#lines] = "DiffMarkGh"
        lines[#lines + 1] = ""

        local by_file, order = {}, {}
        for _, item in ipairs(data.items) do
            if not by_file[item.path] then
                by_file[item.path] = {}
                order[#order + 1] = item.path
            end
            table.insert(by_file[item.path], item)
        end
        table.sort(order)

        for _, path in ipairs(order) do
            lines[#lines + 1] = " " .. path
            hls[#lines] = "Directory"
            table.sort(by_file[path], function(a, b) return (a.line or 0) < (b.line or 0) end)
            for _, item in ipairs(by_file[path]) do
                local full = string.format("%s:%s  @%s\n%s", path,
                    item.line or "outdated", item.author, item.body:gsub("\r", ""))
                lines[#lines + 1] = string.format("  %s  @%s",
                    item.line and (item.line .. "") or "outdated", item.author)
                hls[#lines] = "Comment"
                targets[#lines] = { file = root .. "/" .. path, line = item.line or 1 }
                copies[#lines] = full
                for _, l in ipairs(vim.split(item.body:gsub("\r", ""), "\n")) do
                    lines[#lines + 1] = "     " .. l
                    targets[#lines] = { file = root .. "/" .. path, line = item.line or 1 }
                    copies[#lines] = full
                end
            end
            lines[#lines + 1] = ""
        end
        if #data.items == 0 then
            lines[#lines + 1] = " (no review comments on this PR)"
        end
    end

    panel_fill(P, lines, targets, hls, copies)
end

-- ── the overview ──
--
-- Everything under review in one list, without opening a single file: what
-- changed, what is staged, what you have already ticked off, and where the
-- notes and PR comments are. Built from git plus the stores, so it covers
-- files that are not loaded in a buffer.

-- --numstat gives how much changed but not where, so "open this file" had
-- nowhere to aim and fell back to line 1. One --unified=0 pass over the same
-- rev gives the first changed line per path, which is where the cursor should
-- actually land. Deliberately uncached: the working tree moves under us and a
-- stale landing line is worse than one extra git call per overview.
local function first_changed_lines(root, rev)
    local map = {}
    local cur
    for _, line in ipairs(vim.split(git(root, { "diff", "--unified=0", "--no-color", rev }) or "", "\n")) do
        if line:sub(1, 4) == "+++ " then
            -- +++ /dev/null is a file deleted outright; there is no new line to go to
            cur = line:match("^%+%+%+ b/(.+)$")
        elseif cur then
            local at = line:match("^@@ %-%d+,?%d* %+(%d+)")
            if at then
                map[cur] = tonumber(at)
                cur = nil -- only the first hunk of each file matters
            end
        end
    end
    return map
end

local function overview_data(root)
    local rev = base_rev(root)
    local files, order = {}, {}

    local function slot(rel)
        -- our own scratch file is not part of anyone's review
        if rel == NOTES_FILE then return { add = 0, del = 0, notes = 0, comments = 0 } end
        if not files[rel] then
            files[rel] = { add = 0, del = 0, staged = false, notes = 0, comments = 0, first = nil,
                changed = false }
            order[#order + 1] = rel
        end
        return files[rel]
    end

    for _, line in ipairs(vim.split(git(root, { "diff", "--numstat", rev }) or "", "\n")) do
        local a, d, rel = line:match("^(%S+)\t(%S+)\t(.+)$")
        if rel then
            local f = slot(rel)
            f.add, f.del = tonumber(a) or 0, tonumber(d) or 0
            f.changed = true
        end
    end
    -- brand new files never show up in `diff` against a rev they do not exist in
    for _, rel in ipairs(vim.split(git(root, { "ls-files", "--others", "--exclude-standard" }) or "", "\n")) do
        if vim.trim(rel) ~= "" then slot(rel).untracked = true end
    end
    for _, line in ipairs(vim.split(git(root, { "diff", "--numstat", "--cached" }) or "", "\n")) do
        local rel = line:match("^%S+\t%S+\t(.+)$")
        if rel then slot(rel).staged = true end
    end

    for rel, lnums in pairs(load_notes(root)) do
        local f = slot(rel)
        for lnum in pairs(lnums) do
            f.notes = f.notes + 1
            f.first = math.min(f.first or lnum, lnum)
        end
    end
    local gh = state.gh[root]
    if gh then
        for _, item in ipairs(gh.items) do
            local f = slot(item.path)
            f.comments = f.comments + 1
            if item.line then f.first = math.min(f.first or item.line, item.line) end
        end
    end
    -- after the note/comment passes on purpose: for a file that really changed,
    -- the first changed line is what "go to this file" means. A file that is
    -- only in the list because a comment points at it keeps that comment's line.
    for rel, lnum in pairs(first_changed_lines(root, rev)) do
        if files[rel] then files[rel].first = lnum end
    end

    -- Viewed marks pull a file into the list even when its diff is gone: you
    -- put them there deliberately, so the file staying visible is a record of
    -- what you reviewed, not noise. Same reasoning as notes and PR comments.
    local viewed = (load_viewed() or {})[root] or {}
    for rel, hashes in pairs(viewed) do
        local n = 0
        for _ in pairs(hashes) do n = n + 1 end
        slot(rel).viewed = n
    end

    table.sort(order)
    return files, order
end

local function overview_render(P, root)
    local lines, targets, hls = {}, {}, {}
    local files, order = overview_data(root)

    lines[#lines + 1] = " diffmark  ·  " .. (MODE_LABEL[state.mode] or state.mode)
    hls[#lines] = "Title"
    local gh = state.gh[root]
    if gh then
        lines[#lines + 1] = string.format(" %s PR #%d  %s", GLYPH.gh, gh.pr, gh.title or "")
        hls[#lines] = "DiffMarkGh"
    end
    lines[#lines + 1] = ""

    local t = { add = 0, del = 0, notes = 0, comments = 0, viewed = 0 }
    for _, rel in ipairs(order) do
        local f = files[rel]
        t.add, t.del = t.add + f.add, t.del + f.del
        t.notes, t.comments = t.notes + f.notes, t.comments + f.comments
        t.viewed = t.viewed + (f.viewed or 0)
    end
    lines[#lines + 1] = string.format(" %d file%s  +%d −%d   %s%d  %s%d  %s%d",
        #order, #order == 1 and "" or "s", t.add, t.del,
        "󰆉", t.notes, GLYPH.gh, t.comments, GLYPH.viewed, t.viewed)
    hls[#lines] = "Comment"
    lines[#lines + 1] = ""

    if #order == 0 then
        lines[#lines + 1] = " nothing changed against this base"
        hls[#lines] = "Comment"
    end

    for _, rel in ipairs(order) do
        local f = files[rel]
        lines[#lines + 1] = " " .. rel
        hls[#lines] = f.staged and "DiffMarkStaged" or "Directory"
        targets[#lines] = { file = root .. "/" .. rel, line = f.first or 1 }

        local bits = {}
        if f.untracked then
            bits[#bits + 1] = "new"
        elseif f.changed then
            bits[#bits + 1] = string.format("+%d −%d", f.add, f.del)
        else
            -- only here because a comment or note points at it; "+0 −0" would
            -- read as "tracked and unchanged", which is a different thing
            bits[#bits + 1] = vim.uv.fs_stat(root .. "/" .. rel) and "unchanged" or "not in tree"
        end
        if f.staged then bits[#bits + 1] = "staged" end
        if (f.viewed or 0) > 0 then bits[#bits + 1] = GLYPH.viewed .. f.viewed end
        if f.notes > 0 then bits[#bits + 1] = "󰆉" .. f.notes end
        if f.comments > 0 then bits[#bits + 1] = GLYPH.gh .. f.comments end
        lines[#lines + 1] = "   " .. table.concat(bits, "  ")
        hls[#lines] = "Comment"
        targets[#lines] = { file = root .. "/" .. rel, line = f.first or 1 }

        -- the actual review surface: where the comments and notes are
        if gh then
            for _, item in ipairs(gh.items) do
                if item.path == rel then
                    local body = item.body:gsub("%s+", " ")
                    if #body > 34 then body = body:sub(1, 33) .. "…" end
                    lines[#lines + 1] = string.format("   %s %s @%s  %s", GLYPH.gh,
                        item.line and (item.line .. "") or "—", item.author, body)
                    hls[#lines] = "DiffMarkGh"
                    targets[#lines] = { file = root .. "/" .. rel, line = item.line or 1 }
                end
            end
        end
        for lnum, text in pairs(load_notes(root)[rel] or {}) do
            local short = text:gsub("%s+", " ")
            if #short > 34 then short = short:sub(1, 33) .. "…" end
            lines[#lines + 1] = string.format("   󰆉 %d  %s", lnum, short)
            hls[#lines] = "DiffMarkNote"
            targets[#lines] = { file = root .. "/" .. rel, line = lnum }
        end
        lines[#lines + 1] = ""
    end

    panel_fill(P, lines, targets, hls)
end

-- The split panel is the fallback for a setup without telescope.
function M.overview_split()
    if ov_panel.win and api.nvim_win_is_valid(ov_panel.win) then
        panel_close(ov_panel)
        return
    end
    local root = current_root()
    if not root then
        vim.notify("diffmark: not inside a git repository", vim.log.levels.WARN)
        return
    end
    ensure_enabled()
    panel_open(ov_panel, overview_render, root, true)
end

-- One flat, fuzzy-searchable list: every changed file, and under it every PR
-- comment and note sitting in that file. Typing filters across paths, authors
-- and comment text at once, and the preview pane shows the actual line.
local function overview_entries(root)
    local files, order = overview_data(root)
    local gh = state.gh[root]
    local notes = load_notes(root)
    local out = {}

    for _, rel in ipairs(order) do
        local f = files[rel]
        out[#out + 1] = { kind = "file", rel = rel, f = f, line = f.first or 1 }

        if gh then
            local mine = {}
            for _, item in ipairs(gh.items) do
                if item.path == rel then mine[#mine + 1] = item end
            end
            table.sort(mine, function(a, b) return (a.line or 0) < (b.line or 0) end)
            for _, item in ipairs(mine) do
                out[#out + 1] = { kind = "comment", rel = rel, line = item.line or 1,
                    author = item.author, body = item.body, outdated = item.line == nil,
                    diff_hunk = item.diff_hunk }
            end
        end

        local lnums = vim.tbl_keys(notes[rel] or {})
        table.sort(lnums)
        for _, lnum in ipairs(lnums) do
            out[#out + 1] = { kind = "note", rel = rel, line = lnum, body = notes[rel][lnum] }
        end
    end
    return out
end

local function file_stats(f)
    local bits = {}
    if f.untracked then
        bits[#bits + 1] = "new"
    elseif f.changed then
        bits[#bits + 1] = string.format("+%d −%d", f.add, f.del)
    else
        bits[#bits + 1] = "unchanged"
    end
    if f.staged then bits[#bits + 1] = "staged" end
    if (f.viewed or 0) > 0 then bits[#bits + 1] = GLYPH.viewed .. f.viewed end
    if f.notes > 0 then bits[#bits + 1] = "󰆉" .. f.notes end
    if f.comments > 0 then bits[#bits + 1] = GLYPH.gh .. f.comments end
    return table.concat(bits, "  ")
end

-- The preview is the point of the overview, so it answers the question the
-- selected row actually asks: a file row previews its diff, a comment row
-- previews the comment and the code it hangs off, a note row previews the note
-- against the lines around it. <CR> goes to the line in every case.
local ns_prev = api.nvim_create_namespace("diffmark_preview")

local function hunk_hl(line)
    if line:match("^@@") then return "DiffMarkChange" end
    if line:match("^%+") then return "DiffMarkAdd" end
    if line:match("^%-") then return "DiffMarkDelete" end
    return nil
end

local function preview_comment(e, root, width)
    local lines, hls = {}, {}
    local glyph = e.kind == "note" and "󰆉" or GLYPH.gh
    local who = e.kind == "note" and "note" or ("@" .. e.author)

    lines[#lines + 1] = string.format("%s %s  ·  %s:%s", glyph, who, e.rel,
        e.outdated and "outdated" or e.line)
    hls[#lines] = e.kind == "note" and "DiffMarkNote" or "DiffMarkGh"
    lines[#lines + 1] = string.rep("─", math.min(width, 78))
    hls[#lines] = "Comment"

    vim.list_extend(lines, wrap(e.body, math.min(width - 2, 76)))
    lines[#lines + 1] = ""

    if e.diff_hunk then
        lines[#lines + 1] = "── the code this comment is on " .. string.rep("─", 24)
        hls[#lines] = "Comment"
        for _, l in ipairs(vim.split(e.diff_hunk:gsub("\r", ""), "\n")) do
            lines[#lines + 1] = l
            hls[#lines] = hunk_hl(l)
        end
    else
        -- a note, or a comment whose hunk the API did not give us: fall back to
        -- the live file around the line
        local path = root .. "/" .. e.rel
        if vim.uv.fs_stat(path) then
            lines[#lines + 1] = "── context " .. string.rep("─", 44)
            hls[#lines] = "Comment"
            local all = vim.fn.readfile(path)
            for i = math.max(1, e.line - 6), math.min(#all, e.line + 6) do
                lines[#lines + 1] = string.format("%5d  %s", i, all[i])
                if i == e.line then hls[#lines] = "DiffMarkChangeLn" end
            end
        end
    end
    return lines, hls, nil
end

local function preview_file(e, root)
    local out
    if e.f.untracked then
        out = git_diff(root, { "diff", "--no-index", "--", "/dev/null", e.rel })
    elseif e.f.changed then
        out = git_diff(root, { "diff", base_rev(root), "--", e.rel })
    end
    if not out or vim.trim(out) == "" then
        local path = root .. "/" .. e.rel
        if not vim.uv.fs_stat(path) then
            return { e.rel, "", "not present in this working tree" }, { [3] = "Comment" }, nil
        end
        return vim.fn.readfile(path), {}, vim.filetype.match({ filename = path })
    end
    return vim.split(out, "\n"), {}, "diff"
end

local function overview_previewer(root)
    local previewers = require("telescope.previewers")
    return previewers.new_buffer_previewer({
        title = "diffmark preview",
        dyn_title = function(_, entry)
            local e = entry.value
            if e.kind == "file" then return e.rel .. "  (diff)" end
            return string.format("%s:%s", e.rel, e.outdated and "outdated" or e.line)
        end,
        define_preview = function(self, entry)
            local bufnr = self.state.bufnr
            local e = entry.value
            local width = api.nvim_win_get_width(self.state.winid or 0)

            local lines, hls, ft
            if e.kind == "file" then
                lines, hls, ft = preview_file(e, root)
            else
                lines, hls, ft = preview_comment(e, root, width)
            end

            api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            api.nvim_buf_clear_namespace(bufnr, ns_prev, 0, -1)
            if ft then
                require("telescope.previewers.utils").highlighter(bufnr, ft)
            else
                vim.bo[bufnr].filetype = ""
                for lnum, hl in pairs(hls) do
                    pcall(api.nvim_buf_add_highlight, bufnr, ns_prev, hl, lnum - 1, 0, -1)
                end
            end
            -- put the line being discussed in the middle of the pane
            if e.kind == "file" and ft ~= "diff" and self.state.winid then
                pcall(api.nvim_win_set_cursor, self.state.winid, { math.min(e.line, #lines), 0 })
            end
        end,
    })
end

function M.overview()
    local ok_pickers, pickers = pcall(require, "telescope.pickers")
    if not ok_pickers then return M.overview_split() end
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local entry_display = require("telescope.pickers.entry_display")
    local ok_dev, devicons = pcall(require, "nvim-web-devicons")

    local root = current_root()
    if not root then
        vim.notify("diffmark: not inside a git repository", vim.log.levels.WARN)
        return
    end
    ensure_enabled()

    local entries = overview_entries(root)
    if #entries == 0 then
        vim.notify("diffmark: nothing changed against this base")
        return
    end

    local displayer = entry_display.create({
        separator = " ",
        items = {
            { width = 2 },
            { width = 44 },
            { remaining = true },
        },
    })

    local function make(e)
        local display, ordinal
        if e.kind == "file" then
            local icon, icon_hl = "", nil
            if ok_dev then
                icon, icon_hl = devicons.get_icon(vim.fn.fnamemodify(e.rel, ":t"),
                    vim.fn.fnamemodify(e.rel, ":e"), { default = true })
            end
            ordinal = e.rel
            display = function()
                return displayer({
                    { icon or "", icon_hl },
                    { e.rel, e.f.staged and "DiffMarkStaged" or "Directory" },
                    { file_stats(e.f), "Comment" },
                })
            end
        else
            local is_note = e.kind == "note"
            local glyph = is_note and "󰆉" or GLYPH.gh
            local hl = is_note and "DiffMarkNote" or "DiffMarkGh"
            local label = is_note
                and string.format("  %d", e.line)
                or string.format("  %s  @%s", e.outdated and "—" or e.line, e.author)
            local body = e.body:gsub("%s+", " ")
            ordinal = e.rel .. " " .. (e.author or "") .. " " .. body
            display = function()
                return displayer({ { glyph, hl }, { label, hl }, { body, "Comment" } })
            end
        end
        return {
            value = e,
            ordinal = ordinal,
            display = display,
            filename = root .. "/" .. e.rel,
            lnum = e.line,
            col = 0,
        }
    end

    local gh = state.gh[root]
    local title = "diffmark  ·  " .. (MODE_LABEL[state.mode] or state.mode)
    if gh then title = title .. string.format("  ·  %s #%d", GLYPH.gh, gh.pr) end

    pickers.new({
        layout_strategy = "horizontal",
        -- telescope's stock preview_cutoff is 120 columns, which drops the
        -- preview on a split-screen terminal; the preview is the point here
        layout_config = { width = 0.9, height = 0.85, preview_width = 0.55,
            prompt_position = "top", preview_cutoff = 100 },
        sorting_strategy = "ascending",
    }, {
        prompt_title = title,
        results_title = string.format("%d entries", #entries),
        finder = finders.new_table({ results = entries, entry_maker = make }),
        sorter = conf.generic_sorter({}),
        previewer = overview_previewer(root),
    }):find()
end


-- diff_hunk is the slice of the diff the comment is anchored to; it is what
-- makes the preview show the code being talked about, not just the prose
local GH_JQ = ".[] | {path, line, original_line, body, author: .user.login, " ..
    "url: .html_url, diff_hunk, resolved: false}"

-- With no arguments this is "the PR for the branch I am on". Pass a number to
-- pull the comments off any other PR in this repo.
--
-- `opts.quiet` is for the automatic fetch: no panel, and a repo with no PR is
-- the normal case rather than something worth interrupting you about.
function M.gh_sync(number, opts)
    opts = opts or {}
    local root = current_root()
    if not root then
        if not opts.quiet then
            vim.notify("diffmark: not inside a git repository", vim.log.levels.WARN)
        end
        return
    end
    if vim.fn.executable("gh") == 0 then
        if not opts.quiet then
            vim.notify("diffmark: gh CLI not found -- install it to fetch PR comments",
                vim.log.levels.ERROR)
        end
        return
    end

    -- review comments are part of the same overlay as notes and diff marks, so
    -- pulling them switches it on; otherwise refresh() bails on every buffer
    -- you open next and the teal marks silently never appear
    -- claimed before ensure_enabled, because the refresh_all() that fires from
    -- there runs gh_auto again -- and without the guard already set that would
    -- start a second, concurrent fetch of the same PR
    state.gh_fetched[root] = true
    ensure_enabled()
    spin_start("fetching PR comments")

    local function fail(msg, level)
        vim.schedule(function()
            spin_stop()
            if not opts.quiet then vim.notify(msg, level) end
        end)
    end

    local function fetch(pr)
        vim.system({ "gh", "api", "--paginate",
            string.format("repos/{owner}/{repo}/pulls/%d/comments", pr.number),
            "--jq", GH_JQ },
            { cwd = root, text = true },
            function(res)
                if res.code ~= 0 then
                    return fail("diffmark: fetching comments failed\n" .. (res.stderr or ""),
                        vim.log.levels.ERROR)
                end
                vim.schedule(function()
                    spin_stop()
                    local items = {}
                    for _, line in ipairs(vim.split(res.stdout or "", "\n")) do
                        if vim.trim(line) ~= "" then
                            local good, item = pcall(vim.json.decode, line)
                            -- a comment on a line that has since changed comes
                            -- back with line = null; keep it, flagged outdated,
                            -- rather than dropping review feedback on the floor
                            if good and item.path then
                                item.line = item.line ~= vim.NIL and item.line or nil
                                item.body = item.body ~= vim.NIL and item.body or ""
                                item.diff_hunk = item.diff_hunk ~= vim.NIL and item.diff_hunk or nil
                                items[#items + 1] = item
                            end
                        end
                    end
                    state.gh[root] = { pr = pr.number, title = pr.title, items = items }
                    render_gh_all()
                    -- the automatic fetch marks up your buffers and stops there;
                    -- throwing a split open under you at startup is not on
                    if not opts.quiet then panel_open(gh_panel, gh_render, root) end
                    if not opts.quiet or #items > 0 then
                        M.legend(string.format("%d PR comment%s on #%d",
                            #items, #items == 1 and "" or "s", pr.number))
                    end
                end)
            end)
    end

    if number then
        fetch({ number = number, title = "#" .. number })
        return
    end

    vim.system({ "gh", "pr", "view", "--json", "number,title" }, { cwd = root, text = true },
        function(pr_res)
            if pr_res.code ~= 0 then
                return fail("diffmark: no PR for this branch\n" .. (pr_res.stderr or ""),
                    vim.log.levels.WARN)
            end
            local ok, pr = pcall(vim.json.decode, pr_res.stdout)
            if not ok or not pr.number then
                return fail("diffmark: could not read PR number", vim.log.levels.ERROR)
            end
            fetch(pr)
        end)
end

-- Called on every buffer you open. Everything expensive is behind the
-- gh_fetched guard, so this is one `gh` call per repo per session and it never
-- blocks -- by the time the network answers you have been editing for a while.
local function gh_auto(bufnr)
    if not state.gh_enabled then return end
    local root = get_root(bufnr)
    if not root or state.gh_fetched[root] then return end
    M.gh_sync(nil, { quiet = true })
end

local COMMENT_ORDER = { "off", "cursor", "all" }
local COMMENT_LABEL = {
    off = "comment bodies hidden",
    cursor = "comment body under the cursor",
    all = "all comment bodies",
}

function M.set_comments(mode)
    if not COMMENT_LABEL[mode] then
        vim.notify("diffmark: comments must be off / cursor / all", vim.log.levels.ERROR)
        return
    end
    state.show_comments = mode
    for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) then
            state.ghx_key[b] = nil
            render_gh_body(b)
        end
    end
    M.legend(COMMENT_LABEL[mode])
end

function M.cycle_comments()
    local i = 1
    for k, v in ipairs(COMMENT_ORDER) do
        if v == state.show_comments then i = k end
    end
    M.set_comments(COMMENT_ORDER[i % #COMMENT_ORDER + 1])
end

function M.gh_panel()
    if gh_panel.win and api.nvim_win_is_valid(gh_panel.win) then
        panel_close(gh_panel)
        return
    end
    local root = current_root()
    if not root then return end
    panel_open(gh_panel, gh_render, root, true)
end

function M.gh_clear()
    local root = current_root()
    if not root then return end
    state.gh[root] = nil
    state.gh_fetched[root] = nil
    render_gh_all()
    panel_close(gh_panel)
    M.legend("cleared PR comments")
end

-- PR comments are on by default, so hg is the off switch -- and the on switch
-- again, which refetches rather than restoring a stale list.
function M.gh_toggle()
    if state.gh_enabled then
        state.gh_enabled = false
        state.gh, state.gh_fetched = {}, {}
        for _, b in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_valid(b) then api.nvim_buf_clear_namespace(b, ns_gh, 0, -1) end
        end
        state.gh_ids = {}
        panel_close(gh_panel)
        M.legend("PR comments off")
        return
    end
    state.gh_enabled = true
    M.gh_sync()
end

-- ─────────────────────────────
-- refresh scheduling
-- ─────────────────────────────

local function refresh(bufnr, immediate)
    if not state.enabled then return end
    bufnr = bufnr or api.nvim_get_current_buf()
    if not api.nvim_buf_is_valid(bufnr) then return end

    if immediate then
        render_diff(bufnr)
        render_notes(bufnr)
        render_gh(bufnr)
        return
    end

    local timer = state.timers[bufnr]
    if timer then timer:stop() end
    timer = timer or uv.new_timer()
    state.timers[bufnr] = timer
    timer:start(150, 0, vim.schedule_wrap(function()
        render_diff(bufnr)
    end))
end

-- A panel left open beside you is a live view, not a snapshot: staging a hunk
-- or switching base has to be reflected in it, or you end up acting on numbers
-- that stopped being true several keystrokes ago.
local function panels_refresh()
    local root = current_root()
    if not root then return end
    if ov_panel.win and api.nvim_win_is_valid(ov_panel.win) then
        overview_render(ov_panel, root)
    end
    if gh_panel.win and api.nvim_win_is_valid(gh_panel.win) then
        gh_render(gh_panel, root)
    end
end

local function refresh_all()
    for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) then
            render_diff(b)
            render_notes(b)
            render_gh(b)
        end
    end
    -- switching the overlay on does not fire BufEnter for the buffer you are
    -- already sitting in, so this is what catches the very first fetch
    gh_auto(api.nvim_get_current_buf())
    panels_refresh()
end

-- Turning it off must leave no trace in any buffer.
local function clear_all()
    for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) then
            api.nvim_buf_clear_namespace(b, ns_diff, 0, -1)
            api.nvim_buf_clear_namespace(b, ns_del, 0, -1)
            api.nvim_buf_clear_namespace(b, ns_note, 0, -1)
            api.nvim_buf_clear_namespace(b, ns_gh, 0, -1)
        end
    end
    state.hunks, state.index_hunks, state.counts, state.note_ids = {}, {}, {}, {}
    state.deletions, state.del_key = {}, {}
end

-- Anything that needs the diff to exist switches it on rather than doing
-- nothing and looking broken.
function ensure_enabled()
    if state.enabled then return false end
    state.enabled = true
    refresh_all()
    return true
end

-- ─────────────────────────────
-- the legend on the message line
-- ─────────────────────────────

MODE_LABEL = {
    worktree = "uncommitted (vs HEAD)",
    commit = "latest commit (vs HEAD~1)",
    branch = "whole branch (vs main)",
}

-- One single-line echo, never two messages in a row and never wider than the
-- window -- both of those are what turn a status line into a hit-enter prompt.
function M.legend(status)
    local bufnr = api.nvim_get_current_buf()
    local c = state.counts[bufnr] or { changed = 0, staged = 0, viewed = 0 }

    local head = {}
    if status then
        head[#head + 1] = { "diffmark: " .. status, "Title" }
        head[#head + 1] = { "  " }
    else
        head[#head + 1] = { "diffmark ", "Title" }
    end
    head[#head + 1] = { state.enabled and MODE_LABEL[state.mode] or "off", "Special" }
    -- "all" is the norm now, so saying so every time is noise. Only call out the
    -- states that are not what you would assume from looking at the buffer.
    if state.enabled and state.show_deleted == "off" then
        head[#head + 1] = { "  removed code hidden", "DiffMarkDelete" }
    elseif state.enabled and state.show_deleted == "cursor" then
        head[#head + 1] = { "  removed code: cursor only", "DiffMarkDelete" }
    end

    local swatches = {
        { "  " },
        { GLYPH.add .. " added ", "DiffMarkAdd" },
        { GLYPH.change .. " changed ", "DiffMarkChange" },
        { GLYPH.delete .. " removed ", "DiffMarkDelete" },
        -- in branch mode the muted colour also covers work you already
        -- committed on this branch -- both are "not a live edit"
        { GLYPH.add .. (state.mode == "worktree" and " staged " or " staged/committed "), "DiffMarkStaged" },
        { GLYPH.viewed .. " viewed ", "DiffMarkViewed" },
        { "󰆉 note", "DiffMarkNote" },
    }
    local tail = {
        { string.format("  ·  %d changed, %d staged, %d viewed", c.changed, c.staged, c.viewed), "Comment" },
    }

    local function width(list)
        local w = 0
        for _, ch in ipairs(list) do w = w + vim.fn.strdisplaywidth(ch[1]) end
        return w
    end

    -- leave a column spare: filling the last cell also triggers the prompt
    local budget = vim.o.columns - 1
    local chunks = vim.deepcopy(head)
    local used = width(head)
    if used + width(swatches) + width(tail) <= budget then
        vim.list_extend(chunks, swatches)
        vim.list_extend(chunks, tail)
    elseif used + width(swatches) <= budget then
        vim.list_extend(chunks, swatches)
    elseif used + width(tail) <= budget then
        vim.list_extend(chunks, tail)
    end

    api.nvim_echo(chunks, false, {})
end

-- ─────────────────────────────
-- help
-- ─────────────────────────────

-- { key, description } pairs; a bare string is a section heading, false a gap.
local HELP = {
    "diff",
    { "<leader>hh", "on: asks PR / latest commit / uncommitted.  press again: off" },
    { "<leader>hs", "legend + counts on the message line" },
    { "<leader>hr", "reload base rev + index (after commit / rebase / outside staging)" },
    { "]h  [h", "jump to next / previous changed line" },
    { "<leader>hO", "overview: telescope popup of every changed file, note and PR comment" },
    { "", "type to filter across paths, authors and comment text; preview on the right" },
    { "<leader>hD", "hide / show removed code (it is on whenever you open a diff)" },
    { "<leader>hU", "undo the last diffmark action (stage / viewed / note -- not buffer edits)" },
    false,
    "stage",
    { "<leader>hS", "stage the hunk under the cursor (visual: every hunk selected)" },
    { "<leader>hA", "stage the whole file" },
    { "<leader>hu", "unstage the whole file" },
    false,
    "viewed",
    { "<leader>hv", "mark hunk under cursor as viewed (visual: the selection)" },
    { "<leader>hV", "clear viewed marks in this file" },
    { "<leader>hZ", "clear viewed marks in the whole repo" },
    false,
    "notes  ->  " .. NOTES_FILE,
    { "<leader>hc", "add / edit a note on this line (empty input deletes)" },
    { "<leader>hd", "delete the note on this line" },
    { "<leader>hl", "list every note in the repo (quickfix)" },
    { "<leader>ho", "open .comments.txt" },
    { "<leader>hy", "copy: removed code, PR comments or notes (asks if several apply)" },
    { "<leader>hX", "delete all notes" },
    false,
    "github  ->  needs the gh CLI; on by default, fetched in the background",
    { "<leader>hg", "PR comments off / on (on refetches)" },
    { "<leader>hG", "open / close the comments panel on the right" },
    { "", "in the panel: <CR> jumps, y copies the entry, Y copies all, q closes" },
    { "<leader>hC", "comment bodies: off -> under cursor -> all (starts at 'cursor')" },
    { ":DiffMark ghsync", "refetch now, and open the panel" },
    { ":DiffMark commentsoff", "hide every comment body, keep the 󰊤 signs" },
    false,
    "colors",
    { "GREEN", "┃  line added, not staged yet" },
    { "BLUE", "╏  line changed, not staged yet" },
    { "RED", "▁  lines were removed here" },
    { "AMBER", "already in the index: staged, or committed on this branch" },
    { "GREY", "✓  viewed; flips back the moment you edit the line" },
    { "PURPLE", "󰆉  a note is attached to this line" },
    { "TEAL", "󰊤  a PR review comment is attached to this line" },
    false,
    "commands",
    { ":DiffMark", "toggle pick worktree commit branch reload refresh status legend help" },
    { "", "deletions deloff delcursor delall notes stage stagefile unstage" },
    { "", "undo gh ghsync ghpanel ghclear" },
    { "", "comments commentsoff commentscursor commentsall" },
    { "", "viewed clearviewed clearviewedall" },
}

-- the colour rows paint their key cell instead of printing its name
local SWATCH = {
    GREEN = "DiffMarkAddLn",
    BLUE = "DiffMarkChangeLn",
    RED = "DiffMarkDeleteLn",
    AMBER = "DiffMarkStagedLn",
    GREY = "DiffMarkViewedLn",
    PURPLE = "DiffMarkNoteLn",
}

function M.help()
    local key_w = 0
    for _, row in ipairs(HELP) do
        if type(row) == "table" then key_w = math.max(key_w, #row[1]) end
    end

    local lines, marks = {}, {}
    -- marks are { row, start_col, end_col, hl }; end_col must be a real column,
    -- an end_row spanning trick silently drops the highlight
    local function push(text, hl, from, to)
        lines[#lines + 1] = text
        if hl then
            marks[#marks + 1] = { #lines - 1, from or 0, to or #text, hl }
        end
    end

    push("  diffmark -- " .. MODE_LABEL[state.mode], "Title")
    push("")

    for _, row in ipairs(HELP) do
        if row == false then
            push("")
        elseif type(row) == "string" then
            push("  " .. row, "Special")
        else
            local key = row[1]
            local pad = string.rep(" ", key_w - #key)
            local text = string.format("    %s%s   %s", key, pad, row[2])
            push(text, "Comment", 4 + #key + #pad + 3, #text)
            -- the colour rows show the actual highlight in place of a key name
            marks[#marks + 1] = { #lines - 1, 4, 4 + #key, SWATCH[key] or "DiffMarkNote" }
        end
    end
    push("")
    push("  q / <Esc> to close", "Comment")

    local width = 0
    for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
    width = math.min(width + 2, vim.o.columns - 4)
    local height = math.min(#lines, vim.o.lines - 6)

    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local ns_help = api.nvim_create_namespace("diffmark_help")
    for _, m in ipairs(marks) do
        pcall(api.nvim_buf_set_extmark, buf, ns_help, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end

    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"

    local win = api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " diffmark ",
        title_pos = "center",
    })
    vim.wo[win].cursorline = false

    for _, k in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", k, function()
            if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
        end, { buffer = buf, nowait = true })
    end
end

-- ─────────────────────────────
-- staging
-- ─────────────────────────────

-- Which index->buffer hunks touch [first, last] in buffer coordinates.
local function hunks_in_range(bufnr, first, last)
    local out = {}
    for _, h in ipairs(state.index_hunks[bufnr] or {}) do
        local sb, cb = h[3], h[4]
        local lo, hi
        if cb == 0 then
            lo, hi = sb, sb + 1 -- deletion anchor: either side of the gap counts
        else
            lo, hi = sb, sb + cb - 1
        end
        if lo <= last and hi >= first then out[#out + 1] = h end
    end
    return out
end

-- A zero-context unified diff against the index, which `git apply --cached
-- --unidiff-zero` can stage without touching the rest of the file.
local function build_patch(rel, old_lines, new_lines, hunks)
    local out = {
        "diff --git a/" .. rel .. " b/" .. rel,
        "--- a/" .. rel,
        "+++ b/" .. rel,
    }
    for _, h in ipairs(hunks) do
        local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
        out[#out + 1] = string.format("@@ -%d,%d +%d,%d @@", sa, ca, sb, cb)
        for i = sa, sa + ca - 1 do out[#out + 1] = "-" .. (old_lines[i] or "") end
        for i = sb, sb + cb - 1 do out[#out + 1] = "+" .. (new_lines[i] or "") end
    end
    return table.concat(out, "\n") .. "\n"
end

-- Stage the hunk under the cursor, or every hunk the visual selection touches.
-- Staged content comes from the buffer, so what you see marked is what lands in
-- the index even if the file is not written yet.
function M.stage(first, last)
    ensure_enabled()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then
        vim.notify("diffmark: not in a git repo", vim.log.levels.WARN)
        return
    end
    local rel = relpath(root, bufnr)
    if not rel then return end

    if not first then
        first = api.nvim_win_get_cursor(0)[1]
        last = first
    end

    local hunks = hunks_in_range(bufnr, first, last)
    if #hunks == 0 then
        M.legend("nothing unstaged here")
        return
    end

    local snap = index_entry(root, rel)

    -- untracked file: there is no index blob to patch against, just add it
    local tracked = git(root, { "ls-files", "--error-unmatch", "--", rel }) ~= nil
    if not tracked then
        if vim.bo[bufnr].modified then vim.cmd("silent write") end
        if git(root, { "add", "--", rel }) == nil then
            vim.notify("diffmark: git add failed", vim.log.levels.ERROR)
            return
        end
    else
        local patch = build_patch(rel,
            split(index_text(bufnr, root, rel)),
            api.nvim_buf_get_lines(bufnr, 0, -1, false),
            hunks)

        local res = vim.system(
            { "git", "-C", root, "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "-" },
            { stdin = patch, text = true }):wait()
        if res.code ~= 0 then
            vim.notify("diffmark: staging failed\n" .. (res.stderr or ""), vim.log.levels.ERROR)
            return
        end
    end

    push_undo(string.format("stage %d hunk%s in %s", #hunks, #hunks == 1 and "" or "s", rel), function()
        restore_index(root, rel, snap)
        state.index[bufnr] = nil
        render_diff(bufnr)
    end)

    state.index[bufnr] = nil
    render_diff(bufnr)
    panels_refresh()
    M.legend(string.format("staged %d hunk%s", #hunks, #hunks == 1 and "" or "s"))
end

function M.stage_file()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    local rel = relpath(root, bufnr)
    if not rel then return end
    if vim.bo[bufnr].modified then vim.cmd("silent write") end

    local snap = index_entry(root, rel)
    if git(root, { "add", "--", rel }) == nil then
        vim.notify("diffmark: git add failed", vim.log.levels.ERROR)
        return
    end
    push_undo("stage " .. rel, function()
        restore_index(root, rel, snap)
        state.index[bufnr] = nil
        render_diff(bufnr)
    end)
    state.index[bufnr] = nil
    render_diff(bufnr)
    panels_refresh()
    M.legend("staged " .. rel)
end

-- Unstaging is whole-file only: the index can hold content that is nowhere on
-- screen, so there is no honest way to point at "this hunk" of it.
function M.unstage_file()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    local rel = relpath(root, bufnr)
    if not rel then return end

    local snap = index_entry(root, rel)
    if git(root, { "restore", "--staged", "--", rel }) == nil then
        vim.notify("diffmark: unstage failed", vim.log.levels.ERROR)
        return
    end
    push_undo("unstage " .. rel, function()
        restore_index(root, rel, snap)
        state.index[bufnr] = nil
        render_diff(bufnr)
    end)
    state.index[bufnr] = nil
    render_diff(bufnr)
    panels_refresh()
    M.legend("unstaged " .. rel)
end

-- ─────────────────────────────
-- viewed
-- ─────────────────────────────

-- The run of consecutive marked lines the cursor sits in.
local function hunk_at(bufnr, lnum)
    local marked = {}
    for _, l in ipairs(state.hunks[bufnr] or {}) do marked[l] = true end
    if not marked[lnum] then return lnum, lnum end
    local first, last = lnum, lnum
    while marked[first - 1] do first = first - 1 end
    while marked[last + 1] do last = last + 1 end
    return first, last
end

function M.toggle_viewed(first, last)
    ensure_enabled()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    local rel = relpath(root, bufnr)
    if not rel then return end

    if not first then
        first, last = hunk_at(bufnr, api.nvim_win_get_cursor(0)[1])
    end

    local v = load_viewed()
    v[root] = v[root] or {}
    v[root][rel] = v[root][rel] or {}
    local seen = v[root][rel]
    local snap = vim.deepcopy(seen)

    local lines = api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    local hashes = {}
    local all_seen = true
    for _, l in ipairs(lines) do
        local h = line_hash(l)
        hashes[#hashes + 1] = h
        if not seen[h] then all_seen = false end
    end

    for _, h in ipairs(hashes) do
        seen[h] = (not all_seen) and true or nil
    end
    if next(seen) == nil then v[root][rel] = nil end
    if next(v[root]) == nil then v[root] = nil end

    push_undo("viewed marks in " .. rel, function()
        local cur = load_viewed()
        cur[root] = cur[root] or {}
        cur[root][rel] = next(snap) and snap or nil
        if next(cur[root]) == nil then cur[root] = nil end
        save_viewed()
        render_diff(bufnr)
    end)

    save_viewed()
    render_diff(bufnr)
    panels_refresh()
    M.legend(string.format("%d line%s %s viewed",
        #hashes, #hashes == 1 and "" or "s", all_seen and "un-marked" or "marked"))
end

function M.clear_viewed(all_files)
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    local v = load_viewed()

    local snap = vim.deepcopy(v[root])
    local what
    if all_files then
        v[root] = nil
        what = "cleared viewed marks in this repo"
    else
        local rel = relpath(root, bufnr)
        if not rel or not v[root] then return end
        v[root][rel] = nil
        if next(v[root]) == nil then v[root] = nil end
        what = "cleared viewed marks in " .. rel
    end
    push_undo(what, function()
        load_viewed()[root] = snap
        save_viewed()
        refresh_all()
    end)
    save_viewed()
    refresh_all()
    -- after the re-render, so the counts in the echo are the new ones
    M.legend(what)
end

-- ─────────────────────────────
-- public actions
-- ─────────────────────────────

-- One key does the whole job: pick what you are reviewing and it turns on with
-- removed code already visible, instead of hh then hm then hD.
local PICK = {
    { mode = "branch", label = "PR diff        vs main" },
    { mode = "commit", label = "Latest commit  vs HEAD~1" },
    { mode = "worktree", label = "Uncommitted    vs HEAD" },
}

function M.pick()
    if not get_root(api.nvim_get_current_buf()) then
        vim.notify("diffmark: not inside a git repository", vim.log.levels.WARN)
        return
    end
    vim.ui.select(PICK, {
        prompt = "diffmark: what do you want to see?",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end
        -- opening a diff always shows removed code again. Hiding it is a
        -- momentary "get out of my way", not a preference worth remembering
        -- across a restart or the next time you open the diff.
        state.show_deleted = state.deletions_default
        M.set_mode(choice.mode)
    end)
end

-- hh is the only entry point: it asks the question on the press that turns the
-- marks on, and turns them off on the next press. To change what you are
-- diffing against, toggle off and back on -- there is no second mode key.
function M.toggle()
    if state.enabled then
        state.enabled = false
        clear_all()
        M.legend("off")
        return
    end
    state.base, state.index, state.rev = {}, {}, {}
    M.pick()
end

function M.set_mode(mode)
    if not MODE_LABEL[mode] then
        vim.notify("diffmark: mode must be 'worktree', 'commit' or 'branch'", vim.log.levels.ERROR)
        return
    end
    state.mode = mode
    state.base = {} -- base rev changed, drop cached blobs
    state.enabled = true
    refresh_all()
    M.legend()
end

local DEL_LABEL = {
    off = "removed code hidden",
    cursor = "removed code under the cursor",
    all = "all removed code",
}

function M.set_deleted(mode)
    if not DEL_LABEL[mode] then
        vim.notify("diffmark: deletions must be off / cursor / all", vim.log.levels.ERROR)
        return
    end
    ensure_enabled()
    state.show_deleted = mode
    for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) then
            state.del_key[b] = nil
            render_deletions(b)
        end
    end
    M.legend(DEL_LABEL[mode])
end

-- A plain on/off. The old three-way cycle put "cursor" between the two states
-- anyone actually wants, so hiding removed code took one press and getting it
-- back took two -- and the middle stop silently showed you one block's diff
-- when you had asked for the file's.
function M.toggle_deleted()
    if state.show_deleted ~= "off" then
        M.set_deleted("off")
        return
    end
    -- turning them back on has to land somewhere visible: if the configured
    -- default is itself "off", this key would otherwise toggle off to off
    M.set_deleted(state.deletions_default ~= "off" and state.deletions_default or "all")
end

-- kept for :DiffMark deletions, which used to cycle
M.cycle_deleted = M.toggle_deleted

-- Step back through the diffmark actions that touched the index, the viewed
-- store or .comments.txt. Buffer text is not in here -- that is what `u` is for.
function M.undo()
    local entry = table.remove(state.undo)
    if not entry then
        M.legend("nothing to undo")
        return
    end
    local ok, err = pcall(entry.fn)
    if not ok then
        vim.notify("diffmark: undo failed -- " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    M.legend("undid " .. entry.desc)
end

-- Force a re-read of the base revision and the index (use after committing,
-- rebasing, or staging from outside nvim).
function M.reload()
    state.base = {}
    state.index = {}
    state.rev = {}
    state.default_branch = {}
    state.warned_on_base = {}
    state.roots = {}
    state.notes = {}
    state.viewed = nil
    state.enabled = true
    refresh_all()
    M.legend()
end

-- Re-render the current buffer without dropping any caches.
function M.refresh()
    refresh(api.nvim_get_current_buf(), true)
end

-- ]h means "the next hunk", not "the next changed line" -- stepping through a
-- twenty-line block one press at a time is not navigation. A removed block gets
-- a stop of its own too: a pure deletion marks no line in the buffer, so it was
-- previously impossible to reach with ]h at all.
local function nav_stops(bufnr)
    local marked = state.hunks[bufnr] or {}
    local stops, seen = {}, {}
    local function add(l)
        if l >= 1 and not seen[l] then
            seen[l] = true
            stops[#stops + 1] = l
        end
    end
    for i, l in ipairs(marked) do
        if i == 1 or marked[i - 1] ~= l - 1 then add(l) end
    end
    if state.show_deleted ~= "off" then
        for _, b in ipairs(state.deletions[bufnr] or {}) do add(b.row + 1) end
    end
    table.sort(stops)
    return stops
end

function M.next_hunk(backwards)
    ensure_enabled()
    local bufnr = api.nvim_get_current_buf()
    local hunks = nav_stops(bufnr)
    if #hunks == 0 then
        M.legend("nothing changed in this file")
        return
    end
    local cur = api.nvim_win_get_cursor(0)[1]
    local target
    if backwards then
        for i = #hunks, 1, -1 do
            if hunks[i] < cur then
                target = hunks[i]
                break
            end
        end
        target = target or hunks[#hunks]
    else
        for _, l in ipairs(hunks) do
            if l > cur then
                target = l
                break
            end
        end
        target = target or hunks[1]
    end
    api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd("normal! zz")
end

function M.add_note()
    -- notes are part of the same overlay, so jotting one switches it on
    ensure_enabled()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then
        vim.notify("diffmark: not in a git repo", vim.log.levels.WARN)
        return
    end
    local rel = relpath(root, bufnr)
    if not rel then return end

    local lnum = api.nvim_win_get_cursor(0)[1]
    local _, existing = note_at_cursor(bufnr, lnum)

    vim.ui.input({ prompt = "note (empty = delete): ", default = existing or "" }, function(input)
        if input == nil then return end
        -- positions of other notes in this buffer may have drifted; capture
        -- them before rewriting the file
        sync_notes(bufnr)
        local notes = load_notes(root)
        local snap = vim.deepcopy(notes[rel])
        notes[rel] = notes[rel] or {}
        notes[rel][lnum] = nil
        if vim.trim(input) ~= "" then
            notes[rel][lnum] = vim.trim(input)
        end
        if next(notes[rel]) == nil then notes[rel] = nil end
        write_notes(root, { [rel] = true })
        panels_refresh()
        push_undo("note on " .. rel .. ":" .. lnum, function()
            load_notes(root)[rel] = snap
            write_notes(root, { [rel] = true })
            render_notes(bufnr)
        end)
        render_notes(bufnr)
    end)
end

function M.del_note()
    -- notes are part of the same overlay, so jotting one switches it on
    ensure_enabled()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    local rel = relpath(root, bufnr)
    if not rel then return end

    local lnum = api.nvim_win_get_cursor(0)[1]
    sync_notes(bufnr)
    local notes = load_notes(root)
    if not notes[rel] or not notes[rel][lnum] then
        M.legend("no note on this line")
        return
    end
    local snap = vim.deepcopy(notes[rel])
    notes[rel][lnum] = nil
    if next(notes[rel]) == nil then notes[rel] = nil end
    write_notes(root, { [rel] = true })
    push_undo("delete note on " .. rel .. ":" .. lnum, function()
        load_notes(root)[rel] = snap
        write_notes(root, { [rel] = true })
        render_notes(bufnr)
    end)
    render_notes(bufnr)
end

function M.list_notes()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    sync_notes(bufnr)

    local items = {}
    for rel, lines in pairs(load_notes(root)) do
        for lnum, text in pairs(lines) do
            items[#items + 1] = { filename = root .. "/" .. rel, lnum = lnum, text = text }
        end
    end
    if #items == 0 then
        vim.notify("diffmark: no notes")
        return
    end
    table.sort(items, function(a, b)
        if a.filename == b.filename then return a.lnum < b.lnum end
        return a.filename < b.filename
    end)
    vim.fn.setqflist({}, " ", { title = "diffmark notes", items = items })
    vim.cmd("copen")
end

function M.clear_notes()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    if vim.fn.confirm("Delete all notes in " .. NOTES_FILE .. "?", "&Yes\n&No", 2) ~= 1 then return end
    local snap = vim.deepcopy(load_notes(root))
    state.notes[root] = {}
    write_notes(root)
    push_undo("clear all notes", function()
        state.notes[root] = snap
        write_notes(root)
        for _, b in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(b) then render_notes(b) end
        end
    end)
    for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) then render_notes(b) end
    end
end

function M.open_notes()
    local root = get_root(api.nvim_get_current_buf())
    if not root then return end
    sync_notes(api.nvim_get_current_buf())
    vim.cmd("edit " .. vim.fn.fnameescape(notes_path(root)))
end

-- Everything in .comments.txt on the clipboard, ready to paste at an agent.
-- ─────────────────────────────
-- copying things out
-- ─────────────────────────────

-- Removed code is drawn with virt_lines and PR comments with virt_text, and
-- neither is buffer text -- you can read them but `y` cannot touch them. This
-- is the way out.

local function copy_out(text, what)
    if text == "" then
        M.legend("nothing to copy")
        return
    end
    vim.fn.setreg("+", text)
    -- the unnamed register too, so plain `p` works without a clipboard provider
    vim.fn.setreg('"', text)
    local n = #vim.split(text, "\n")
    M.legend(string.format("copied %s (%d line%s)", what, n, n == 1 and "" or "s"))
end

local function del_block_at(bufnr, lnum)
    for _, b in ipairs(state.deletions[bufnr] or {}) do
        if lnum >= b.lo and lnum <= b.hi then return b end
    end
end

-- one block copies as bare code, ready to paste back in; the whole file gets
-- @@ path:line @@ headers so you can still tell where each piece came from
local function deletions_text(rel, blocks, headers)
    local out = {}
    for _, b in ipairs(blocks) do
        if headers then out[#out + 1] = string.format("@@ %s:%d @@", rel, b.row + 1) end
        vim.list_extend(out, b.lines)
        if headers then out[#out + 1] = "" end
    end
    return vim.trim(table.concat(out, "\n"))
end

local function comments_text(items)
    table.sort(items, function(a, b)
        if a.path == b.path then return (a.line or 0) < (b.line or 0) end
        return a.path < b.path
    end)
    local out = {}
    for _, it in ipairs(items) do
        out[#out + 1] = string.format("%s:%s  @%s", it.path, it.line or "outdated", it.author)
        for _, l in ipairs(vim.split((it.body or ""):gsub("\r", ""), "\n")) do
            out[#out + 1] = "    " .. l
        end
        out[#out + 1] = ""
    end
    return vim.trim(table.concat(out, "\n"))
end

function M.yank()
    local bufnr = api.nvim_get_current_buf()
    local root = current_root()
    local rel = root and relpath(root, bufnr)
    local lnum = api.nvim_win_get_cursor(0)[1]
    local choices = {}

    local blocks = state.deletions[bufnr] or {}
    local here = del_block_at(bufnr, lnum)
    if here then
        choices[#choices + 1] = {
            label = string.format("Removed code here  (%d line%s)",
                #here.lines, #here.lines == 1 and "" or "s"),
            fn = function() copy_out(deletions_text(rel, { here }, false), "removed code") end,
        }
    end
    if #blocks > 0 then
        local n = 0
        for _, b in ipairs(blocks) do n = n + #b.lines end
        choices[#choices + 1] = {
            label = string.format("All removed code in this file  (%d line%s)",
                n, n == 1 and "" or "s"),
            fn = function() copy_out(deletions_text(rel, blocks, true), "removed code") end,
        }
    end

    local gh = root and state.gh[root]
    if gh and #gh.items > 0 then
        local at, mine = {}, {}
        for _, it in ipairs(gh.items) do
            if it.path == rel then
                mine[#mine + 1] = it
                if it.line == lnum then at[#at + 1] = it end
            end
        end
        if #at > 0 then
            choices[#choices + 1] = {
                label = "PR comment on this line",
                fn = function() copy_out(comments_text(at), "comment") end,
            }
        end
        if #mine > 0 then
            choices[#choices + 1] = {
                label = string.format("PR comments in this file  (%d)", #mine),
                fn = function() copy_out(comments_text(mine), "comments") end,
            }
        end
        choices[#choices + 1] = {
            label = string.format("All PR comments on #%d  (%d)", gh.pr, #gh.items),
            fn = function() copy_out(comments_text(vim.deepcopy(gh.items)), "comments") end,
        }
    end

    if root and next(load_notes(root)) then
        choices[#choices + 1] = { label = "Notes  (" .. NOTES_FILE .. ")", fn = M.yank_notes }
    end

    if #choices == 0 then
        M.legend("nothing here to copy")
        return
    end
    -- no point asking a question with one answer
    if #choices == 1 then return choices[1].fn() end

    vim.ui.select(choices, {
        prompt = "diffmark: copy what?",
        format_item = function(c) return c.label end,
    }, function(c) if c then c.fn() end end)
end

function M.yank_notes()
    local bufnr = api.nvim_get_current_buf()
    local root = get_root(bufnr)
    if not root then return end
    sync_notes(bufnr)
    local fd = io.open(notes_path(root), "r")
    if not fd then
        vim.notify("diffmark: no notes")
        return
    end
    local content = fd:read("*a")
    fd:close()
    vim.fn.setreg("+", content)
    M.legend("notes copied to clipboard")
end

M.status = M.legend

-- ─────────────────────────────
-- setup
-- ─────────────────────────────

local function visual_range()
    local a = vim.fn.line("v")
    local b = vim.fn.line(".")
    if a > b then a, b = b, a end
    return a, b
end

function M.setup(opts)
    opts = opts or {}
    state.mode = opts.mode or state.mode
    -- opts.enabled = true opts you back in to marks from the moment nvim starts
    if opts.enabled ~= nil then state.enabled = opts.enabled end
    if opts.deletions ~= nil then
        state.deletions_default = opts.deletions
        state.show_deleted = opts.deletions
    end
    -- opts.github = false stops diffmark from ever shelling out to gh
    if opts.github ~= nil then state.gh_enabled = opts.github end
    if opts.comments ~= nil then state.show_comments = opts.comments end

    apply_highlights()
    api.nvim_create_autocmd("ColorScheme", {
        group = api.nvim_create_augroup("diffmark-colors", { clear = true }),
        callback = apply_highlights,
    })

    local group = api.nvim_create_augroup("diffmark", { clear = true })

    api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
        group = group,
        callback = function(e)
            refresh(e.buf, true)
            -- fire-and-forget; guarded to one gh call per repo per session
            if state.enabled then gh_auto(e.buf) end
        end,
    })

    api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
        group = group,
        callback = function(e) refresh(e.buf, false) end,
    })

    -- cursor mode: unfold the block under the cursor as you move through the
    -- file. Cheap -- the blocks are already computed, this only re-renders when
    -- you cross into (or out of) a different one.
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = function(e)
            if not state.enabled then return end
            if api.nvim_win_get_buf(api.nvim_get_current_win()) ~= e.buf then return end
            local lnum = api.nvim_win_get_cursor(0)[1]

            if state.show_deleted == "cursor" then
                local blocks = state.deletions[e.buf]
                if blocks and #blocks > 0 then
                    local key = 0
                    for i, b in ipairs(blocks) do
                        if lnum >= b.lo and lnum <= b.hi then
                            key = i
                            break
                        end
                    end
                    if state.del_key[e.buf] ~= key then
                        state.del_key[e.buf] = key
                        render_deletions(e.buf)
                    end
                end
            end

            -- same trick for comment bodies: the line number the cursor is on
            -- is the whole key, so crossing lines with no comment is free
            if state.show_comments == "cursor" then
                local ids = state.gh_ids[e.buf]
                if ids and not vim.tbl_isempty(ids) then
                    local key = 0
                    for id in pairs(ids) do
                        local pos = api.nvim_buf_get_extmark_by_id(e.buf, ns_gh, id, {})
                        if pos and pos[1] == lnum - 1 then
                            key = lnum
                            break
                        end
                    end
                    if state.ghx_key[e.buf] ~= key then
                        state.ghx_key[e.buf] = key
                        render_gh_body(e.buf)
                    end
                end
            end
        end,
    })

    api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(e)
            sync_notes(e.buf)
            state.index[e.buf] = nil
            refresh(e.buf, true)
        end,
    })

    -- committing / staging / branch switching outside nvim invalidates our view
    api.nvim_create_autocmd("FocusGained", {
        group = group,
        callback = function()
            state.rev = {}
            state.default_branch = {}
            state.base = {}
            state.index = {}
            refresh(api.nvim_get_current_buf(), true)
        end,
    })

    api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        callback = function(e)
            local t = state.timers[e.buf]
            if t then
                t:stop()
                t:close()
            end
            for _, tbl in ipairs({ state.timers, state.roots, state.base, state.index,
                state.hunks, state.index_hunks, state.counts, state.note_ids,
                state.deletions, state.del_key }) do
                tbl[e.buf] = nil
            end
        end,
    })

    api.nvim_create_user_command("DiffMark", function(a)
        local sub = a.args ~= "" and a.args or "status"
        local actions = {
            toggle = M.toggle,
            pick = M.pick,
            undo = M.undo,
            gh = M.gh_toggle,
            yank = M.yank,
            yanknotes = M.yank_notes,
            ghsync = function() M.gh_sync() end,
            overview = M.overview,
            overviewsplit = M.overview_split,
            comments = M.cycle_comments,
            commentsoff = function() M.set_comments("off") end,
            commentscursor = function() M.set_comments("cursor") end,
            commentsall = function() M.set_comments("all") end,
            ghpanel = M.gh_panel,
            ghclear = M.gh_clear,
            worktree = function() M.set_mode("worktree") end,
            commit = function() M.set_mode("commit") end,
            branch = function() M.set_mode("branch") end,
            reload = M.reload,
            deletions = M.cycle_deleted,
            deloff = function() M.set_deleted("off") end,
            delcursor = function() M.set_deleted("cursor") end,
            delall = function() M.set_deleted("all") end,
            refresh = M.refresh,
            help = M.help,
            status = M.legend,
            legend = M.legend,
            notes = M.open_notes,
            stage = function() M.stage() end,
            stagefile = M.stage_file,
            unstage = M.unstage_file,
            viewed = function() M.toggle_viewed() end,
            clearviewed = function() M.clear_viewed(false) end,
            clearviewedall = function() M.clear_viewed(true) end,
        }
        local fn = actions[sub]
        if fn then fn() else vim.notify("diffmark: unknown subcommand " .. sub, vim.log.levels.ERROR) end
    end, {
        nargs = "?",
        complete = function()
            return { "toggle", "pick", "worktree", "commit", "branch", "reload", "refresh", "status", "legend", "help", "notes",
                "deletions", "deloff", "delcursor", "delall",
                "stage", "stagefile", "unstage", "viewed", "clearviewed", "clearviewedall",
                "undo", "gh", "ghsync", "ghpanel", "ghclear",
                "comments", "commentsoff", "commentscursor", "commentsall", "overview", "overviewsplit" }
        end,
    })

    local map = vim.keymap.set
    map("n", "<leader>hh", M.toggle, { desc = "Diff: line marks on (asks what to diff) / off" })
    map("n", "<leader>hr", M.reload, { desc = "Diff: reload base + index" })
    map("n", "<leader>hs", M.legend, { desc = "Diff: legend + counts" })
    map("n", "<leader>h?", M.help, { desc = "Diff: help -- every diffmark mapping" })
    map("n", "]h", function() M.next_hunk(false) end, { desc = "Diff: next changed line" })
    map("n", "[h", function() M.next_hunk(true) end, { desc = "Diff: prev changed line" })
    map("n", "<leader>hD", M.toggle_deleted, { desc = "Diff: hide / show removed code" })

    map("n", "<leader>hS", function() M.stage() end, { desc = "Stage: hunk under cursor" })
    map("x", "<leader>hS", function()
        local a, b = visual_range()
        vim.cmd("normal! \27")
        M.stage(a, b)
    end, { desc = "Stage: hunks in selection" })
    map("n", "<leader>hA", M.stage_file, { desc = "Stage: whole file" })
    map("n", "<leader>hu", M.unstage_file, { desc = "Stage: unstage whole file" })

    map("n", "<leader>hv", function() M.toggle_viewed() end, { desc = "Viewed: toggle hunk under cursor" })
    map("x", "<leader>hv", function()
        local a, b = visual_range()
        vim.cmd("normal! \27")
        M.toggle_viewed(a, b)
    end, { desc = "Viewed: toggle selection" })
    map("n", "<leader>hV", function() M.clear_viewed(false) end, { desc = "Viewed: clear in this file" })
    map("n", "<leader>hZ", function() M.clear_viewed(true) end, { desc = "Viewed: clear in whole repo" })

    map("n", "<leader>hc", M.add_note, { desc = "Note: add/edit on this line" })
    map("n", "<leader>hd", M.del_note, { desc = "Note: delete on this line" })
    map("n", "<leader>hl", M.list_notes, { desc = "Note: list all (quickfix)" })
    map("n", "<leader>ho", M.open_notes, { desc = "Note: open .comments.txt" })
    map("n", "<leader>hy", M.yank, { desc = "Copy: removed code / PR comments / notes" })
    map("n", "<leader>hX", M.clear_notes, { desc = "Note: clear all" })

    map("n", "<leader>hg", M.gh_toggle, { desc = "GitHub: PR comments on / off" })
    map("n", "<leader>hG", M.gh_panel, { desc = "GitHub: toggle the comments panel" })
    map("n", "<leader>hC", M.cycle_comments, { desc = "GitHub: cycle comment bodies off/cursor/all" })
    map("n", "<leader>hO", M.overview, { desc = "Diff: overview of every changed file" })

    map("n", "<leader>hU", M.undo, { desc = "Diff: undo the last diffmark action" })

    if state.enabled then refresh(api.nvim_get_current_buf(), true) end
end

return M
