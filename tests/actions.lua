-- nvim --headless -u NONE -l tests/actions.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = (vim.uv or vim.loop).fs_realpath(root)
local file = root .. "/file.txt"
vim.fn.writefile({ "one", "two", "three", "four" }, file)
vim.cmd.edit(vim.fn.fnameescape(file))
local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
local c = { root = root, github = true }
local calls, notices, registers = {}, {}, {}
vim.notify = function(text) notices[#notices + 1] = text end
vim.fn.setreg = function(reg, text, kind) registers[reg] = { text, kind } end
vim.ui.select = function() error("unexpected selection/confirmation") end
vim.ui.input = function() error("unexpected input") end
local r = { workflow_context = function() return c end }
local function record(name)
    return function(...)
        assert(api.nvim_get_current_buf() == buf and api.nvim_get_current_win() == win, "origin not restored")
        assert(api.nvim_win_get_cursor(win)[1] == 3, "cursor not restored")
        calls[#calls + 1] = { name, ... }
    end
end
for _, name in ipairs({ "stage", "stage_file", "unstage", "unstage_file", "add_note", "toggle_viewed",
    "select_hunk", "overview", "open_notes", "undo" }) do r[name] = record(name) end
package.loaded.redline = r
local w = require("redline.workflow")
for _, name in ipairs({ "diff", "handoff", "commit", "push", "pr" }) do w[name] = record(name) end
local opts, maps, selected, enter, closed
package.loaded["telescope.pickers"] = { new = function(_, options)
    opts = options
    return { find = function()
        maps, closed = {}, false
        options.attach_mappings(123, function(mode, key, fn) maps[mode .. key] = fn end)
    end }
end }
package.loaded["telescope.finders"] = { new_table = function(options) return options end }
package.loaded["telescope.config"] = { values = { generic_sorter = function() return {} end } }
package.loaded["telescope.actions"] = {
    close = function(prompt) assert(prompt == 123); closed = true end,
    select_default = { replace = function(_, fn) enter = fn end },
}
package.loaded["telescope.actions.state"] = { get_selected_entry = function() return selected end }
local function open(first, last)
    api.nvim_set_current_win(win)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(win, { 3, 0 })
    w.actions(first, last)
end
local function press(key)
    maps[key]()
    vim.wait(20, function() return false end)
end
local function equal(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local ok, err = xpcall(function()
    open(2, 3)
    assert(opts.initial_mode == "normal" and opts.previewer == false)
    assert(opts.prompt_title:find("selected lines 2-3: file.txt", 1, true))
    assert(opts.results_title:find("/: search", 1, true))
    local keys = {}
    for _, item in ipairs(opts.finder.results) do
        assert(#item.key == 1 and not keys[item.key], "nonunique shortcut")
        keys[item.key] = true
        local entry = opts.finder.entry_maker(item)
        assert(entry.display:sub(1, 3) == "[" .. item.key .. "]")
        assert(entry.ordinal == item.label and entry.value == item)
        assert(maps["n" .. item.key] and not maps["i" .. item.key])
    end
    equal(vim.tbl_count(keys), 14)
    for key, name in pairs({ s = "stage", u = "unstage", c = "add_note", v = "toggle_viewed" }) do
        open(3, 2)
        vim.cmd.vsplit()
        press("n" .. key)
        assert(closed)
        equal(calls[#calls], { name, 2, 3 })
        local extra = api.nvim_list_wins()[1]
        for _, id in ipairs(api.nvim_list_wins()) do if id ~= win then extra = id end end
        api.nvim_win_close(extra, true)
    end
    for key, expected in pairs({ s = { "stage_file" }, u = { "unstage_file" },
        c = { "add_note", 1, 4 }, v = { "toggle_viewed", 1, 4 }, h = { "select_hunk" },
        f = { "overview", root }, n = { "open_notes", root }, z = { "undo" }, d = { "diff", c },
        a = { "handoff", c }, C = { "commit", c }, P = { "push", c }, p = { "pr", c } }) do
        open()
        assert(opts.prompt_title == "Redline | file: file.txt")
        press("n" .. key)
        equal(calls[#calls], expected)
    end
    open(2, 3)
    press("ny")
    equal(registers['"'], { { "two", "three" }, "V" })
    equal(registers['+'], registers['"'])
    open()
    press("ny")
    equal(registers['"'], { { "one", "two", "three", "four" }, "V" })
    for _, key in ipairs({ "n<CR>", "i<CR>", "default" }) do
        open(2, 3)
        selected = opts.finder.entry_maker(opts.finder.results[2])
        if key == "default" then enter(); vim.wait(20) else press(key) end
        equal(calls[#calls], { "unstage", 2, 3 })
    end
    local count = #calls
    for _, key in ipairs({ "nq", "n<Esc>", "i<Esc>" }) do
        open(); press(key); assert(closed and #calls == count)
    end
    open(); selected = nil; enter(); assert(not closed)
    local startinsert = vim.cmd.startinsert
    local searching = false
    vim.cmd.startinsert = function() searching = true end
    press("n/"); assert(searching and not closed and #calls == count)
    vim.cmd.startinsert = startinsert

    open(2, 3)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "edited" })
    press("ns"); assert(#calls == count and notices[#notices]:find("buffer changed", 1, true))
    open(); api.nvim_buf_set_name(buf, root .. "/renamed.txt")
    press("nf"); assert(#calls == count)
    api.nvim_buf_set_name(buf, file)
    open(); api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
    press("nz"); assert(#calls == count)
    open(); vim.fn.delete(file)
    press("nu"); assert(#calls == count and notices[#notices]:find("no longer exists", 1, true))
    vim.fn.writefile({ "one" }, file)
    open(); vim.cmd.vsplit(); api.nvim_win_close(win, true)
    press("na"); assert(#calls == count)
    win = api.nvim_get_current_win()
    open(); api.nvim_buf_delete(buf, { force = true })
    press("ns"); assert(#calls == count)
    vim.cmd.edit(vim.fn.fnameescape(file))
    buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    c.github = false
    open()
    assert(#opts.finder.results == 13 and not maps.np)
    c.github = true
    vim.bo[buf].buftype = "nofile"
    open()
    assert(#opts.finder.results == 8 and not maps.ns and not maps.ny)
    assert(opts.prompt_title == "Redline | repo: " .. root)
    vim.bo[buf].buftype = ""

    -- Missing Telescope uses the identical registry and scope, without another prompt.
    package.loaded["telescope.pickers"] = nil
    package.preload["telescope.pickers"] = function() error("not installed") end
    local fallback_calls = 0
    vim.ui.select = function(items, options, callback)
        fallback_calls = fallback_calls + 1
        assert(#items == 14 and options.prompt:find("selected lines 2-3", 1, true))
        assert(options.format_item(items[1]) == "[s] Stage selected lines 2-3")
        callback(items[1])
    end
    open(2, 3)
    equal(calls[#calls], { "stage", 2, 3 })
    assert(fallback_calls == 1)
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then error(err) end
print("actions: ok")
