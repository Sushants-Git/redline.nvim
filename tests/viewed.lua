-- Run from the plugin root: nvim --headless -u NONE -l tests/viewed.lua
local api = vim.api
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. "/repo", "p")
vim.env.XDG_DATA_HOME = temp .. "/data"
vim.env.XDG_STATE_HOME = temp .. "/state"
vim.env.XDG_CACHE_HOME = temp .. "/cache"
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = (vim.uv or vim.loop).fs_realpath(temp .. "/repo")
local function eq(want, got, label)
    assert(vim.deep_equal(want, got), label .. ": expected " .. vim.inspect(want) .. ", got " .. vim.inspect(got))
end
local function git(...)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, { ... })
    local result = vim.system(cmd, { text = true }):wait()
    assert(result.code == 0, result.stderr)
end
local function up(fn, name, visited)
    visited = visited or {}
    if visited[fn] then return end
    visited[fn] = true
    for i = 1, 100 do
        local n, v = debug.getupvalue(fn, i)
        if not n then break end
        if n == name then return v end
        if type(v) == "function" then
            local found = up(v, name, visited)
            if found ~= nil then return found end
        end
    end
end
local function run()
    git("init", "-q")
    vim.fn.writefile({ "anchor", "tail" }, root .. "/file")
    vim.fn.writefile({}, root .. "/empty", "b")
    vim.fn.writefile({ "" }, root .. "/blank")
    vim.fn.writefile({ "no newline" }, root .. "/noeol", "b")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
    local M = require("redline")
    local H = require("redline.viewed")
    local state = assert(up(M.toggle_viewed, "state"))
    local render = assert(up(M.toggle_viewed, "render_diff"))
    local overview = assert(up(M.overview, "overview_data"))
    state.enabled, state.gh_enabled = true, false
    M.legend = function() end
    local function edit(name)
        vim.cmd("edit! " .. vim.fn.fnameescape(root .. "/" .. name))
        return api.nvim_get_current_buf()
    end
    for name, expected in pairs({ empty = "", blank = "\n", noeol = "no newline" }) do
        local b = edit(name)
        eq(expected, H.buffer_text(b), name .. " serialization")
        render(b)
        eq(0, state.counts[b].changed, name .. " unchanged diff")
    end
    local eofbuf = edit("noeol")
    vim.bo[eofbuf].endofline = true
    render(eofbuf)
    eq(1, state.counts[eofbuf].changed, "real final newline change detected")
    local emptybuf = edit("empty")
    api.nvim_buf_set_lines(emptybuf, 0, -1, false, { "" })
    eq("\n", H.buffer_text(emptybuf), "explicit blank line is not an empty file")
    render(emptybuf)
    eq(1, state.counts[emptybuf].changed, "empty to blank diff detected")
    local b = edit("file")
    M.toggle_viewed(1, 2)
    eq(nil, state.viewed[root], "unchanged selection rejected")
    api.nvim_buf_set_lines(b, 1, 1, false, { "same", "", "same", "" })
    render(b)
    M.toggle_viewed(2, 3)
    eq(2, state.counts[b].viewed, "duplicate text and blanks independent")
    M.toggle_viewed(2, 2)
    eq(1, state.counts[b].viewed, "single duplicate unmarked")
    M.toggle_viewed(2, 2)
    api.nvim_buf_set_lines(b, 0, 0, false, { "prefix" })
    render(b)
    eq(2, state.counts[b].viewed, "positions follow insertion")
    api.nvim_buf_set_lines(b, 2, 3, false, { "edited" })
    render(b)
    eq(1, state.counts[b].viewed, "fingerprint invalidates edit")
    api.nvim_buf_set_lines(b, 3, 4, false, {})
    render(b)
    eq(0, state.counts[b].viewed, "deleted blank does not transfer to duplicate")
    M.clear_viewed(false)
    eq(nil, state.viewed[root], "clear file")
    state.undo[#state.undo].fn()
    assert(state.viewed[root].file, "clear undo restores records")
    render(b)
    eq(0, state.counts[b].viewed, "clear undo does not validate stale records")
    M.clear_viewed(false)

    -- Changed old content must not inherit a deletion's viewed anchor.
    api.nvim_buf_set_lines(b, 0, -1, false, { "anchor" })
    render(b)
    M.toggle_viewed(1, 1)
    eq(1, state.counts[b].viewed, "deletion reviewed")
    state.base[b].text = "anchor\nother removed text\n"
    render(b)
    eq(0, state.counts[b].viewed, "deletion content identity")
    state.base[b] = nil
    M.clear_viewed(true)

    api.nvim_buf_set_lines(b, 0, -1, false, { "anchor", "new", "tail" })
    render(b)
    M.toggle_viewed(2, 2)
    local store = vim.fn.stdpath("data") .. "/redline-viewed.json"
    local persisted = table.concat(vim.fn.readfile(store), "\n")
    local records = H.decode(persisted)[root].file
    local candidates = assert(up(M.toggle_viewed, "viewed_candidates"))[b]
    local clone = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(clone, 0, -1, false, { "anchor", "new", "tail" })
    eq(1, vim.tbl_count(H.match(clone, records, candidates, vim.fn.sha256(H.buffer_text(clone)))),
        "persisted exact snapshot restored")
    local changed = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(changed, 0, -1, false, { "elsewhere", "new", "tail" })
    eq(0, vim.tbl_count(H.match(changed, records, candidates, vim.fn.sha256(H.buffer_text(changed)))),
        "persisted changed snapshot rejected")
    eq({}, H.decode(vim.json.encode({ [root] = { file = { [vim.fn.sha256("new"):sub(1, 16)] = true } } })),
        "legacy hashes not guessed")
    eq({}, H.decode("not json"), "corrupt store")
    eq({}, H.decode('{"version":2,"roots":{"bad":{"file":true}}}'), "malformed records")

    -- Disk is unchanged, but an unsaved reviewed diff should still be listed.
    local files = overview(root)
    eq(1, files.file.viewed, "overview counts active unsaved diff")
    api.nvim_buf_set_lines(b, 0, -1, false, { "anchor", "tail" })
    render(b)
    files = overview(root)
    eq(nil, files.file, "history-only unchanged file omitted")

    api.nvim_buf_set_lines(b, 0, -1, false, { "anchor", "disk addition", "tail" })
    M.toggle_viewed(2, 2)
    vim.fn.writefile({ "anchor", "disk addition", "tail" }, root .. "/file")
    api.nvim_buf_delete(b, { force = true })
    files = overview(root)
    eq(1, files.file.viewed, "unloaded file validates persisted snapshot")
    vim.fn.writefile({ "anchor", "different disk addition", "tail" }, root .. "/file")
    files = overview(root)
    eq(0, files.file.viewed, "unloaded edited file rejects stale history")

    -- Exercise the real save hook, after renders have already moved the record.
    M.setup({ enabled = true, github = false, keymaps = false })
    b = edit("file")
    M.clear_viewed(true)
    api.nvim_buf_set_lines(b, 0, -1, false, { "anchor", "new", "tail" })
    M.toggle_viewed(2, 2)
    local before = vim.fn.readfile(store)
    local open, writes = io.open, 0
    io.open = function(path, mode)
        if mode == "w" and path:sub(1, #store + 1) == store .. "." then writes = writes + 1 end
        return open(path, mode)
    end
    api.nvim_buf_set_lines(b, 0, 0, false, { "prefix" })
    render(b)
    render(b)
    eq(1, state.counts[b].viewed, "moved record remains viewed")
    eq(before, vim.fn.readfile(store), "render does not persist unsaved positions")
    eq(0, writes, "renders do not write viewed state")
    vim.cmd("silent write")
    eq(1, writes, "buffer write persists validated viewed state once")
    render(b)
    eq(1, writes, "post-save render does not write viewed state")
    io.open = open
    records = H.decode(table.concat(vim.fn.readfile(store), "\n"))[root].file
    local record = select(2, next(records))
    eq(3, record.line, "saved position follows insertion")
    eq(vim.fn.sha256(H.buffer_text(b)), record.snapshot, "saved snapshot follows insertion")
    clone = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(clone, 0, -1, false, api.nvim_buf_get_lines(b, 0, -1, false))
    eq(1, vim.tbl_count(H.match(clone, records, up(M.toggle_viewed, "viewed_candidates")[b],
        vim.fn.sha256(H.buffer_text(clone)))), "saved moved record restores in a fresh buffer")
    render(b)

    api.nvim_buf_delete(b, { unload = true })
    assert(api.nvim_buf_is_valid(b) and not api.nvim_buf_is_loaded(b), "unload retains buffer number")
    vim.fn.bufload(b)
    render(b)
    eq(1, state.counts[b].viewed, "unchanged unloaded buffer rebinds viewed mark")
    api.nvim_buf_delete(b, { unload = true })
    vim.fn.writefile({ "different prefix", "anchor", "new", "tail" }, root .. "/file")
    vim.fn.bufload(b)
    render(b)
    eq(0, state.counts[b].viewed, "missing extmark still requires an exact snapshot")

    -- Replacing identical text invalidates the occurrence, unlike unloading.
    api.nvim_set_current_buf(b)
    M.clear_viewed(true)
    M.toggle_viewed(3, 3)
    api.nvim_buf_set_lines(b, 2, 3, false, { "new" })
    render(b)
    eq(0, state.counts[b].viewed, "invalidated extmark is not rebound from identical text")
    print("viewed: all tests passed")
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(temp, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
vim.cmd("qa!")
