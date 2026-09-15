local _M = {}

local resty_sha256 = require "resty.sha256"

local encode_base64 = ngx.encode_base64

local sha256 = resty_sha256:new()

function _M.hash(input)
    sha256:reset()
    sha256:update(input)
    return (encode_base64(sha256:final(), true):gsub("+", "-"):gsub("/", "_"))
end

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

local function has_a_byte_frontier_would_reject(value)
    return value:find("[^\32-\126]") ~= nil or value:find('["\\;]') ~= nil
end

local function unquoted(value)
    if #value > 1 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
        return value:sub(2, -2)
    end

    return value
end

function _M.parse_cookies(cookie_header)
    local name_to_every_value_sent = {}

    if not cookie_header then
        return name_to_every_value_sent
    end

    for pair in cookie_header:gmatch("[^;]+") do
        local name, raw_value = pair:match("^%s*([^=%s]+)%s*=(.-)%s*$")
        local value = raw_value and unquoted(raw_value)

        if value and not has_a_byte_frontier_would_reject(value) then
            local values = name_to_every_value_sent[name]

            if values then
                values[#values + 1] = value
            else
                name_to_every_value_sent[name] = { value }
            end
        end
    end

    return name_to_every_value_sent
end

return _M
