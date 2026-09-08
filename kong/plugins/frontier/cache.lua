local _M = {}

local jwt_decoder = require "kong.plugins.frontier.jwt_decoder"
local redis = require "kong.plugins.frontier.redis"
local utils = require "kong.plugins.frontier.utils"

local kong = kong
local ngx = ngx
local pcall = pcall
local concat = table.concat
local ipairs = ipairs
local sort = table.sort
local type = type
local tonumber = tonumber
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
        tostring(conf.cache_ttl),
        tostring(conf.cache_exp_skew)
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

-- How long the entry may live, in seconds. Zero or less means do not store it.
-- Clamped to the token's own expiry minus cache_exp_skew, and nothing else sets
-- the expiry, so a token still in redis has at least the skew left on it.
function _M.ttl_for(conf, token)
    local ttl = conf.cache_ttl

    local jwt = jwt_decoder.decode_token(token)
    local claims = jwt and jwt.claims
    local exp = type(claims) == "table" and tonumber(claims.exp) or nil

    if exp then
        -- ngx.now(), not ngx.time(): whole seconds round down, which would let
        -- an entry outlive its token when cache_exp_skew is 0
        local remaining = exp - ngx.now() - conf.cache_exp_skew
        if remaining < ttl then
            ttl = remaining
        end
    end

    return ttl
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

    local ttl = _M.ttl_for(conf, token)

    if ttl > 0 then
        local set_ok, set_err = pcall(redis.set, conf, key, token, ttl)
        if not set_ok then
            kong.log.warn("redis write raised, ignoring it: ", set_err)
        end
    end

    return token
end

return _M
