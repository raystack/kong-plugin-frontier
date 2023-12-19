local _M = {}

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

return _M
