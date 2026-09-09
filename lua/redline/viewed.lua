local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("redline_viewed_positions")
local tracked = {}
local serial = 0

function M.buffer_text(buf)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Neovim represents a zero-byte file as one empty buffer line.
    if #lines == 1 and lines[1] == "" and api.nvim_buf_call(buf, function()
        return vim.fn.wordcount().bytes == 0
    end) then return "" end
    return table.concat(lines, "\n") .. (vim.bo[buf].endofline and "\n" or "")
end

function M.decode(text)
    local ok, data = pcall(vim.json.decode, text)
    local roots = {}
    -- Shipped text-only hashes cannot establish which occurrence was reviewed.
    if not ok or type(data) ~= "table" or data.version ~= 2 or type(data.roots) ~= "table" then
        return roots
    end
    for root, files in pairs(data.roots) do
        if type(files) == "table" then
            for rel, records in pairs(files) do
                if type(records) == "table" then
                    for key, r in pairs(records) do
                        if type(key) == "string" and type(r) == "table"
                            and type(r.line) == "number" and r.line >= 1 and r.line % 1 == 0
                            and type(r.fingerprint) == "string" and type(r.snapshot) == "string" then
                            roots[root] = roots[root] or {}
                            roots[root][rel] = roots[root][rel] or {}
                            roots[root][rel][key] = r
                        end
                    end
                end
            end
        end
    end
    return roots
end

local function bind(buf, key, r)
    local id = api.nvim_buf_set_extmark(buf, ns, r.line - 1, 0, {
        end_row = r.line, end_col = 0, right_gravity = true,
        end_right_gravity = false, invalidate = true, undo_restore = true,
    })
    tracked[key] = { buf = buf, id = id }
    return tracked[key]
end

function M.match(buf, records, candidates, snapshot)
    local seen = {}
    for key, r in pairs(records) do
        local mark = tracked[key]
        local pos = mark and mark.buf == buf and api.nvim_buf_is_valid(buf)
            and api.nvim_buf_get_extmark_by_id(buf, ns, mark.id, { details = true }) or {}
        -- Unloading preserves the buffer number but removes its extmarks.
        if #pos == 0 then
            if r.snapshot == snapshot and r.line <= api.nvim_buf_line_count(buf) then
                mark = bind(buf, key, r)
                pos = api.nvim_buf_get_extmark_by_id(buf, ns, mark.id, { details = true })
            end
        end
        if #pos > 0 and not pos[3].invalid then
            local line = pos[1] + 1
            for i, c in ipairs(candidates) do
                if c[1] == line and c[3] == r.fingerprint then
                    seen[i] = key
                    r.line, r.snapshot = line, snapshot
                end
            end
        end
    end
    return seen
end

function M.add(buf, records, candidate, snapshot)
    serial = serial + 1
    local key = tostring((vim.uv or vim.loop).hrtime()) .. ":" .. serial
    local r = { line = candidate[1], fingerprint = candidate[3], snapshot = snapshot }
    records[key] = r
    bind(buf, key, r)
end

function M.unload(buf)
    for key, mark in pairs(tracked) do
        if mark.buf == buf then tracked[key] = nil end
    end
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

return M
