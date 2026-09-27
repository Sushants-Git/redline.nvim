-- nvim --headless -u NONE -l tests/layout.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local function git(...)
    local r = vim.system(vim.list_extend({ "git", "-C", root }, { ... }), { text = true }):wait()
    assert(r.code == 0, r.stderr)
end
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local function settle() vim.wait(50, function() return false end) end
local ok, err = xpcall(function()
    git("init", "-q")
    git("config", "user.email", "t@t")
    git("config", "user.name", "t")
    vim.fn.writefile({ "one", "two", "three" }, root .. "/a.txt")
    vim.fn.writefile({ "alpha", "beta" }, root .. "/b.txt")
    git("add", ".")
    git("commit", "-qm", "init")
    vim.fn.writefile({ "one", "TWO", "three", "four" }, root .. "/a.txt")
    vim.fn.writefile({ "alpha" }, root .. "/b.txt")

    local redline = require("redline")
    vim.g.mapleader = " "
    redline.setup({ github = false })
    assert(vim.fn.maparg(" hs", "n", false, true).callback == redline.toggle_layout)
    vim.cmd.edit(root .. "/a.txt")
    local a, src = api.nvim_get_current_buf(), api.nvim_get_current_win()
    redline.set_mode("worktree")
    local del_ns = api.nvim_get_namespaces().redline_deleted
    assert(#api.nvim_buf_get_extmarks(a, del_ns, 0, -1, {}) > 0, "unified shows removed code inline")

    vim.o.diffopt = "internal,closeoff,linematch:40"
    redline.set_layout("split")
    local wins = api.nvim_tabpage_list_wins(0)
    assert(#wins == 2, "base window opened")
    assert(api.nvim_get_current_win() == src, "focus stays on the source")
    local base = wins[1]
    local bbuf = api.nvim_win_get_buf(base)
    assert(vim.deep_equal(api.nvim_buf_get_lines(bbuf, 0, -1, false), { "one", "two", "three" }))
    assert(not vim.bo[bbuf].modifiable and vim.bo[bbuf].filetype == "")
    assert(vim.wo[base].diff and vim.wo[src].diff, "both sides in diff mode")
    assert(api.nvim_buf_get_name(bbuf):find("redline://", 1, true))
    assert(#api.nvim_buf_get_extmarks(a, del_ns, 0, -1, {}) == 0, "no inline deletions side by side")
    assert(#api.nvim_buf_get_extmarks(a, api.nvim_get_namespaces().redline, 0, -1, {}) > 0, "marks kept")

    -- line by line: the change pairs up, the pure addition gets a gap on the left
    assert(vim.o.diffopt:find("linematch:1000", 1, true) and vim.o.diffopt:find("algorithm:histogram", 1, true))
    assert(vim.wo[src].fillchars:find("diff:╱", 1, true))
    local base_hl = api.nvim_win_call(base, function()
        return { vim.fn.diff_hlID(2, 1), vim.fn.diff_filler(4) }
    end)
    local src_hl = api.nvim_win_call(src, function()
        return { vim.fn.diff_hlID(2, 1), vim.fn.diff_hlID(4, 1), vim.fn.diff_filler(4) }
    end)
    assert(base_hl[1] ~= 0 and base_hl[2] == 1, "old 'two' changed, gap opposite 'four'")
    assert(src_hl[1] ~= 0 and src_hl[2] ~= 0 and src_hl[3] == 0, "new 'TWO' changed, 'four' added")
    assert(vim.wo[src].winhighlight:find("DiffAdd:RedlineAddLn", 1, true))
    assert(vim.wo[base].winhighlight:find("DiffAdd:RedlineDeleteLn", 1, true))

    -- the pair follows the next file opened in the source window
    vim.cmd.edit(root .. "/b.txt")
    settle()
    assert(#api.nvim_tabpage_list_wins(0) == 2 and api.nvim_win_is_valid(base))
    assert(vim.deep_equal(api.nvim_buf_get_lines(bbuf, 0, -1, false), { "alpha", "beta" }))
    -- a pure deletion leaves the gap on the right
    assert(vim.wo[src].diff and vim.wo[src].winhighlight:find("RedlineAddLn", 1, true), "new file dressed too")
    assert(api.nvim_win_call(src, function() return vim.fn.diff_filler(2) end) == 1)

    -- a new tab gets its own pair
    vim.cmd("tabnew " .. root .. "/a.txt")
    settle()
    assert(#api.nvim_tabpage_list_wins(0) == 2, "new tab paired")
    vim.cmd("tabclose")
    settle()
    assert(#api.nvim_tabpage_list_wins(0) == 2, "closing a tab is not a layout change")

    -- back to unified: base gone, diff off, deletions return
    redline.toggle_layout()
    assert(#api.nvim_tabpage_list_wins(0) == 1 and not vim.wo[src].diff)
    assert(vim.o.diffopt == "internal,closeoff,linematch:40", "user diffopt restored")
    assert(not vim.wo[src].fillchars:find("╱", 1, true) and vim.wo[src].winhighlight == "")
    assert(not api.nvim_buf_is_valid(bbuf))
    vim.cmd.edit(root .. "/a.txt")
    settle()
    assert(#api.nvim_tabpage_list_wins(0) == 1, "unified stays unified")
    assert(#api.nvim_buf_get_extmarks(a, del_ns, 0, -1, {}) > 0)

    -- closing the base window yourself returns to unified
    redline.set_layout("split")
    base = api.nvim_tabpage_list_wins(0)[1]
    api.nvim_win_close(base, true)
    settle()
    vim.cmd.edit(root .. "/b.txt")
    settle()
    assert(#api.nvim_tabpage_list_wins(0) == 1 and not vim.wo[src].diff, "closing base means unified")

    -- turning the overlay off takes the pair down too
    redline.set_layout("split")
    assert(#api.nvim_tabpage_list_wins(0) == 2)
    redline.toggle()
    assert(#api.nvim_tabpage_list_wins(0) == 1 and not vim.wo[src].diff)

    -- configured default and :Redline subcommands
    redline.setup({ github = false, layout = "split" })
    vim.cmd("Redline unified")
    assert(#api.nvim_tabpage_list_wins(0) == 1)
    vim.cmd("Redline split")
    assert(#api.nvim_tabpage_list_wins(0) == 2)
    vim.cmd("Redline layout")
    assert(#api.nvim_tabpage_list_wins(0) == 1)
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then error(err) end
print("layout: ok")
