-- nvim --headless -u NONE -l /Users/sushantmishra/redline.nvim/tests/ai.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))
local api, M = vim.api, require("redline")
local W = require("redline.workflow")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = (vim.uv or vim.loop).fs_realpath(root)
local function git(...)
    local r = vim.system(vim.list_extend({ "git", "-C", root }, { ... }), { text = true }):wait()
    assert(r.code == 0, r.stderr)
    return vim.trim(r.stdout)
end
local function up(fn, name)
    for i = 1, 100 do
        local key, value = debug.getupvalue(fn, i)
        if key == name then return value end
        if not key then break end
    end
    error("missing upvalue " .. name)
end
local text, notices
vim.notify = function(s) notices = s end
vim.fn.setreg = function(reg, s)
    if reg == "+" then error("no clipboard") end
    text = s
end
vim.ui.input = function() error("unexpected input") end
vim.ui.select = function() error("unexpected confirmation") end
local function has(s) assert(text:find(s, 1, true), s .. " missing from " .. text) end
local function lacks(s) assert(not text:find(s, 1, true), s .. " leaked into " .. text) end
local ok, err = xpcall(function()
    git("init", "-q")
    local original = { "one", "old two", "old three", "four", "five", "six", "seven", "old eight" }
    vim.fn.writefile(original, root .. "/file.txt")
    vim.fn.writefile({ "OTHER FILE SECRET" }, root .. "/other.txt")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base")
    local head = git("rev-parse", "HEAD")
    vim.cmd.edit(vim.fn.fnameescape(root .. "/file.txt"))
    local buf = api.nvim_get_current_buf()
    local state = up(M.review_context, "state")
    state.mode = "worktree"
    vim.fn.writefile({ "file.txt:2: MATCH NOTE", "file.txt:4-6: RANGE NOTE",
        "file.txt:7: UNRELATED NOTE", "other.txt:2: OTHER NOTE" }, root .. "/.comments.txt")
    api.nvim_set_hl(0, "RedlineNote", {})
    api.nvim_set_hl(0, "RedlineNoteLn", {})
    up(M.add_note, "render_notes")(buf)
    local function note_bytes() return table.concat(vim.fn.readfile(root .. "/.comments.txt", "b"), "\n") end
    local saved_bytes = note_bytes()
    local cached_notes = vim.deepcopy(state.notes[root])
    state.gh[root] = { items = {
        { path = "file.txt", line = 4, body = "MATCH PR", author = "reviewer", side = "RIGHT", commit_id = head },
        { path = "file.txt", line = 7, body = "UNRELATED PR", side = "RIGHT", commit_id = head },
        { path = "file.txt", start_line = 4, line = 6, body = "RANGE PR", side = "RIGHT",
            start_side = "RIGHT", commit_id = head },
        { path = "file.txt", body = "OUTDATED PR" },
        { path = "file.txt", line = 2, body = "LEFT PR", side = "LEFT", commit_id = head },
        { path = "other.txt", line = 2, body = "OTHER PR" },
    } }
    api.nvim_buf_set_text(buf, 1, 0, 1, #original[2], { "live two" })
    api.nvim_buf_set_text(buf, 2, 0, 2, #original[3], { "UNSELECTED NEW THREE" })
    api.nvim_buf_set_lines(buf, 7, 8, false, { "DISTANT CHANGE" })
    W.copy_for_ai(nil, buf, 2, 2)
    has("Please address these review comments")
    has("Lines 2-2: file.txt"); has("live two"); has("-old two"); has("MATCH NOTE")
    lacks("UNSELECTED NEW THREE"); lacks("old three"); lacks("DISTANT CHANGE")
    lacks("UNRELATED NOTE"); lacks("OTHER NOTE"); lacks("OTHER FILE SECRET")
    lacks("RANGE NOTE"); lacks("RANGE PR")
    lacks("OUTDATED PR"); lacks("LEFT PR"); lacks("OTHER PR"); lacks("MATCH PR")
    has("cannot map to selected lines")
    assert(notices:find("Check for secrets", 1, true))
    -- Extmark anchors and PR commit positions both follow unsaved insertions.
    api.nvim_buf_set_lines(buf, 0, 0, false, { "unsaved insertion" })
    W.copy_for_ai(nil, buf, 3, 5)
    has("MATCH NOTE"); has("MATCH PR"); has("Lines 5-5")
    has("RANGE NOTE"); has("RANGE PR")
    has("Lines 3-3: MATCH NOTE"); has("Lines 5-7: RANGE NOTE")
    assert(note_bytes() == saved_bytes, "copy persisted unsaved note positions")
    assert(vim.deep_equal(state.notes[root], cached_notes), "copy mutated cached notes")
    lacks("UNRELATED NOTE"); lacks("UNRELATED PR"); lacks("DISTANT CHANGE")
    W.copy_for_ai(nil, buf)
    has("Whole file: file.txt"); has("DISTANT CHANGE"); has("UNRELATED NOTE")
    has("OUTDATED PR"); has("Outdated; current position unavailable")
    lacks("OTHER PR"); lacks("OTHER NOTE"); lacks("OTHER FILE SECRET")
    -- Another editor updates this same file's notes while live anchors still
    -- refer to the earlier bodies. Copy must neither overwrite nor revive them.
    vim.fn.writefile({ "# preserve this header and missing final newline", "",
        "file.txt:2: EXTERNAL REPLACEMENT", "file.txt:3: EXTERNAL NEW",
        "file.txt:4-6: RANGE NOTE", "other.txt:2: OTHER NOTE" }, root .. "/.comments.txt", "b")
    local external_bytes = note_bytes()
    W.copy_for_ai(nil, buf)
    has("EXTERNAL REPLACEMENT"); has("EXTERNAL NEW")
    has("saved position; cannot map to unsaved buffer")
    has("Lines 5-7: RANGE NOTE")
    lacks("MATCH NOTE"); lacks("UNRELATED NOTE"); lacks("OTHER NOTE")
    assert(note_bytes() == external_bytes, "copy overwrote external same-file edits")
    W.copy_for_ai(nil, buf, 3, 5)
    has("Lines 5-7: RANGE NOTE")
    has("2 same-file saved note(s) omitted")
    lacks("EXTERNAL REPLACEMENT"); lacks("EXTERNAL NEW"); lacks("MATCH NOTE")
    assert(note_bytes() == external_bytes, "selection copy changed saved bytes")
    assert(vim.deep_equal(state.notes[root], cached_notes), "copy refreshed note cache behind live anchors")
    -- A fresh base is read even if the overlay has cached an earlier HEAD.
    api.nvim_buf_set_lines(buf, 0, -1, false, original)
    W.copy_for_ai(nil, buf)
    has("No changes in this scope"); lacks("old eight")
    vim.fn.writefile({ "new base" }, root .. "/file.txt")
    git("add", "file.txt")
    git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "next")
    W.copy_for_ai(nil, buf)
    has("-new base")
    -- An absent, unmodified tracked file is a deletion, not a stale live copy.
    vim.bo[buf].modified = false
    vim.fn.delete(root .. "/file.txt")
    W.copy_for_ai(nil, buf)
    has("-new base"); lacks("+one")
    W.copy_for_ai(nil, buf, 2, 2)
    has("2: old two"); lacks("old eight")
    -- Unsaved new files are supported without adding other untracked files.
    local new = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(new, root .. "/new.txt")
    api.nvim_buf_set_lines(new, 0, -1, false, { "new first", "new second" })
    W.copy_for_ai(nil, new, 2, 2)
    has("+new second"); lacks("new first"); lacks("MATCH NOTE")
    api.nvim_buf_set_lines(new, 0, -1, false, { "" })
    vim.bo[new].endofline = false
    W.copy_for_ai(nil, new)
    has("No changes in this scope")
    git("checkout", "--orphan", "unborn")
    api.nvim_buf_set_lines(new, 0, -1, false, { "unborn content" })
    W.copy_for_ai(nil, new)
    has("+unborn content"); lacks("OTHER FILE SECRET")
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then error(err) end
print("ai: ok")
