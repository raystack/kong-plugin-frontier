local _M = {}

local resty_sha256 = require "resty.sha256"

local encode_base64 = ngx.encode_base64

-- resty.sha256 rather than kong.tools.sha256, which does not exist before 3.6.
-- One instance per worker, safe because nothing yields between reset and final.
local sha256 = resty_sha256:new()

function _M.hash(input)
    sha256:reset()
    sha256:update(input)
    return (encode_base64(sha256:final(), true):gsub("+", "-"):gsub("/", "_"))
end

-- splits a string s using a delimiter and returns a table
-- containing the resulting substrings
function _M.split(s, delimiter)
    local result = {}
    for match in (s .. delimiter):gmatch("(.-)" .. delimiter) do
        table.insert(result, match)
    end
    return result
end

-- Trim spaces from the starting of a string
function _M.ltrim(s)
    return s:match'^%s*(.*)'
  end

-- Parses a cookie header into a table of name to list of values, in order. A
-- name can legitimately appear more than once, so every value is kept: callers
-- cannot guess which one the auth server will act on.
function _M.parse_cookies(cookie_header)
    local jar = {}

    if not cookie_header then
        return jar
    end

    for pair in cookie_header:gmatch("[^;]+") do
        local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if name then
            local values = jar[name]
            if values then
                values[#values + 1] = value
            else
                jar[name] = { value }
            end
        end
    end

    return jar
end

return _M
