local D = {}

function D.snapshot(c)
    local function git(args, no_index)
        local argv = { "git", "-C", c.root, "--literal-pathspecs", "-c", "diff.suppressBlankEmpty=false" }
        vim.list_extend(argv, args)
        local r = vim.system(argv, { text = false }):wait()
        if r.code ~= 0 and not (no_index and r.code == 1) then error(r.stderr or "git failed") end
        return r.stdout or ""
    end
    local base = c.base
    if base == "HEAD" and not pcall(git, { "rev-parse", "--verify", "HEAD" }) then
        base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    end
    local resolved = vim.trim(git({ "rev-parse", "--verify", base }))
    local options = { "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/",
        "--dst-prefix=b/", "--line-prefix=", "--find-renames", "--ignore-submodules=none", "--no-relative",
        "--submodule=short", "--word-diff=none",
        "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= " }
    local function tracked(format)
        local args = vim.list_extend(vim.deepcopy(options), format)
        vim.list_extend(args, { base, "--" })
        return git(args)
    end
    -- Identical diff options keep NUL-delimited destinations in patch-section order.
    -- Never infer paths from quoted/space-delimited display headers (including binary/rename-only patches).
    local names = vim.split(tracked({ "--name-status", "-z" }), "\0", { plain = true })
    local files, i = {}, 1
    while names[i] and names[i] ~= "" do
        local status, path = names[i], names[i + 1]
        i = i + 2
        if status:match("^[RC]") then path, i = names[i], i + 1 end
        files[#files + 1] = { path = c.root .. "/" .. path, deleted = status == "D", excluded = path == ".comments.txt" }
    end
    local lines = { "Changes: " .. c.mode, "Compared with: " .. base .. " (" .. resolved .. ")",
        "Saved files only. Save your edits to include them.", "" }
    local rows, hunks, saved = {}, {}, {}
    local function append(text, entries)
        local index, target, current, remaining, empty_range = 0, nil, 1, 0, false
        for _, line in ipairs(vim.split(text, "\n", { plain = true, trimempty = false })) do
            if line:match("^diff %-%-git ") then
                index = index + 1
                target, current, remaining, empty_range = entries[index], 1, 0, false
                if target and not target.deleted and not target.excluded and saved[target.path] == nil then
                    local stat = vim.uv.fs_stat(target.path)
                    local file = stat and stat.type == "file" and io.open(target.path, "rb")
                    if file then
                        saved[target.path] = file:read("*a")
                        file:close()
                    end
                end
            end
            if target and not target.excluded then
                local start, count = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
                if start then
                    current = tonumber(start)
                    remaining = count == "" and 1 or tonumber(count)
                    empty_range = remaining == 0
                    hunks[#hunks + 1] = #lines + 1
                end
                local anchor = current
                if start and empty_range then anchor = current + 1 end
                -- A zero-length new range points BEFORE the deletion; use the following line.
                if not start and line:sub(1, 1) == "-" and empty_range then anchor = current + 1 end
                if line:sub(1, 1) == "\\" and rows[#lines] then anchor = rows[#lines].line end
                lines[#lines + 1] = line
                rows[#lines] = { path = target.path, line = math.max(1, anchor), deleted = target.deleted }
                if not start and remaining > 0 and (line:sub(1, 1) == "+" or line:sub(1, 1) == " ") then
                    current, remaining = current + 1, remaining - 1
                end
            end
        end
    end
    append(tracked({ "--patch" }), files)
    for _, path in ipairs(vim.split(git({ "ls-files", "--others", "--exclude-standard", "-z" }), "\0",
        { plain = true, trimempty = true })) do
        if path ~= ".comments.txt" then
            local args = vim.deepcopy(options)
            vim.list_extend(args, { "--no-index", "--", "/dev/null", path })
            append(git(args, true), { { path = c.root .. "/" .. path } })
        end
    end
    return table.concat(lines, "\n"), { rows = rows, hunks = hunks, saved = saved }
end

function D.live_line(saved, path, line)
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then return nil, "This file is absent or deleted." end
    if saved == nil then return nil, "Saved text was unavailable when this diff opened. Reopen the diff." end
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    local live_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local live = table.concat(live_lines, "\n") .. (vim.bo[buf].endofline and "\n" or "")
    -- Keep the captured bytes intact; normalize only the representation Neovim decoded.
    if vim.bo[buf].fileformat == "dos" then saved = saved:gsub("\r\n", "\n") end
    if vim.bo[buf].bomb then saved = saved:gsub("^\239\187\191", "") end
    if saved == live then return math.min(line, #live_lines) end
    if saved:find("\0", 1, true) or (vim.bo[buf].fileencoding ~= "" and vim.bo[buf].fileencoding ~= "utf-8") then
        return math.min(line, #live_lines), "Approximate location: binary or encoded text cannot be mapped safely."
    end
    local saved_count = select(2, saved:gsub("\n", "")) + (saved:sub(-1) == "\n" and 0 or 1)
    line = math.max(1, math.min(line, saved_count))
    local shift = 0
    for _, h in ipairs(vim.diff(saved, live, { result_type = "indices", algorithm = "histogram" })) do
        local old, removed, new, added = unpack(h)
        if removed == 0 then
            if line <= old then break end
        elseif line < old then
            break
        elseif line < old + removed then
            -- The target itself changed: choose the nearer unchanged boundary, not replacement text.
            local before = added == 0 and new or new - 1
            local after = added == 0 and new + 1 or new + added
            local anchor = after
            if old > 1 and (old + removed > saved_count or line - old + 1 < old + removed - line) then
                anchor = before
            end
            local explanation = old == 1 and removed >= saved_count
                and "no saved lines survive in the current buffer."
                or "the saved line was changed or deleted in the current buffer; using the nearest surviving line."
            return math.max(1, math.min(anchor, #live_lines)),
                "Approximate location: " .. explanation
        end
        shift = shift + added - removed
    end
    return math.max(1, math.min(line + shift, #live_lines))
end

return D
