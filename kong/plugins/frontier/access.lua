local _M = {}

local http = require "resty.http"
local json = require('cjson')
local jwt_decoder = require "kong.plugins.frontier.jwt_decoder"
local kong = kong
local ngx = ngx
local utils = require "kong.plugins.frontier.utils"
local unauthorized_response = {
    message = "unauthorized"
}
local method_to_permission_map = {
    ["GET"] = "view",
    ["HEAD"] = "view",
    ["POST"] = "create",
    ["PUT"] = "update",
    ["PATCH"] = "update",
    ["DELETE"] = "delete"
}

local frontier_org_ids_claim_key = "org_ids"

local function fail_auth()
    kong.response.exit(ngx.HTTP_UNAUTHORIZED, unauthorized_response)
end

local function get_http_client(conf)
    local client = http.new()
    client:set_timeouts(conf.http_connect_timeout, conf.http_read_timeout, conf.http_send_timeout)
    return client
end

-- send a request to auth server and fetch user token in exchange of cookies
local function check_request_identity(conf, cookies, bearer)
    local client = get_http_client(conf)
    local res, err = client:request_uri(conf.authn_url, {
        method = conf.http_method,
        headers = {
            ["cookie"] = cookies,
            ["authorization"] = bearer
        }
    })
    if not res or err then
        kong.log.debug(err)
        return fail_auth()
    end
    if not err and res and res.status ~= 200 then
        return kong.response.exit(ngx.HTTP_UNAUTHORIZED, unauthorized_response, {
            ["x-upstream-status"] = res.status
        })
    end

    -- set an upstream header if the credential exists and is valid
    return res.headers[conf.header_name]
end

local function get_permission(conf_methods)
    local req_method = kong.request.get_method()
    local permission = method_to_permission_map[req_method]

    -- check if path needs to override default permission to method mapping
    for i, val in ipairs(conf_methods) do
        local parts = utils.split(val, "#")
        if #parts == 2 then
            if parts[1] == req_method then
                permission = parts[2]
            end
        end
    end

    return permission
end

-- send a check request to auth server to verify user permission
local function check_request_permission(conf, cookies, bearer)
    local permission = get_permission(conf.rule.methods)

    local object_id = ngx.ctx.router_matches.uri_captures[conf.rule.id]
    if not object_id then
        return fail_auth()
    end

    local payload = {
        ["objectId"] = object_id,
        ["objectNamespace"] = conf.rule.namespace,
        ["permission"] = permission
    }

    local client = get_http_client(conf)
    local res, err = client:request_uri(conf.authz_url, {
        method = "POST",
        headers = {
            ["cookie"] = cookies,
            ["authorization"] = bearer,
            ['content-type'] = 'application/json'
        },
        body = json.encode(payload)
    })
    if not res or err then
        kong.log.debug(err)
        return fail_auth()
    end
    if not err and res and res.status ~= 200 then
        return kong.response.exit(ngx.HTTP_UNAUTHORIZED, unauthorized_response, {
            ["x-upstream-status"] = res.status
        })
    end

    local bodyJson, err = json.decode(res.body)
    if err or not bodyJson then
        kong.log.debug(err)
        return fail_auth()
    end

    if bodyJson["status"] ~= true then
        return fail_auth()
    end
end


local function append_claims_as_headers(conf, user_token)
    local clear_header = kong.service.request.clear_header
    local set_header = kong.service.request.set_header

    local req_headers = kong.request.get_headers()

    -- Clear headers of the format matching conf.frontier_header_prefix. These should be set only by the plugin.
    for _, header in pairs(req_headers) do
        local trimmed_header = utils.ltrim(header)

        -- Format: string.find(fullstring, searchstring, init, is_this_a_pattern)
        -- The last parameter here is important, since without this, we can run into "escape" issues. Eg. without this, "-" needs to be matched with "%-".
        local st, en = string.find(string.lower(trimmed_header), string.lower(conf.frontier_header_prefix), 1, true)

        if st == 1 then
            clear_header(header)
        end
    end

    local jwt, err = jwt_decoder.decode_token(user_token)
    if err then
        return fail_auth()
    end

    local claims = jwt.claims

    for _, header_name in pairs(conf.token_claims_to_append_as_headers) do
        local new_header = conf.frontier_header_prefix .. header_name
        local val = claims[header_name]

        set_header(new_header, val)
    end

end

local function verify_organization_id_header(conf, user_token)
    local request_organization_id = kong.request.get_header(conf.request_organization_id_header)
    
    if request_organization_id then
        local jwt, err = jwt_decoder.decode_token(user_token)
        if err then
            return fail_auth()
        end
    
        local claims = jwt.claims
        local org_ids = claims[frontier_org_ids_claim_key]

        local org_id_header_verified = false
        for word in string.gmatch(org_ids, '([^,]+)') do
            if word == request_organization_id then
                org_id_header_verified = true
            end
        end

        if not org_id_header_verified then
            kong.log.info(conf.request_organization_id_header .. " header removed for request")
            kong.service.request.clear_header(conf.request_organization_id_header)
        end
    end
end

-- run it for every request
function _M.run(conf)
    local cookies = kong.request.get_header("cookie")
    local bearer = kong.request.get_header("authorization")

    -- verify user identity(authn)
    local user_token = check_request_identity(conf, cookies, bearer)
    kong.service.request.set_header(conf.header_name, user_token)

    if conf.override_authz_header then
        kong.service.request.set_header("Authorization", "Bearer " .. user_token)
    end

    -- verify user permission(path authz)
    if conf.authz_url then
        if conf.rule then
            check_request_permission(conf, cookies, bearer)
        end
    end

    if #conf.token_claims_to_append_as_headers > 0 then
        append_claims_as_headers(conf, user_token)
    end

    if conf.verify_request_organization_id_header then
        verify_organization_id_header(conf, user_token)
    end
end

return _M
