-- nvim --headless -u NONE -l tests/diff.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api, root = vim.api, vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local function git(...)
    local args = { "git", "-C", root }
    vim.list_extend(args, { ... })
    local r = vim.system(args, { text = false }):wait()
    assert(r.code == 0, r.stderr)
    return r.stdout
end
local function write(path, lines, flags) vim.fn.writefile(lines, root .. "/" .. path, flags or "") end
local function press(key) vim.fn.maparg(key, "n", false, true).callback() end
local ok, err = xpcall(function()
    git("init", "-b", "main")
    local odd = 'space "quote"\ttab\nline ' .. string.char(195, 169) .. '.txt'
    write("edited", { "one", "old", "three", "four", "five", "six", "seven", "eight", "nine", "ten" })
    write("deleted", { "gone" })
    write("rename old", { "same" })
    write(odd, { "odd old" })
    write("binary", { "old\nbytes" }, "b")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial")
    git("mv", "rename old", "rename new")
    vim.fn.delete(root .. "/deleted")
    write("edited", { "one", "new", "three", "four", "five", "six", "seven", "eight", "nine", "TEN" })
    write(odd, { "odd new" }, "b")
    write("binary", { "new\nbytes" }, "b")
    write("untracked\n\tfile", { "fresh", "last" }, "b")
    write(".comments.txt", { "PRIVATE_NOTES" })
    git("config", "diff.mnemonicPrefix", "true")
    git("config", "diff.noprefix", "true")
    git("config", "diff.srcPrefix", "custom old/")
    git("config", "diff.dstPrefix", "custom new/")
    local w, c = require("redline.workflow"), { root = root, base = "HEAD", mode = "working" }
    local text, meta = w.snapshot(c)
    assert(text:find("Changes: working", 1, true))
    assert(text:find("Compared with: HEAD", 1, true))
    assert(text:find("Saved files only. Save your edits to include them.", 1, true))
    assert(not text:find("PRIVATE_NOTES", 1, true))
    assert(meta.saved[root .. "/" .. odd] == "odd new", "capture missing final newline exactly")
    assert(meta.saved[root .. "/untracked\n\tfile"] == "fresh\nlast")
    local lines = vim.split(text, "\n", { plain = true })
    local found = {}
    for row, line in ipairs(lines) do
        local target = meta.rows[row]
        if line == "+new" or line == "-old" then assert(target.path == root .. "/edited" and target.line == 2); found.edit = true end
        if line == "+TEN" then assert(target.line == 10); found.last = true end
        if line == "+odd new" then assert(target.path == root .. "/" .. odd and target.line == 1); found.odd = true end
        if line == "+last" then assert(target.path == root .. "/untracked\n\tfile" and target.line == 2); found.untracked = true end
        if line == "-gone" then assert(target.deleted); found.deleted = true end
        if line == "rename to rename new" then assert(target.path == root .. "/rename new"); found.rename = true end
        if line:match("^Binary files") then assert(target.path == root .. "/binary"); found.binary = true end
    end
    for _, name in ipairs({ "edit", "last", "odd", "untracked", "deleted", "rename", "binary" }) do assert(found[name], name) end
    vim.cmd.edit(root .. "/edited")
    api.nvim_buf_set_lines(0, 0, 1, false, { "UNSAVED" })
    local source, source_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    w.diff(c)
    local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    assert(#api.nvim_tabpage_list_wins(0) == 1 and win ~= source_win)
    assert(vim.bo.filetype == "diff" and not vim.bo.modifiable)
    assert(vim.fn.search("^+new$", "w") > 0)
    press("<CR>")
    assert(api.nvim_get_current_buf() == source and api.nvim_win_get_cursor(0)[1] == 2)
    assert(vim.bo[source].modified and api.nvim_buf_get_lines(source, 0, 1, false)[1] == "UNSAVED")
    -- Map from captured saved text, even if the disk changes after opening the view.
    api.nvim_buf_set_lines(source, 0, 0, false, { "inserted one", "inserted two" })
    write("edited", { "disk changed after snapshot" })
    api.nvim_set_current_win(win)
    assert(vim.fn.search("^+new$", "w") > 0)
    press("<CR>")
    assert(api.nvim_get_current_buf() == source and api.nvim_win_get_cursor(0)[1] == 4)
    api.nvim_set_current_win(win)
    assert(vim.fn.search("^-old$", "w") > 0)
    press("<CR>")
    assert(api.nvim_win_get_cursor(0)[1] == 4, "removed row follows its saved anchor into live text")
    api.nvim_buf_set_lines(source, 3, 4, false, {})
    local notices, original_notify = {}, vim.notify
    vim.notify = function(s) notices[#notices + 1] = s end
    api.nvim_set_current_win(win)
    assert(vim.fn.search("^+new$", "w") > 0)
    local tick = api.nvim_buf_get_changedtick(source)
    press("<CR>")
    vim.notify = original_notify
    assert(api.nvim_get_current_line() == "three" and api.nvim_win_get_cursor(0)[1] == 4)
    assert(notices[1]:find("Approximate location", 1, true) and notices[1]:find("deleted", 1, true))
    assert(api.nvim_buf_get_changedtick(source) == tick and vim.bo[source].modified)
    api.nvim_set_current_win(win)
    assert(vim.fn.search("^+odd new$", "w") > 0)
    press("<CR>")
    assert(api.nvim_buf_get_name(0) == root .. "/" .. odd and api.nvim_win_get_cursor(0)[1] == 1)
    api.nvim_set_current_win(win)
    assert(vim.fn.search("^+last$", "w") > 0)
    press("<CR>")
    assert(api.nvim_buf_get_name(0) == root .. "/untracked\n\tfile" and api.nvim_win_get_cursor(0)[1] == 2)
    assert(not vim.bo.endofline)
    local untracked = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(untracked, 0, 0, false, { "above one", "above two" })
    api.nvim_set_current_win(win)
    assert(vim.fn.search("^+last$", "w") > 0)
    press("<CR>")
    assert(api.nvim_get_current_buf() == untracked and api.nvim_win_get_cursor(0)[1] == 4)
    assert(not vim.bo.endofline and vim.bo.modified)
    api.nvim_set_current_win(win)
    assert(vim.fn.search("^-gone$", "w") > 0)
    local notice
    local notify = vim.notify
    vim.notify = function(s) notice = s end
    press("<CR>")
    vim.notify = notify
    assert(notice:find("deleted") and api.nvim_get_current_buf() == buf)
    assert(vim.fn.bufnr(root .. "/deleted") == -1)
    api.nvim_win_set_cursor(win, { 1, 0 })
    press("]h")
    assert(api.nvim_get_current_line():match("^@@"))
    local first = api.nvim_win_get_cursor(0)[1]
    press("]h"); press("[h")
    assert(api.nvim_win_get_cursor(0)[1] == first)
    press("?")
    assert(api.nvim_get_current_buf() ~= buf)
    press("q")
    assert(api.nvim_get_current_buf() == buf)
    press("q")
    assert(api.nvim_get_current_win() == source_win and api.nvim_get_current_buf() == source)
    -- Zero-context deletions anchor after the old range, then clamp at EOF in view.jump.
    git("config", "diff.context", "0")
    write("edited", { "one", "three", "four", "five", "six", "seven", "eight", "nine" })
    text, meta = w.snapshot(c)
    for row, line in ipairs(vim.split(text, "\n", { plain = true })) do
        if line == "-old" then assert(meta.rows[row].line == 2) end
        if line == "-ten" then assert(meta.rows[row].line == 9) end
    end
    -- An unborn branch uses the empty tree and still includes untracked files.
    git("checkout", "--orphan", "unborn")
    text = w.snapshot(c)
    assert(text:find("Compared with: 4b825", 1, true) and text:find("+fresh", 1, true))
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
print("diff: all tests passed")
vim.cmd("qa!")
