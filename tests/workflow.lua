-- nvim --headless -u NONE -l tests/workflow.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = (vim.uv or vim.loop).fs_realpath(root)
vim.env.XDG_DATA_HOME = root .. "/data"
vim.env.XDG_STATE_HOME = root .. "/state"
vim.env.XDG_CACHE_HOME = root .. "/cache"
vim.g.clipboard = { name = "workflow-test", copy = { ["+"] = function() end, ["*"] = function() end },
    paste = { ["+"] = function() return { {}, "v" } end, ["*"] = function() return { {}, "v" } end } }
local system = vim.system
local function git(...)
    local argv = { "git", "-C", root }
    vim.list_extend(argv, { ... })
    local r = system(argv, { text = true }):wait()
    assert(r.code == 0, r.stderr)
    return vim.trim(r.stdout)
end
local function contains(s, needle) assert(s:find(needle, 1, true), "missing: " .. needle) end
local ok, err = xpcall(function()
    git("init", "-b", "trunk")
    vim.fn.writefile({ "old" }, root .. "/file.txt")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial")
    git("update-ref", "refs/remotes/origin/trunk", "HEAD")
    git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
    git("checkout", "-b", "topic")
    git("remote", "add", "origin", "https://example.invalid/test.git")
    vim.fn.writefile({ "disk" }, root .. "/file.txt", "b")
    vim.fn.writefile({ "untracked bytes" }, root .. "/[new] space.txt", "b")
    vim.fn.writefile({ "file.txt:1: saved note" }, root .. "/.comments.txt")
    vim.cmd.edit(vim.fn.fnameescape(root .. "/file.txt"))
    local r = require("redline")
    r.setup({ keymaps = false, github = false })
    assert(vim.fn.maparg("\\ho", "n") == "")
    vim.g.mapleader = " "
    r.setup({ github = false })
    for _, key in ipairs({ "ho", "ha", "hc", "hv", "h?" }) do assert(vim.fn.maparg(" " .. key, "n") ~= "") end
    for _, key in ipairs({ "ha", "hc", "hv" }) do assert(vim.fn.maparg(" " .. key, "x") ~= "") end
    assert(vim.fn.maparg(" hh", "n") == "")
    assert(vim.deep_equal(vim.fn.getcompletion("Redline ", "cmdline"), { "open", "actions", "diff", "help" }))
    local overview, old_overview = 0, r.overview
    r.overview = function() overview = overview + 1 end
    vim.ui.select = function(items, _, cb)
        contains(items[3].label, "origin/trunk")
        cb(items[1])
    end
    vim.cmd.Redline()
    assert(overview == 1)
    r.overview = old_overview
    local w = require("redline.workflow")
    local c = r.workflow_context()
    api.nvim_buf_set_lines(0, 0, -1, false, { "UNSAVED_SENTINEL" })
    local snapshot = w.snapshot(c)
    contains(snapshot, "+disk")
    contains(snapshot, "untracked bytes")
    contains(snapshot, "[new] space.txt")
    contains(snapshot, "\\ No newline at end of file")
    assert(not snapshot:find("UNSAVED_SENTINEL", 1, true))
    assert(not snapshot:find("saved note", 1, true))
    w.diff(c)
    assert(vim.bo.buftype == "nofile" and not vim.bo.modifiable)
    assert(vim.fn.search("untracked bytes", "w") > 0)
    vim.cmd.close()
    local original = api.nvim_get_current_buf()
    w.open_target(root, root .. "/deleted.txt", 1, true)
    assert(vim.bo.buftype == "nofile")
    assert(vim.fn.bufnr(root .. "/deleted.txt") == -1)
    vim.cmd.close()
    assert(api.nvim_get_current_buf() == original)
    local captured
    vim.ui.select = function(items) captured = items end
    w.open_target(root, root .. "/[new] space.txt", 1, true)
    assert(api.nvim_buf_get_name(0) == root .. "/[new] space.txt", api.nvim_buf_get_name(0))
    assert(captured[1][1] == "Stage hunk")
    local picker_opts, mappings, enter, closed = nil, {}, nil, false
    package.loaded["telescope.pickers"] = { new = function(_, opts)
        picker_opts = opts
        return { find = function() opts.attach_mappings(123, function(mode, key, fn) mappings[mode .. key] = fn end) end }
    end }
    package.loaded["telescope.finders"] = { new_table = function(opts) return opts end }
    package.loaded["telescope.config"] = { values = { generic_sorter = function() return {} end } }
    package.loaded["telescope.pickers.entry_display"] = { create = function() return function(x) return x end end }
    package.loaded["telescope.previewers"] = { new_buffer_previewer = function(opts) return opts end }
    package.loaded["telescope.actions"] = { close = function(prompt) assert(prompt == 123); closed = true end,
        select_default = { replace = function(_, fn) enter = fn end } }
    package.loaded["telescope.actions.state"] = { get_selected_entry = function()
        return { filename = root .. "/[new] space.txt", lnum = 1 }
    end }
    local opened, open_target = 0, w.open_target
    w.open_target = function(repo, file, line, menu)
        assert(closed and repo == root and file == root .. "/[new] space.txt" and line == 1)
        assert(menu == (opened < 2))
        opened = opened + 1
    end
    r.overview()
    contains(picker_opts.results_title, "actions")
    mappings["i<C-a>"]()
    closed = false
    mappings.na()
    closed = false
    enter()
    assert(opened == 3)
    w.open_target = open_target

    -- Refreshing from another repository must not retarget an open split panel.
    local other = root .. "/other-repo"
    vim.fn.mkdir(other, "p")
    assert(system({ "git", "-C", other, "init", "-q" }):wait().code == 0)
    vim.fn.writefile({ "other repository" }, other .. "/other-only.txt")
    local source = api.nvim_get_current_win()
    for _, key in ipairs({ "<CR>", "a" }) do
        api.nvim_set_current_win(source)
        api.nvim_set_current_buf(original)
        r.overview_split()
        local panel, panel_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
        api.nvim_set_current_win(source)
        vim.cmd.edit(vim.fn.fnameescape(other .. "/other-only.txt"))
        r.reload()
        api.nvim_set_current_win(panel)
        assert(vim.b[panel_buf].redline_root == root)
        local row
        for i, text in ipairs(api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
            assert(not text:find("other-only.txt", 1, true), "split changed repositories on refresh")
            if text:find("[new] space.txt", 1, true) then row = i end
        end
        assert(row, "split lost its original repository target")
        api.nvim_win_set_cursor(panel, { row, 0 })
        captured = nil
        vim.fn.maparg(key, "n", false, true).callback()
        assert(not api.nvim_win_is_valid(panel), "selection closes split")
        assert(api.nvim_buf_get_name(0) == root .. "/[new] space.txt")
        if key == "a" then assert(captured and captured[1][1] == "Stage hunk") end
    end
    local stages = 0
    r.stage = function(a, b) assert(a == 1 and b == 2); stages = stages + 1 end
    w.actions(1, 2)
    local stage = captured[1][2]
    vim.ui.select = function(_, _, cb) cb("Cancel") end
    stage()
    assert(stages == 0)
    vim.ui.select = function(_, _, cb) cb("Confirm") end
    stage()
    assert(stages == 1)
    api.nvim_buf_set_lines(0, 0, -1, false, { "changed while menu was open" })
    stage()
    assert(stages == 1)
    w.handoff(c)
    contains(vim.fn.getreg('"'), "saved note")
    contains(vim.fn.getreg('"'), "Base: HEAD")
    git("add", "file.txt")
    local calls = {}
    r.reload = function() end
    vim.system = function(argv, opts, cb)
        if cb then
            assert(opts.cwd == root)
            calls[#calls + 1] = argv
            cb({ code = 0, stdout = "mock completed", stderr = "" })
            return {}
        end
        assert(argv[1] == "git", "network operation must be async")
        return system(argv, opts)
    end
    vim.ui.input = function(_, cb) cb("message; $(touch NOT_EXECUTED)") end
    vim.ui.select = function(_, _, cb) cb("Cancel") end
    w.commit(c)
    assert(#calls == 0)
    vim.ui.select = function(_, _, cb) cb("Confirm") end
    w.commit(c)
    assert(vim.deep_equal(calls[1], { "git", "commit", "-m", "message; $(touch NOT_EXECUTED)" }))
    vim.ui.input = function(_, cb) cb("topic") end
    vim.ui.select = function(items, _, cb) cb(items[1] == "Cancel" and "Confirm" or items[1]) end
    w.push(c)
    assert(vim.deep_equal(calls[2], { "git", "push", "--", "origin", "HEAD:refs/heads/topic" }))
    vim.ui.select = function(_, _, cb) cb(nil) end
    w.push(c)
    assert(#calls == 2)
    vim.ui.select = function(items, _, cb) cb(items[1] == "Cancel" and "Confirm" or items[1]) end
    c.github = true
    local values = { "title; $(nope)", "body with 'quotes'", "trunk" }
    vim.ui.input = function(_, cb) cb(table.remove(values, 1)) end
    w.pr(c, true)
    assert(vim.deep_equal(calls[3], { "gh", "pr", "create", "--head", "topic", "--base", "trunk",
        "--title", "title; $(nope)", "--body", "body with 'quotes'", "--draft" }))
    w.pr(c, false)
    assert(vim.deep_equal(calls[4], { "gh", "pr", "view", "--web" }))
    vim.ui.input = function(_, cb) cb(nil) end
    w.pr(c, true)
    assert(#calls == 4)
    c.github = false
    w.pr(c, false)
    assert(#calls == 4)
    vim.wait(20, function() return false end)
end, debug.traceback)
vim.system = system
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
print("workflow: all tests passed")
vim.cmd("qa!")
