-- Run from the plugin root: nvim --headless -u NONE -l tests/unstaging.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api, M = vim.api, require("redline")
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
root = vim.uv.fs_realpath(root)
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_INDEX_FILE = root .. "/.git/index"
vim.env.GIT_DIR = root .. "/.git"
vim.env.GIT_WORK_TREE = root
vim.env.GIT_AUTHOR_NAME, vim.env.GIT_COMMITTER_NAME = "Test", "Test"
vim.env.GIT_AUTHOR_EMAIL, vim.env.GIT_COMMITTER_EMAIL = "test@example.com", "test@example.com"
local function git(args, stdin)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { stdin = stdin }):wait()
    assert(res.code == 0, res.stderr)
    return res.stdout
end
local function eq(want, got)
    assert(want == got, vim.inspect({ expected = want, actual = got }))
end
local messages = {}
local function run()
    git({ "init", "-q" })
    upvalue(M.stage, "ensure_enabled", function() end)
    upvalue(M.stage, "get_root", function() return root end)
    upvalue(M.stage, "render_diff", function() end)
    upvalue(M.stage, "panels_refresh", function() end)
    M.legend = function(msg) messages[#messages + 1] = msg end
    vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then error(msg) end
        messages[#messages + 1] = msg
    end
    local state = upvalue(M.stage, "state")
    local serial = 0
    local function entry(path, text)
        if text == false then
            git({ "--literal-pathspecs", "update-index", "--force-remove", "--", path })
        else
            local sha = vim.trim(git({ "hash-object", "-w", "--stdin" }, text))
            git({ "update-index", "--add", "--cacheinfo", "100644," .. sha .. "," .. path })
        end
    end
    local function fixture(head, index, live, path, unborn)
        serial = serial + 1
        path = path or ("case-" .. serial .. ".txt")
        entry(path, head)
        if not unborn then
            local tree = vim.trim(git({ "write-tree" }))
            local commit = vim.trim(git({ "commit-tree", tree }, "fixture\n"))
            git({ "update-ref", "HEAD", commit })
        end
        entry(path, index)
        local buf = api.nvim_create_buf(true, false)
        api.nvim_set_current_buf(buf)
        api.nvim_buf_set_name(buf, root .. "/" .. path)
        local eol = live:sub(-1) == "\n"
        api.nvim_buf_set_lines(buf, 0, -1, false,
            vim.split(eol and live:sub(1, -2) or live, "\n", { plain = true }))
        vim.bo[buf].endofline, vim.bo[buf].fixendofline = eol, false
        vim.fn.writefile({ "disk stays untouched" }, root .. "/" .. path)
        state.index[buf] = "stale\n"
        return path, buf
    end
    local function contents(path)
        if git({ "--literal-pathspecs", "ls-files", "--", path }) == "" then return false end
        return git({ "cat-file", "blob", ":" .. path })
    end
    local function check(head, index, live, first, last, want, path, unborn)
        local rel, buf = fixture(head, index, live, path, unborn)
        local before = api.nvim_buf_get_lines(buf, 0, -1, false)
        local modified, eol = vim.bo[buf].modified, vim.bo[buf].endofline
        local undo = #state.undo
        M.unstage(first, last)
        eq(want, contents(rel))
        assert(vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false)))
        eq(modified, vim.bo[buf].modified)
        eq(eol, vim.bo[buf].endofline)
        eq("disk stays untouched", vim.fn.readfile(root .. "/" .. rel)[1])
        if #state.undo > undo then
            state.undo[#state.undo].fn()
            eq(index, contents(rel))
        end
        return rel, buf
    end
    check(false, "one\ntwo\n", "one\ntwo\n", 1, 1, "two\n", nil, true)
    check(false, "one\n", "one\n", nil, nil, false, nil, true)
    entry("unborn-a.txt", "decoy\n")
    check(false, "one\n", "unsaved\n", nil, nil, false, "unborn-[a].txt", true)
    eq("decoy\n", contents("unborn-a.txt"))
    check("a\nb\nc\n", "A\nB\nC\n", "A\nB\nC\n", 2, 2, "A\nb\nC\n")
    check("a\nb\nc\nd\n", "A\nB\nd\n", "A\nB\nd\n", 2, 2, "A\nb\nd\n")
    check("a\nb\nc\nd\n", "A\nB\nd\n", "A\nB\nd\n", 2, 1, "a\nb\nc\nd\n")
    check("a\nz\n", "A\nB\nC\nz\n", "A\nB\nC\nz\n", 2, 2, "A\nC\nz\n")
    check("a\nb\nc\n", "A\nb\nC\n", "insert\nA\nb\nC\n", 4, 4, "A\nb\nc\n")
    check("a\nb\nc\n", "A\nb\nC\n", "A\nC\n", 2, 2, "A\nb\nc\n")
    check("a\nb\nc\n", "A\nb\nC\n", "unstaged\nb\nC\n", 3, 3, "A\nb\nc\n")
    check("a\nb\nc\n", "A\nb\nC\n", "unstaged\nb\nC\n", 1, 3, "A\nb\nC\n")
    assert(messages[#messages]:match("cannot be mapped safely"))
    check("a\nz\n", "A\nz\n", "insert\nA\nz\n", 1, 1, "A\nz\n")
    check("a\nb\nc\n", "A\nB\nC\n", "A\nC\n", 1, 2, "a\nB\nc\n")
    check("a\nb\nc\n", "A\nB\nC\n", "A\ninsert\nB\nC\n", 1, 3, "a\nb\nC\n")
    check("a\nb\nc\n", "a\nc\n", "a\nc\n", 1, 2, "a\nc\n")
    check("a\nb\nc\n", "a\nc\n", "unsaved\n", nil, nil, "a\nb\nc\n")
    check("a\n", false, "unsaved\n", nil, nil, "a\n")
    check(false, "one\ntwo", "one\ntwo", 2, 2, "one\n")
    check(false, "one\ntwo", "one\ntwo", 1, 2, false)
    check("a\nb", "A\nb", "A\nb", 1, 1, "a\nb")
    check("a\nb\n", "a\nb", "a\nb", 2, 2, "a\nb\n")
    check("a\nb", "a\nb\n", "a\nb\n", 2, 2, "a\nb")
    check("a\r\nb\r\n", "A\r\nb\r\n", "A\r\nb\r\n", 1, 1, "a\r\nb\r\n")
    entry("glob-a.txt", "decoy\n")
    check("old\n", "new\n", "unsaved\n", nil, nil, "old\n", "glob-[a].txt")
    eq("decoy\n", contents("glob-a.txt"))
    check(false, "new\n", "unsaved\n", nil, nil, false, ":[literal].txt")
    check("old\n", "new\n", "new\n", 1, 1, "old\n", '-[odd] "quote"\tback\\slash\nname.txt')
    -- Fresh external index changes must win over the rendering cache.
    local rel = fixture("a\nb\n", "A\nB\n", "A\nB\n")
    entry(rel, "external\nB\n")
    M.unstage(2, 2)
    eq("external\nb\n", contents(rel))
    -- Selection uses actual review chunks, even with the overlay off/stale.
    local _, buf = fixture("a\nb\nc\nd\n", "a\nb\nc\nd\n", "A\nB\nc\nD\n")
    state.base[buf] = { rev = "HEAD", text = "stale\n" }
    api.nvim_win_set_cursor(0, { 2, 0 })
    M.select_hunk()
    eq("V", vim.fn.mode())
    eq(1, vim.fn.line("v"))
    eq(2, api.nvim_win_get_cursor(0)[1])
    vim.cmd("normal! \27")
    api.nvim_win_set_cursor(0, { 3, 0 })
    M.select_hunk()
    assert(messages[#messages]:match("no review chunk"))
    fixture("a\nb\nc\n", "a\nc\n", "a\nc\n")
    api.nvim_win_set_cursor(0, { 1, 0 })
    M.select_hunk()
    assert(messages[#messages]:match("removed code has no selectable lines"))
    eq("n", vim.fn.mode())
    -- Commit review of a root commit is against the empty tree, not HEAD.
    state.mode = "commit"
    M.select_hunk()
    eq("V", vim.fn.mode())
    eq(1, vim.fn.line("v"))
    eq(2, api.nvim_win_get_cursor(0)[1])
    vim.cmd("normal! \27")
    state.mode = "worktree"
    vim.g.mapleader = " "
    M.setup({ keymaps = true })
    local called
    M.toggle_viewed = function(first, last) called = { first, last } end
    vim.fn.maparg(" hv", "n", false, true).callback()
    assert(vim.deep_equal({ 1, api.nvim_buf_line_count(0) }, called))
    M.add_note = function(first, last) called = { first, last } end
    vim.fn.maparg(" hc", "n", false, true).callback()
    assert(vim.deep_equal({ 1, api.nvim_buf_line_count(0) }, called))
    print("unstaging: all tests passed")
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
vim.cmd("qa!")
