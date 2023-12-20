local _M = {}

local jwt_decoder = require "kong.plugins.jwt.jwt_parser"

-- Return type: [metatable, error]
function _M.decode_token(token)
    local jwt, err = jwt_decoder:new(token)

    if err then
        ngx.log(ngx.STDERR, err)
        return nil, err
    end

    return jwt, nil
end

return _M