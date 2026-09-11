local _M = {}

local redis = require "kong.plugins.frontier.redis"
local utils = require "kong.plugins.frontier.utils"

local kong = kong
local pcall = pcall
local concat = table.concat
local ipairs = ipairs
local sort = table.sort
local hash = utils.hash

-- Builds the key for the credential being exchanged. Only the cookies named in
-- conf.cache_cookie_names go in; the rest change too often to key on. Returns
-- nil when there is no credential, so anonymous requests never share an entry.
function _M.build_key(conf, cookies, bearer)
    local jar = utils.parse_cookies(cookies)

    -- sorted, so the order the names are listed in does not matter
    local names = {}
    for _, name in ipairs(conf.cache_cookie_names or {}) do
        names[#names + 1] = name
    end
    sort(names)

    local has_credential = false

    -- everything that changes what the entry means
    local parts = {
        conf.authn_url or "",
        conf.http_method or "",
        conf.header_name or "",
        conf.token_response_field or "",
        tostring(conf.cache_ttl)
    }

    for _, name in ipairs(names) do
        local values = jar[name]

        -- Every occurrence goes in. Frontier acts on the last `sid` that
        -- decodes, so taking one would let two users hash to the same key.
        if values then
            for _, value in ipairs(values) do
                if value ~= "" then
                    has_credential = true
                end
                parts[#parts + 1] = name .. "=" .. value
            end
        else
            parts[#parts + 1] = name .. "="
        end
    end

    if bearer and bearer ~= "" then
        has_credential = true
        parts[#parts + 1] = bearer
    else
        parts[#parts + 1] = ""
    end

    if not has_credential then
        return nil
    end

    -- hashed, so no session sits in redis as a plaintext key
    return hash(concat(parts, "\0"))
end

-- Resolves the token: redis first, then the auth server through `fetch`. Redis
-- is a cache and not an authority, so any problem with it falls through too.
function _M.get(conf, key, fetch)
    -- no credential to key on, or no redis to key it in
    if not key or not redis.enabled(conf) then
        return fetch()
    end

    -- pcall'd so redis cannot fail a request even by raising
    local ok, cached = pcall(redis.get, conf, key)

    if not ok then
        kong.log.warn("redis lookup raised, ignoring it: ", cached)
    elseif cached then
        kong.log.debug("token served from redis")
        return cached
    end

    local token, err = fetch()
    if not token then
        return nil, err
    end

    -- cache_ttl as configured. The token is not read for its expiry, so
    -- cache_ttl must stay well under the auth server's token lifetime.
    if conf.cache_ttl > 0 then
        local set_ok, set_err = pcall(redis.set, conf, key, token, conf.cache_ttl)
        if not set_ok then
            kong.log.warn("redis write raised, ignoring it: ", set_err)
        end
    end

    return token
end

return _M
