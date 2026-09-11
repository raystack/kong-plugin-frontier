local _M = {}

local redis = require "kong.plugins.frontier.redis"
local utils = require "kong.plugins.frontier.utils"

local kong = kong
local pcall = pcall
local concat = table.concat
local ipairs = ipairs
local sort = table.sort
local tostring = tostring
local hash = utils.hash

local function cookie_names_in_a_stable_order(conf)
    local names = {}

    for _, name in ipairs(conf.cache_cookie_names or {}) do
        names[#names + 1] = name
    end

    sort(names)

    return names
end

local function settings_that_change_what_an_entry_means(conf)
    return {
        conf.authn_url or "",
        conf.http_method or "",
        conf.header_name or "",
        conf.token_response_field or "",
        tostring(conf.cache_ttl)
    }
end

function _M.build_key(conf, cookies, bearer)
    local jar = utils.parse_cookies(cookies)
    local parts = settings_that_change_what_an_entry_means(conf)
    local found_a_credential = false

    for _, name in ipairs(cookie_names_in_a_stable_order(conf)) do
        local every_value_sent_under_this_name = jar[name]

        if every_value_sent_under_this_name then
            for _, value in ipairs(every_value_sent_under_this_name) do
                found_a_credential = found_a_credential or value ~= ""
                parts[#parts + 1] = name .. "=" .. value
            end
        else
            parts[#parts + 1] = name .. "="
        end
    end

    found_a_credential = found_a_credential or (bearer ~= nil and bearer ~= "")
    parts[#parts + 1] = bearer or ""

    if not found_a_credential then
        return nil
    end

    return hash(concat(parts, "\0"))
end

local function token_in_redis(conf, key)
    local reached_redis, token = pcall(redis.get, conf, key)

    if not reached_redis then
        kong.log.warn("redis lookup raised, ignoring it: ", token)
        return nil
    end

    return token
end

local function remember_token_in_redis(conf, key, token)
    local reached_redis, err = pcall(redis.set, conf, key, token, conf.cache_ttl)

    if not reached_redis then
        kong.log.warn("redis write raised, ignoring it: ", err)
    end
end

function _M.get(conf, key, fetch_from_auth_server)
    local nothing_to_cache_or_nowhere_to_cache_it = key == nil or not redis.enabled(conf)

    if nothing_to_cache_or_nowhere_to_cache_it then
        return fetch_from_auth_server()
    end

    local cached = token_in_redis(conf, key)

    if cached then
        kong.log.debug("token served from redis")
        return cached
    end

    local token, err = fetch_from_auth_server()

    if not token then
        return nil, err
    end

    if conf.cache_ttl > 0 then
        remember_token_in_redis(conf, key, token)
    end

    return token
end

return _M
