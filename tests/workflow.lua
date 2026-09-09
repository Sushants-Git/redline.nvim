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
    contains(snapshot, "Compared with: HEAD")
    contains(snapshot, "Saved files only. Save your edits to include them.")
    contains(snapshot, "+disk")
    contains(snapshot, "untracked bytes")
    contains(snapshot, "[new] space.txt")
    contains(snapshot, "\\ No newline at end of file")
    assert(not snapshot:find("UNSAVED_SENTINEL", 1, true))
    assert(not snapshot:find("saved note", 1, true))
    w.diff(c)
    assert(vim.bo.buftype == "nofile" and not vim.bo.modifiable)
    assert(vim.fn.search("untracked bytes", "w") > 0)
    require("redline.view").back(api.nvim_get_current_buf())
    local original = api.nvim_get_current_buf()
    w.open_target(root, root .. "/deleted.txt", 1, true)
    assert(vim.bo.buftype == "nofile")
    assert(vim.fn.bufnr(root .. "/deleted.txt") == -1)
    require("redline.view").back(api.nvim_get_current_buf())
    assert(api.nvim_get_current_buf() == original)
    local captured
    local actions = w.actions
    w.actions = function() captured = true end
    w.open_target(root, root .. "/[new] space.txt", 1, true)
    assert(api.nvim_buf_get_name(0) == root .. "/[new] space.txt", api.nvim_buf_get_name(0))
    assert(captured)
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
        if key == "a" then assert(captured) end
    end
    w.actions = actions
    vim.ui.select = function() error("unexpected selection prompt") end
    vim.ui.input = function() error("unexpected input prompt") end
    w.handoff(c)
    assert(vim.fn.getreg('"') ~= "", "hidden handoff alias still copies text")
    git("add", "file.txt")
    local calls, notifications, reloads = {}, {}, 0
    local response = { code = 0, stdout = "mock completed", stderr = "" }
    local pending = 0
    vim.notify = function(message) notifications[#notifications + 1] = message end
    r.reload = function() reloads = reloads + 1 end
    vim.system = function(argv, opts, cb)
        if cb then
            assert(opts.cwd == root)
            calls[#calls + 1] = argv
            if argv[1] == "gh" and argv[3] == "create" and vim.fn.has("mac") == 1 then
                assert(opts.env.GH_BROWSER == "open")
            end
            local result = response
            pending = pending + 1
            vim.schedule(function() cb(result); pending = pending - 1 end)
            return {}
        end
        assert(argv[1] == "git", "network operation must be async")
        assert(argv[2] == "-C", "mutating commands must be mocked")
        return system(argv, opts)
    end
    local function flush()
        assert(vim.wait(1000, function() return pending == 0 end))
        vim.wait(20, function() return false end)
    end
    vim.ui.input = function(opts, cb)
        contains(opts.prompt, "staged changes ONLY")
        contains(opts.prompt, "file.txt")
        cb(nil)
    end
    w.commit(c)
    assert(#calls == 0)
    vim.ui.input = function(_, cb) cb("   ") end
    w.commit(c)
    assert(#calls == 0)
    vim.ui.input = function(_, cb) cb("message; $(touch NOT_EXECUTED)") end
    w.commit(c)
    flush()
    assert(vim.deep_equal(calls[1], { "git", "commit", "-m", "message; $(touch NOT_EXECUTED)" }))
    assert(reloads == 1)
    vim.ui.input = function() error("unexpected input prompt") end
    w.push(c)
    flush()
    assert(vim.deep_equal(calls[2], { "git", "push", "--", "origin", "HEAD:refs/heads/topic" }))
    assert(reloads == 2)
    git("config", "branch.topic.remote", "origin")
    git("config", "branch.topic.merge", "refs/heads/main")
    w.push(c)
    flush()
    assert(#calls == 2, "topic tracking origin/main must not automatically push")
    contains(notifications[#notifications], "push refused")
    contains(notifications[#notifications], "configure a matching upstream")
    git("remote", "add", "upstream", "https://example.invalid/upstream.git")
    git("config", "branch.topic.remote", "upstream")
    git("config", "branch.topic.merge", "refs/heads/topic")
    w.push(c)
    flush()
    assert(vim.deep_equal(calls[3], { "git", "push", "--", "upstream", "HEAD:refs/heads/topic" }))
    git("config", "--unset", "branch.topic.remote")
    git("config", "--unset", "branch.topic.merge")
    vim.ui.select = function(_, _, cb) cb(nil) end
    w.push(c)
    assert(#calls == 3)
    vim.ui.select = function(items, _, cb)
        assert(vim.deep_equal(items, { "origin", "upstream" }))
        cb("upstream")
    end
    response = { code = 1, stdout = "", stderr = "push rejected" }
    w.push(c)
    flush()
    assert(vim.deep_equal(calls[4], { "git", "push", "--", "upstream", "HEAD:refs/heads/topic" }))
    assert(reloads == 3)
    contains(notifications[#notifications], "push rejected")
    vim.ui.select = function() error("unexpected selection prompt") end
    git("checkout", "--detach")
    w.push(c)
    assert(#calls == 4)
    contains(notifications[#notifications], "detached HEAD")
    git("checkout", "topic")
    git("remote", "remove", "origin")
    git("remote", "remove", "upstream")
    w.push(c)
    assert(#calls == 4)
    contains(notifications[#notifications], "no remote")
    git("remote", "add", "origin", "https://example.invalid/test.git")

    local browser_urls = {}
    vim.ui.open = function(url)
        browser_urls[#browser_urls + 1] = url
        return nil, "mock browser failure"
    end
    c.github = true
    c.default_branch = "origin/trunk"
    calls = {}
    response = { code = 0, stdout = '{"url":"https://github.com/test/repo/pull/1"}', stderr = "" }
    w.pr(c)
    assert(#calls == 1, "lookup must finish before opening browser")
    flush()
    assert(vim.deep_equal(calls[1], { "gh", "pr", "view", "--json", "url" }))
    if vim.fn.has("mac") == 1 then
        assert(vim.deep_equal(calls[2], { "open", "https://github.com/test/repo/pull/1" }))
    else
        assert(browser_urls[1] == "https://github.com/test/repo/pull/1")
    end
    assert(reloads == 3, "read-only browser workflows must not reload")
    for _, failure in ipairs({ "authentication required", "HTTP 401: Bad credentials", "network unavailable",
        'no pull requests found for branch "other"', 'no pull requests found for branch "topic"\nHTTP 403' }) do
        calls = {}
        response = { code = 1, stdout = "", stderr = failure }
        w.pr(c)
        flush()
        assert(#calls == 1, "lookup errors must not open creation page")
        contains(notifications[#notifications], failure)
    end
    calls = {}
    response = { code = 0, stdout = "invalid JSON", stderr = "" }
    w.pr(c)
    flush()
    assert(#calls == 1)
    contains(notifications[#notifications], "invalid PR response")
    calls = {}
    response = { code = 1, stdout = "", stderr = 'no pull requests found for branch "topic"\n' }
    w.pr(c)
    flush()
    assert(vim.deep_equal(calls[2], { "gh", "pr", "create", "--web", "--head", "topic", "--base", "trunk" }))
    assert(#calls == 2 and reloads == 3)
    for _, base in ipairs({ "release/stable", "origin/release/stable", "refs/remotes/origin/release/stable" }) do
        calls = {}
        c.default_branch = base
        w.pr(c)
        flush()
        assert(vim.deep_equal(calls[2], { "gh", "pr", "create", "--web", "--head", "topic", "--base", "release/stable" }))
    end
    calls = {}
    c.default_branch = false
    w.pr(c)
    flush()
    assert(vim.deep_equal(calls[2], { "gh", "pr", "create", "--web", "--head", "topic" }))
    calls = {}
    c.github = false
    w.pr(c)
    assert(#calls == 0)
    c.github = true
    git("checkout", "--detach")
    w.pr(c)
    assert(#calls == 0)
    contains(notifications[#notifications], "detached HEAD")
    git("checkout", "topic")
    response = { code = 1, stdout = "", stderr = "commit hook rejected" }
    vim.ui.input = function(_, cb) cb("message") end
    w.commit(c)
    flush()
    assert(reloads == 3)
    contains(notifications[#notifications], "commit hook rejected")
    git("reset", "--", "file.txt")
    vim.ui.input = function() error("nothing staged must not prompt") end
    w.commit(c)
    contains(notifications[#notifications], "nothing staged")

    local has = vim.fn.has
    vim.fn.has = function(feature) return feature == "mac" and 0 or has(feature) end
    response = { code = 0, stdout = '{"url":"https://github.com/test/repo/pull/1"}', stderr = "" }
    w.pr(c)
    flush()
    contains(notifications[#notifications], "mock browser failure")
    vim.ui.open = function()
        return {
            is_closing = function() return true end,
            wait = function(_, timeout)
                assert(timeout == 0)
                return { code = 1, stderr = "browser exited unsuccessfully" }
            end,
        }
    end
    w.pr(c)
    flush()
    assert(vim.wait(1000, function()
        return notifications[#notifications]:find("browser exited unsuccessfully", 1, true) ~= nil
    end))
    vim.fn.has = function(feature) return feature == "mac" and 1 or has(feature) end
    local mocked_system = vim.system
    vim.system = function(argv, opts, cb)
        if argv[1] == "open" then
            assert(vim.deep_equal(argv, { "open", "https://github.com/test/repo/pull/1" }))
            cb({ code = 1, stdout = "", stderr = "open failed" })
            return {}
        end
        return mocked_system(argv, opts, cb)
    end
    w.pr(c)
    flush()
    contains(notifications[#notifications], "open failed")
    vim.system = function(argv, opts, cb)
        if cb then error("mock executable not found") end
        return mocked_system(argv, opts, cb)
    end
    w.pr(c)
    contains(notifications[#notifications], "mock executable not found")
    assert(reloads == 3)
    vim.fn.has = has
    vim.system = mocked_system
    calls = {}
    response = { code = 1, stdout = "", stderr = "mock push rejected" }
    git("remote", "add", "fork", "https://example.invalid/fork.git")
    git("config", "branch.topic.remote", "origin")
    git("config", "branch.topic.merge", "refs/heads/topic")
    git("config", "remote.pushDefault", "fork")
    w.push(c)
    flush()
    assert(vim.deep_equal(calls[1], { "git", "push", "--", "fork", "HEAD:refs/heads/topic" }))
    git("config", "branch.topic.pushRemote", "origin")
    w.push(c)
    flush()
    assert(vim.deep_equal(calls[2], { "git", "push", "--", "origin", "HEAD:refs/heads/topic" }))
    git("config", "branch.topic.merge", "refs/heads/main")
    w.push(c)
    flush()
    assert(#calls == 2, "push remote overrides must not bypass mismatched-upstream refusal")
    git("config", "branch.topic.merge", "refs/heads/topic")
    git("config", "branch.topic.pushRemote", "missing")
    w.push(c)
    assert(#calls == 2)
    contains(notifications[#notifications], "configured branch remote is unavailable")
    assert(reloads == 3)
end, debug.traceback)
vim.system = system
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
print("workflow: all tests passed")
vim.cmd("qa!")
