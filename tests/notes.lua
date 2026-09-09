-- Run from the plugin root: nvim --headless -u NONE -l tests/notes.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local M = require("redline")
local api = vim.api
local function upvalue(fn, name, replacement)
    for i = 1, 100 do
        local key, value = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then
            if replacement ~= nil then debug.setupvalue(fn, i, replacement) end
            return value
        end
    end
    error("missing upvalue: " .. name)
end
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = (vim.uv or vim.loop).fs_realpath(root)
local function eq(expected, actual)
    assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local function run()
    api.nvim_set_hl(0, "RedlineNote", { fg = "#ffffff" })
    api.nvim_set_hl(0, "RedlineNoteLn", { bg = "#333333" })
    -- Isolate note logic from git, panels, autocmds, and the user's config.
    upvalue(M.add_note, "ensure_enabled", function() end)
    upvalue(M.add_note, "get_root", function() return root end)
    upvalue(M.add_note, "panels_refresh", function() end)
    local base = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n"
    upvalue(M.add_note, "base_text", function() return base end)
    M.legend = function() end
    local render = upvalue(M.add_note, "render_notes")
    local sync = upvalue(M.add_note, "sync_notes")
    local load = upvalue(M.add_note, "load_notes")
    local lookup = upvalue(M.add_note, "note_at_cursor")
    local state = upvalue(load, "state")
    local buf = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(buf)
    api.nvim_buf_set_name(buf, root .. "/sample.txt")
    local function reset(lines, disk)
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.fn.writefile(disk or {}, root .. "/.comments.txt")
        state.notes[root] = nil
        render(buf)
    end
    local original = vim.split(base:sub(1, -2), "\n")
    local function contents() return table.concat(vim.fn.readfile(root .. "/.comments.txt"), "\n") end
    local function has(text) assert(contents():find(text, 1, true), contents()) end
    local function input(text, default)
        vim.ui.input = function(opts, cb)
            if default then eq(default, opts.default) end
            cb(text)
        end
    end

    reset(original, { "sample.txt:2: legacy", "sample.txt:4-6: range", "sample.txt:0: invalid",
        "sample.txt:7-3: invalid", "other.txt:2-9: other" })
    eq("legacy", load(root)["sample.txt"][2])
    eq("range", select(2, lookup(buf, 5)))
    eq(nil, lookup(buf, 7))
    api.nvim_win_set_cursor(0, { 5, 0 })
    input("edited", "range")
    M.add_note()
    has("sample.txt:4-6: edited")
    has("sample.txt:2: legacy")
    has("other.txt:2-9: other")
    M.del_note()
    eq(nil, lookup(buf, 5))
    M.undo()
    eq("edited", select(2, lookup(buf, 5)))

    api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
    api.nvim_buf_set_lines(buf, 5, 5, false, { "inside" })
    sync(buf)
    has("sample.txt:5-8: edited")
    render(buf)
    eq("edited", select(2, lookup(buf, 8)))
    eq(nil, lookup(buf, 9))
    vim.fn.writefile({ "remote.txt:3-7: external" }, root .. "/.comments.txt", "a")
    sync(buf)
    has("remote.txt:3-7: external")
    api.nvim_buf_set_lines(buf, 4, 8, false, {})
    sync(buf)
    has("sample.txt:5: edited")

    reset(original)
    input("visual")
    M.add_note(6, 3)
    has("sample.txt:3-6: visual")
    input("resized", "visual")
    M.add_note(3, 7)
    has("sample.txt:3-7: resized")
    M.undo()
    has("sample.txt:3-6: visual")
    input("nested")
    M.add_note(4, 4)
    eq("nested", select(2, lookup(buf, 4)))
    eq("visual", select(2, lookup(buf, 5)))
    api.nvim_win_set_cursor(0, { 5, 0 })
    input("", "visual")
    M.add_note()
    eq(nil, lookup(buf, 5))
    eq("nested", select(2, lookup(buf, 4)))

    reset({ "one", "TWO", "THREE", "four", "five", "SIX", "seven", "eight" })
    api.nvim_win_set_cursor(0, { 3, 0 })
    input("hunk")
    M.add_note()
    has("sample.txt:2-3: hunk")
    api.nvim_win_set_cursor(0, { 5, 0 })
    input("line")
    M.add_note()
    has("sample.txt:5: line")
    input(nil)
    local before = contents()
    M.add_note(1, 8)
    eq(before, contents())
    M.add_note("invalid", 2)
    eq(before, contents())

    local preview = upvalue(upvalue(M.overview, "overview_previewer"), "preview_comment")
    vim.fn.writefile(original, root .. "/sample.txt")
    local lines, highlights = preview({ kind = "note", rel = "sample.txt", line = 2,
        end_line = 7, body = "preview range" }, root, 80)
    assert(lines[1]:find("sample.txt:2-7", 1, true))
    local highlighted = 0
    for _, hl in pairs(highlights) do
        if hl == "RedlineChangeLn" then highlighted = highlighted + 1 end
    end
    eq(6, highlighted)

    local setreg = vim.fn.setreg
    local copied
    vim.fn.setreg = function(reg, text) if reg == "+" then copied = text end end
    M.yank_notes()
    vim.fn.setreg = setreg
    assert(copied:find("sample.txt:2-3: hunk", 1, true))
    M.list_notes()
    local items = vim.fn.getqflist()
    eq(2, items[1].lnum)
    eq(3, items[1].end_lnum)
    vim.cmd("cclose")

    reset({ "one", "four", "five", "six", "seven", "eight" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    input("deleted hunk")
    M.add_note()
    has("sample.txt:1: deleted hunk")
    reset(original)
    input("to EOF")
    M.add_note(6, 8)
    api.nvim_buf_set_lines(buf, 8, 8, false, { "outside" })
    sync(buf)
    has("sample.txt:6-8: to EOF")
    eq(nil, lookup(buf, 9))
    local confirm = vim.fn.confirm
    vim.fn.confirm = function() return 1 end
    M.clear_notes()
    eq(nil, (vim.uv or vim.loop).fs_stat(root .. "/.comments.txt"))
    M.undo()
    has("sample.txt:6-8: to EOF")
    vim.fn.confirm = confirm
    print("notes: all tests passed")
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
vim.cmd("qa!")
