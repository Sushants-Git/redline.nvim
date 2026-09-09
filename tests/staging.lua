-- Run from the plugin root: nvim --headless -u NONE -l tests/staging.lua
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
-- Apply isolation to the plugin's subprocesses too, not only the test helper.
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_INDEX_FILE = root .. "/.git/index"
vim.env.GIT_DIR = root .. "/.git"
vim.env.GIT_WORK_TREE = root
local function git(args, stdin)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { stdin = stdin, env = {
        GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_INDEX_FILE = root .. "/.git/index", GIT_DIR = root .. "/.git",
        GIT_WORK_TREE = root,
    } }):wait()
    assert(res.code == 0, res.stderr)
    return res.stdout
end
local function eq(want, got)
    assert(want == got, vim.inspect({ expected = want, actual = got }))
end
local function run()
    git({ "init", "-q" })
    -- Only isolate UI/persistence. Staging, diffing, applying and undo use real Git.
    upvalue(M.stage, "ensure_enabled", function() end)
    upvalue(M.stage, "get_root", function() return root end)
    upvalue(M.stage, "render_diff", function() end)
    upvalue(M.stage, "panels_refresh", function() end)
    M.legend = function() end
    local messages = {}
    vim.notify = function(msg, level)
        messages[#messages + 1] = msg
        if level == vim.log.levels.ERROR then error(msg) end
    end
    local state = upvalue(M.stage, "state")
    local serial = 0
    local function fixture(old, new, path, mode)
        serial = serial + 1
        path = path or ("case-" .. serial .. ".txt")
        if old then
            local sha = vim.trim(git({ "hash-object", "-w", "--stdin" }, old))
            git({ "update-index", "--add", "--cacheinfo", (mode or "100644") .. "," .. sha .. "," .. path })
        end
        local buf = api.nvim_create_buf(true, false)
        api.nvim_set_current_buf(buf)
        api.nvim_buf_set_name(buf, root .. "/" .. path)
        local eol = new:sub(-1) == "\n"
        api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(eol and new:sub(1, -2) or new, "\n", { plain = true }))
        vim.bo[buf].endofline = eol
        vim.bo[buf].fixendofline = false
        state.index[buf] = "stale cache\n"
        state.index_hunks[buf] = {}
        local function contents() return git({ "cat-file", "blob", ":" .. path }) end
        return contents, path, buf
    end
    local function check(old, new, first, last, want, path)
        local contents, rel, buf = fixture(old, new, path)
        local before = api.nvim_buf_get_lines(buf, 0, -1, false)
        local eol = vim.bo[buf].endofline
        M.stage(first, last)
        eq(want, contents())
        assert(vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false)))
        eq(eol, vim.bo[buf].endofline)
        eq(nil, vim.uv.fs_stat(root .. "/" .. rel)) -- never writes the buffer
        return contents
    end
    check("a\nz\n", "a\nx\ny\nw\nz\n", 3, 3, "a\ny\nz\n")
    check("a\nb\nc\nd\n", "A\nB\nC\nd\n", 2, 2, "a\nB\nc\nd\n")
    check("a\nb\nz\n", "A\nB\nC\nD\nz\n", 3, 3, "a\nb\nC\nz\n")
    check("a\nb\nc\nd\nz\n", "A\nB\nz\n", 2, 2, "a\nB\nc\nd\nz\n")
    check("a\nb\nc\nd\nz\n", "A\nB\nz\n", 2, 1, "A\nB\nz\n")
    check("a\nz\n", "x\na\ny\nz\nw\n", 3, 5, "a\ny\nz\nw\n")
    check("a\nb\nc\n", "a\nc\n", 1, 2, "a\nb\nc\n")
    local contents = fixture("a\nb\nc\n", "a\nc\n")
    api.nvim_win_set_cursor(0, { 1, 0 })
    M.stage()
    eq("a\nc\n", contents())
    contents = fixture("a\nz\n", "a\nx\ny\nz\n")
    api.nvim_win_set_cursor(0, { 2, 0 })
    M.stage()
    eq("a\nx\ny\nz\n", contents())
    contents = fixture("a\nb\n", "")
    api.nvim_win_set_cursor(0, { 1, 0 })
    M.stage()
    eq("", contents())
    contents = fixture(nil, "one\ntwo")
    M.stage()
    eq("one\ntwo", contents())
    check("a\nb", "A\nb", 1, 1, "A\nb")
    check("a\nb\n", "a\nB", 2, 2, "a\nB")
    check("a\nb", "a\nb\n", 2, 2, "a\nb\n")
    check("a\nb\n", "a\nb", 2, 2, "a\nb")
    check("a\r\nb\r\n", "A\r\nb\r\n", 1, 1, "A\r\nb\r\n")
    check("a", "a\nx\ny", 2, 2, "a\nx\n")
    check(nil, "one\ntwo\nthree", 2, 2, "two\n")
    check(nil, "one\ntwo\nthree", 3, 3, "three")
    check("", "\nx\n", 1, 1, "\n")
    check("a\n", "A\n", 1, 1, "A\n", '-[odd] "quote"\tback\\slash\nname.txt')
    check(nil, "a\nb", 2, 2, "b", 'new [odd] "quote"\tback\\slash\nname.txt')
    check("a\n", "A\n", 1, 1, "A\n", "caf\195\169.txt")
    -- Every invocation re-diffs the actual index, including another tool's edits.
    local rel
    contents, rel = fixture("a\nb\nc\n", "A\nB\nC\n")
    local sha = vim.trim(git({ "hash-object", "-w", "--stdin" }, "external\nb\nc\n"))
    git({ "update-index", "--cacheinfo", "100644," .. sha .. "," .. rel })
    M.stage(2, 2)
    eq("external\nB\nc\n", contents())
    M.stage(3, 3)
    eq("external\nB\nC\n", contents())
    state.undo[#state.undo].fn()
    eq("external\nB\nc\n", contents())
    contents, rel = fixture(nil, "a\nb\n")
    M.stage(2, 2)
    eq("b\n", contents())
    state.undo[#state.undo].fn()
    eq("", git({ "--literal-pathspecs", "ls-files", "--", rel }))
    contents, rel = fixture("a\n", "A\n", nil, "100755")
    M.stage(1, 1)
    assert(git({ "ls-files", "--stage", "--", rel }):match("^100755"))
    -- Literal pathspecs must not snapshot a different matching file for undo.
    fixture("decoy\n", "decoy\n", "glob-a.txt")
    contents = fixture(nil, "new\nextra\n", "glob-[a].txt")
    M.stage(1, 1)
    eq("new\n", contents())
    state.undo[#state.undo].fn()
    eq("", git({ "--literal-pathspecs", "ls-files", "--", "glob-[a].txt" }))
    eq("decoy\n", git({ "cat-file", "blob", ":glob-a.txt" }))
    -- Whole-file staging uses the live buffer, including deletions and empty
    -- untracked files, without a write or pathspec expansion (also before HEAD).
    for _, case in ipairs({
        { "a\nb\nc\n", "a\nc\n" }, { "a\n", "" },
        { false, "" }, { false, "unsaved\n" }, { "old\n", "new" },
    }) do
        local buf
        contents, rel, buf = fixture(case[1], case[2])
        local modified = vim.bo[buf].modified
        M.stage_file()
        eq(case[2], contents())
        eq(modified, vim.bo[buf].modified)
        eq(nil, vim.uv.fs_stat(root .. "/" .. rel))
        state.undo[#state.undo].fn()
        if case[1] then eq(case[1], contents())
        else eq("", git({ "--literal-pathspecs", "ls-files", "--", rel })) end
    end
    fixture("decoy\n", "decoy\n", "whole-a.txt")
    contents = fixture(nil, "literal\n", "whole-[a].txt")
    M.stage_file()
    eq("literal\n", contents())
    eq("decoy\n", git({ "cat-file", "blob", ":whole-a.txt" }))
    -- Ignore checks also apply to buffers that have never existed on disk.
    vim.fn.writefile({ "*.env", "!allowed.env", "literal-a.txt" }, root .. "/.gitignore")
    for _, path in ipairs({ "secret.env", "-[secret].env" }) do
        local buf
        _, rel, buf = fixture(nil, "secret\n", path)
        if path == "secret.env" then vim.fn.writefile({ "disk secret" }, root .. "/" .. rel) end
        local undo = state.undo[#state.undo]
        M.stage(1, 1)
        assert(messages[#messages]:match("ignored untracked"))
        M.stage_file()
        assert(messages[#messages]:match("ignored untracked"))
        eq("", git({ "--literal-pathspecs", "ls-files", "--", rel }))
        eq(undo, state.undo[#state.undo])
        eq(true, vim.bo[buf].modified)
        if path == "secret.env" then eq("disk secret", vim.fn.readfile(root .. "/" .. rel)[1])
        else eq(nil, vim.uv.fs_stat(root .. "/" .. rel)) end
    end
    contents = fixture(nil, "literal\n", "literal-[a].txt")
    M.stage_file()
    eq("literal\n", contents())
    contents = fixture(nil, "allowed\n", "allowed.env")
    M.stage(1, 1)
    eq("allowed\n", contents())
    contents = fixture("old\n", "new\n", "tracked.env")
    M.stage(1, 1)
    eq("new\n", contents())
    M.stage_file()
    eq("new\n", contents())

    -- Mode-only changes use filesystem bits, not executable() or the old mode.
    local function index_mode(path)
        return git({ "--literal-pathspecs", "ls-files", "--stage", "--", path }):match("^(%d+)")
    end
    contents, rel = fixture("same\n", "same\n")
    vim.fn.writefile({ "disk stays untouched" }, root .. "/" .. rel)
    git({ "config", "core.fileMode", "true" })
    assert(vim.uv.fs_chmod(root .. "/" .. rel, 493)) -- 0755
    M.stage_file()
    eq("100755", index_mode(rel))
    state.undo[#state.undo].fn()
    eq("100644", index_mode(rel))
    git({ "config", "core.fileMode", "false" })
    M.stage_file()
    eq("100644", index_mode(rel))
    git({ "config", "core.fileMode", "true" })
    M.stage_file()
    eq("100755", index_mode(rel))
    assert(vim.uv.fs_chmod(root .. "/" .. rel, 420)) -- 0644
    git({ "config", "core.fileMode", "false" })
    M.stage_file()
    eq("100755", index_mode(rel))
    git({ "config", "core.fileMode", "true" })
    M.stage_file()
    eq("100644", index_mode(rel))
    eq("same\n", contents())
    eq("disk stays untouched", vim.fn.readfile(root .. "/" .. rel)[1])
    contents, rel = fixture(nil, "new executable\n")
    vim.fn.writefile({ "disk" }, root .. "/" .. rel)
    assert(vim.uv.fs_chmod(root .. "/" .. rel, 493))
    M.stage(1, 1)
    eq("100755", index_mode(rel))
    state.undo[#state.undo].fn()
    git({ "config", "core.fileMode", "false" })
    M.stage_file()
    eq("100644", index_mode(rel))
    git({ "config", "core.fileMode", "true" })

    -- Real clean conversion, including an LFS-shaped whole-content filter.
    -- No git-lfs dependency: this exercises Git's actual filter machinery.
    vim.fn.writefile({ "*.filter filter=upper", "*.lfs filter=pointer", "*.crlf text eol=lf",
        "*.broken filter=broken" }, root .. "/.gitattributes")
    git({ "config", "filter.upper.clean", "tr '[:lower:]' '[:upper:]'" })
    git({ "config", "filter.upper.required", "true" })
    local pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:" .. string.rep("a", 64) .. "\nsize 8\n"
    git({ "config", "filter.pointer.clean", "cat >/dev/null; printf '%s' '" .. pointer .. "'" })
    git({ "config", "filter.pointer.required", "true" })
    for _, case in ipairs({
        { "-[literal].filter", "unsaved\n", "UNSAVED\n" },
        { "asset.lfs", "payload\n", pointer },
        { "lines.crlf", "one\r\ntwo\r\n", "one\ntwo\n" },
    }) do
        local buf
        contents, rel, buf = fixture(nil, case[2], case[1])
        vim.fn.writefile({ "disk stays untouched" }, root .. "/" .. rel)
        local before = api.nvim_buf_get_lines(buf, 0, -1, false)
        M.stage_file()
        eq(case[3], contents())
        eq(vim.trim(git({ "hash-object", "--path=" .. rel, "--stdin" }, case[2])),
            vim.trim(git({ "rev-parse", ":" .. rel })))
        eq("disk stays untouched", vim.fn.readfile(root .. "/" .. rel)[1])
        eq(true, vim.bo[buf].modified)
        assert(vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false)))
        local snap = git({ "ls-files", "--stage", "--", rel })
        local undo = state.undo[#state.undo]
        api.nvim_buf_set_lines(buf, 0, -1, false, { "new payload\r", "more payload\r" })
        M.stage(1, 1)
        assert(messages[#messages]:match("use whole%-file stage"))
        M.stage()
        eq(snap, git({ "ls-files", "--stage", "--", rel }))
        eq(undo, state.undo[#state.undo])
    end
    _, rel = fixture(nil, "payload\n", "new.lfs")
    M.stage(1, 1)
    eq("", git({ "ls-files", "--", rel }))
    -- A failing required filter must not replace an existing index entry.
    git({ "config", "filter.broken.clean", "false" })
    git({ "config", "filter.broken.required", "true" })
    contents, rel = fixture("staged\n", "unsaved\n", "failure.broken")
    local undo = state.undo[#state.undo]
    local ok, err = pcall(M.stage_file)
    assert(not ok and err:match("staging buffer failed"))
    eq("staged\n", contents())
    eq(undo, state.undo[#state.undo])
    eq(nil, vim.uv.fs_stat(root .. "/" .. rel))
    -- Small exhaustive replacement matrix: additions, balanced replacements,
    -- and replacements with surplus deletions; no unselected new line leaks.
    for old_count = 0, 4 do
        for new_count = 1, 4 do
            local old, new = {}, {}
            for i = 1, old_count do old[i] = "old" .. i .. "\n" end
            for i = 1, new_count do new[i] = "new" .. i .. "\n" end
            for first = 1, new_count do
                for last = first, new_count do
                    local expected = {}
                    for i = 1, math.max(old_count, new_count) do
                        if i >= first and i <= last then
                            expected[#expected + 1] = new[i]
                        elseif old[i] and not (first == 1 and last == new_count) then
                            expected[#expected + 1] = old[i]
                        end
                    end
                    check(table.concat(old), table.concat(new), first, last, table.concat(expected))
                end
            end
        end
    end
    print("staging: all tests passed")
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
vim.cmd("qa!")
