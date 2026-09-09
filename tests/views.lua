-- nvim --headless -u NONE -l tests/views.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local view = require("redline.view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local c = { root = root }
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local ok, err = xpcall(function()
    for _, name in ipairs({ "one", "two", "new [%] # |.txt", "$REDLINE_VIEW_TEST.txt", "${REDLINE_VIEW_TEST}.txt" }) do
        vim.fn.writefile({ "disk", "second", "third" }, root .. "/" .. name)
    end
    vim.o.hidden, vim.o.autowrite, vim.o.autowriteall = false, true, true
    vim.cmd.edit(root .. "/one")
    local one, one_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    api.nvim_buf_set_lines(one, 0, 1, false, { "dirty one" })
    vim.cmd("noautocmd vsplit " .. root .. "/two")
    local two, two_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    api.nvim_buf_set_lines(two, 0, 1, false, { "dirty two" })
    api.nvim_win_set_cursor(two_win, { 2, 0 })
    local expected_options = { number = true, relativenumber = true, signcolumn = "yes:2", foldcolumn = "1", wrap = true }
    for name, value in pairs(expected_options) do vim.wo[two_win][name] = value end
    local redline = require("redline")
    vim.g.mapleader = " "
    redline.setup({ keymaps = false, github = false })
    assert(vim.fn.maparg(" hb", "n") == "")
    local user_mapping = function() end
    vim.keymap.set("n", "<leader>hb", user_mapping, { desc = "User back" })
    redline.setup({ github = false })
    assert(vim.fn.maparg(" hb", "n", false, true).callback == user_mapping)
    vim.keymap.del("n", "<leader>hb")
    vim.keymap.set("n", "<leader>hb", user_mapping, { buffer = two })
    redline.setup({ github = false })
    assert(vim.fn.maparg(" hb", "n", false, true).callback == user_mapping)
    vim.keymap.del("n", "<leader>hb", { buffer = two })
    assert(vim.fn.maparg(" hb", "n") == "")
    redline.setup({ github = false })
    redline.setup({ github = false })
    assert(vim.fn.maparg(" hb", "n", false, true).callback == view.return_to_review)
    local origin_tab, layout = api.nvim_get_current_tabpage(), vim.fn.winlayout()
    local writes = 0
    api.nvim_create_autocmd("BufWritePre", { callback = function() writes = writes + 1 end })
    local diff, diff_win = view.open(c, "Changes", { "+changed" }, { filetype = "diff", hints = "Enter Open file   q Back" })
    local diff_tab = api.nvim_get_current_tabpage()
    assert(#api.nvim_tabpage_list_wins(diff_tab) == 1)
    assert(vim.bo[diff].filetype == "diff" and not vim.bo[diff].modifiable)
    assert(vim.b[diff].redline_root == root)
    assert(api.nvim_buf_get_lines(diff, 0, 1, false)[1] == "Changes")
    local help = view.open(c, "Help", { "Guide" })
    vim.cmd.normal("q")
    assert(not api.nvim_buf_is_valid(help) and api.nvim_get_current_win() == diff_win, vim.inspect(notices))
    help = view.open(c, "Help", {})
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
    assert(not api.nvim_buf_is_valid(help) and api.nvim_get_current_win() == diff_win)
    assert(view.jump(diff, "two", 99))
    assert(api.nvim_get_current_win() == two_win and api.nvim_win_get_cursor(0)[1] == 3)
    assert(api.nvim_buf_is_valid(diff))
    local notice_count = #notices
    assert(notices[notice_count]:find("Space hb", 1, true))
    vim.cmd.normal(" hb")
    assert(api.nvim_get_current_win() == diff_win)
    api.nvim_set_current_win(diff_win)
    assert(view.jump(diff, root .. "/one", 2))
    assert(api.nvim_get_current_win() == one_win)
    api.nvim_set_current_win(diff_win)
    local count = #api.nvim_list_tabpages()
    view.jump(diff, "missing", 1)
    view.jump(diff, "", 1)
    view.jump(diff, root, 1)
    assert(#notices == notice_count + 3 and #api.nvim_list_tabpages() == count)
    assert(api.nvim_get_current_win() == diff_win)
    assert(vim.fn.bufnr(root .. "/missing") == -1)
    assert(view.jump(diff, "new [%] # |.txt", 2))
    local source, source_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    assert(#api.nvim_list_tabpages() == count + 1)
    assert(api.nvim_buf_get_name(source) == root .. "/new [%] # |.txt")
    assert(vim.fn.maparg("q", "n") == "")
    for name, value in pairs(expected_options) do assert(vim.wo[source_win][name] == value, name) end
    api.nvim_buf_set_lines(source, 0, 1, false, { "dirty source" })
    view.return_to_review()
    assert(api.nvim_get_current_win() == diff_win)
    assert(view.jump(diff, "new [%] # |.txt", 1))
    assert(api.nvim_get_current_win() == source_win and #api.nvim_list_tabpages() == count + 1)
    assert(#notices == notice_count + 3, "only notify once per view")

    -- A buffer-local user mapping can shadow Back without being touched on cleanup.
    vim.keymap.set("n", "<leader>hb", user_mapping, { buffer = source })
    -- Explicitly return to the Changes tab, then Back restores the original view.
    api.nvim_set_current_tabpage(diff_tab)
    view.back()
    assert(not api.nvim_buf_is_valid(diff))
    assert(api.nvim_get_current_win() == two_win and api.nvim_win_get_cursor(0)[1] == 2)
    assert(api.nvim_get_current_tabpage() == origin_tab)
    assert(vim.deep_equal(layout, vim.fn.winlayout()))
    assert(api.nvim_win_get_buf(source_win) == source and vim.bo[source].modified)
    api.nvim_set_current_win(source_win)
    assert(vim.fn.maparg(" hb", "n", false, true).callback == user_mapping)
    vim.keymap.del("n", "<leader>hb", { buffer = source })
    assert(vim.fn.maparg(" hb", "n", false, true).callback == view.return_to_review)

    -- Literal Git filenames must not expand environment variables.
    vim.env.REDLINE_VIEW_TEST = "expanded-and-absent"
    api.nvim_set_current_win(two_win)
    local literal, literal_win = view.open(c, "Changes", {})
    for _, name in ipairs({ "$REDLINE_VIEW_TEST.txt", "${REDLINE_VIEW_TEST}.txt" }) do
        assert(view.jump(literal, name, 1))
        assert(api.nvim_buf_get_name(0) == root .. "/" .. name)
        view.return_to_review()
        assert(api.nvim_get_current_win() == literal_win)
    end
    view.back(literal)

    -- Each source window remembers its own most recent review, not another file's.
    api.nvim_set_current_win(two_win)
    local first_view, first_win = view.open(c, "Changes A", {})
    assert(view.jump(first_view, "one", 1))
    local second_view, second_win = view.open(c, "Changes B", {})
    assert(view.jump(second_view, "two", 1))
    api.nvim_set_current_win(one_win)
    view.return_to_review()
    assert(api.nvim_get_current_win() == first_win)
    api.nvim_set_current_win(two_win)
    view.return_to_review()
    assert(api.nvim_get_current_win() == second_win)
    -- An unrelated source uses the latest visited page, including ordinary tab visits.
    api.nvim_set_current_win(source_win)
    view.return_to_review()
    assert(api.nvim_get_current_win() == second_win)
    api.nvim_set_current_win(first_win)
    api.nvim_set_current_win(source_win)
    view.return_to_review()
    assert(api.nvim_get_current_win() == first_win)
    assert(view.jump(first_view, "two", 1))
    view.return_to_review()
    assert(api.nvim_get_current_win() == first_win)
    -- Wiping the winner falls back to another live view, never a dead window.
    view.back(first_view)
    api.nvim_set_current_win(two_win)
    view.return_to_review()
    assert(api.nvim_get_current_win() == second_win)
    view.back(second_view)

    -- Captured source options survive nested views and a closed original tab.
    api.nvim_set_current_win(two_win)
    vim.cmd("noautocmd tabnew")
    local disposable_win = api.nvim_get_current_win()
    for name, value in pairs(expected_options) do vim.wo[disposable_win][name] = value end
    local parent = view.open(c, "Changes", {})
    local child, child_win = view.open(c, "Help", {})
    api.nvim_win_close(disposable_win, false)
    view.back(parent)
    vim.fn.writefile({ "new source" }, root .. "/after-close")
    assert(view.jump(child, "after-close", 1))
    for name, value in pairs(expected_options) do assert(vim.wo[0][name] == value, name) end
    local after_close_win = api.nvim_get_current_win()
    view.return_to_review()
    assert(api.nvim_get_current_win() == child_win)
    assert(view.jump(child, "after-close", 1))
    assert(api.nvim_get_current_win() == after_close_win)
    view.back(child)

    -- Repurposing the origin must not replace its new buffer or cursor.
    vim.cmd("noautocmd tabnew")
    local temporary_win = api.nvim_get_current_win()
    local page = view.open(c, "Help", {})
    local replacement = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(replacement, 0, -1, false, { "replacement", "keep cursor" })
    api.nvim_win_set_buf(temporary_win, replacement)
    api.nvim_win_set_cursor(temporary_win, { 2, 0 })
    view.back(page)
    assert(api.nvim_get_current_buf() == replacement and api.nvim_win_get_cursor(0)[1] == 2)
    page = view.open(c, "Help", {})
    vim.bo[replacement].bufhidden = "hide"
    api.nvim_win_close(temporary_win, false)
    view.back(page)
    assert(not api.nvim_buf_is_valid(page) and vim.bo[replacement].modified)

    -- A source placed into the owned tab is never closed by Back.
    api.nvim_set_current_win(two_win)
    page, diff_win = view.open(c, "Help", {})
    vim.bo[page].bufhidden = "hide"
    api.nvim_win_set_buf(diff_win, source)
    view.back(page)
    assert(api.nvim_win_is_valid(diff_win) and api.nvim_win_get_buf(diff_win) == source)
    assert(not api.nvim_buf_is_valid(page))

    -- Closing an outer page first must not strand its nested Help page.
    api.nvim_set_current_win(two_win)
    local outer = view.open(c, "Changes", {})
    local nested = view.open(c, "Help", {})
    view.back(outer)
    view.back(nested)
    assert(not api.nvim_buf_is_valid(outer) and not api.nvim_buf_is_valid(nested))
    assert(api.nvim_win_is_valid(two_win))

    -- A manual tab close also wipes the owned scratch and leaves Back harmless.
    page = view.open(c, "Help", {})
    vim.cmd.tabclose()
    assert(not api.nvim_buf_is_valid(page))
    view.back(page)

    redline.workflow_context = function() return c end
    vim.g.mapleader = " "
    page = require("redline.workflow").help()
    local text = table.concat(api.nvim_buf_get_lines(page, 0, -1, false), "\n")
    for _, phrase in ipairs({ "Start", "Review", "Move", "Share", "Space ha", "Copy for AI", "Space hb", "Local notes", "this session" }) do
        assert(text:find(phrase, 1, true), phrase)
    end
    assert(not text:find("handoff") and not text:find("repo index"))
    assert(#api.nvim_buf_get_extmarks(page, api.nvim_create_namespace("redline.help"), 0, -1, {}) > 10)
    view.back(page)
    local before = api.nvim_get_current_win()
    view.return_to_review()
    assert(api.nvim_get_current_win() == before and notices[#notices]:find("no review view", 1, true))
    assert(vim.bo[one].modified and vim.bo[two].modified)
    assert(writes == 0 and vim.o.autowrite and vim.o.autowriteall and not vim.o.hidden)
    for _, name in ipairs({ "one", "two", "new [%] # |.txt" }) do
        assert(vim.fn.readfile(root .. "/" .. name)[1] == "disk")
    end
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
print("views: ok")
vim.cmd("qa!")
