local _M = {}

local jwt_decoder = require "kong.plugins.jwt.jwt_parser"

function _M.decode_token(token)
    local parsed_without_raising, jwt, err = pcall(jwt_decoder.new, jwt_decoder, token)

    if not parsed_without_raising then
        local raised = jwt
        ngx.log(ngx.STDERR, raised)
        return nil, "could not decode token"
    end

    if err then
        ngx.log(ngx.STDERR, err)
        return nil, err
    end

    return jwt, nil
end

return _M
