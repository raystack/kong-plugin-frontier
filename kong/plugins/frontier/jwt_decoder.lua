local _M = {}

local jwt_decoder = require "kong.plugins.jwt.jwt_parser"

-- Return type: [metatable, error]
function _M.decode_token(token)
    -- pcall'd because jwt_parser reads the decoded header without checking its
    -- type, so a token whose header segment is valid json but not an object
    -- raises. A cached token can come from anywhere with write access to the
    -- cache, so nothing here can assume the token is well formed.
    local ok, jwt, err = pcall(jwt_decoder.new, jwt_decoder, token)

    if not ok then
        ngx.log(ngx.STDERR, jwt)
        return nil, "could not decode token"
    end

    if err then
        ngx.log(ngx.STDERR, err)
        return nil, err
    end

    return jwt, nil
end

return _M
