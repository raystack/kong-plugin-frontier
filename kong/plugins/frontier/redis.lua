local _M = {}

local resty_redis = require "resty.redis"
local utils = require "kong.plugins.frontier.utils"

local kong = kong
local ngx = ngx
local fmt = string.format
local math_floor = math.floor
local tonumber = tonumber

-- Redis is a cache here, not an authority, so nothing in this file fails a
-- request. Every problem returns nil and the caller falls through.
--
-- A worker whose command fails stops trying that instance for
-- redis_breaker_seconds, so an outage cannot make every request pay the
-- timeout. Keyed per instance. A rejected password or database does not trip
-- it, being a config mistake rather than a fault.
local breaker_until = {}

-- memoised per conf table, so the password is hashed once and not per command
local ids = setmetatable({}, { __mode = "k" })

-- Identifies one instance, and is also the pool name. A pooled connection skips
-- authentication, so anything that changes what a connection means belongs in
-- here. The password is hashed so it cannot reach a log.
local function instance_id(conf)
    local id = ids[conf]

    if not id then
        local secret = ""
        if conf.redis_password and conf.redis_password ~= "" then
            secret = utils.hash(conf.redis_password)
        end

        id = fmt("frontier:%s:%d:%d:%s:%s:%s:%s:%s",
            conf.redis_host,
            conf.redis_port,
            conf.redis_database,
            conf.redis_username or "",
            secret,
            conf.redis_ssl and "s" or "p",
            conf.redis_ssl_verify and "v" or "n",
            conf.redis_server_name or "")

        ids[conf] = id
    end

    return id
end

local function connection_options(conf)
    return {
        ssl = conf.redis_ssl,
        ssl_verify = conf.redis_ssl_verify,
        server_name = conf.redis_server_name,
        pool = instance_id(conf)
    }
end

local function breaker_is_open(conf)
    local until_when = breaker_until[instance_id(conf)]
    return until_when ~= nil and ngx.now() < until_when
end

local function trip_breaker(conf, action, err)
    breaker_until[instance_id(conf)] = ngx.now() + conf.redis_breaker_seconds
    kong.log.warn("redis at ", conf.redis_host, ":", conf.redis_port, " failed (",
        action, ": ", err, "), skipping it for ", conf.redis_breaker_seconds, "s")
end

function _M.enabled(conf)
    return conf.redis_host ~= nil and conf.redis_host ~= ""
end

local function get_connection(conf)
    local red = resty_redis:new()
    red:set_timeouts(conf.redis_timeout, conf.redis_timeout, conf.redis_timeout)

    local ok, err = red:connect(conf.redis_host, conf.redis_port, connection_options(conf))
    if not ok then
        trip_breaker(conf, "connect", err)
        return nil
    end

    -- a pooled connection has already authenticated and selected its database
    local reused, reuse_err = red:get_reused_times()
    if reuse_err then
        trip_breaker(conf, "get_reused_times", reuse_err)
        red:close()
        return nil
    end

    -- Redis answering and refusing is a config problem, not an unreachable
    -- instance, so neither of these trips the breaker.
    if reused == 0 then
        if conf.redis_password and conf.redis_password ~= "" then
            local auth_ok, auth_err
            if conf.redis_username and conf.redis_username ~= "" then
                auth_ok, auth_err = red:auth(conf.redis_username, conf.redis_password)
            else
                auth_ok, auth_err = red:auth(conf.redis_password)
            end
            if not auth_ok then
                kong.log.warn("redis refused the credentials for ",
                    conf.redis_host, ":", conf.redis_port, ": ", auth_err)
                red:close()
                return nil
            end
        end

        if conf.redis_database ~= 0 then
            local sel_ok, sel_err = red:select(conf.redis_database)
            if not sel_ok then
                kong.log.warn("redis rejected database ", conf.redis_database,
                    " on ", conf.redis_host, ":", conf.redis_port, ": ", sel_err)
                red:close()
                return nil
            end
        end
    end

    return red
end

local function release(conf, red)
    local ok, err = red:set_keepalive(conf.redis_keepalive_ms, conf.redis_pool_size)
    if not ok then
        kong.log.debug("failed to return redis connection to the pool: ", err)
        red:close()
    end
end

-- Returns the stored value, or nil for a miss, a failure or a tripped breaker.
function _M.get(conf, key)
    if breaker_is_open(conf) then
        return nil
    end

    local red = get_connection(conf)
    if not red then
        return nil
    end

    local value, err = red:get(conf.redis_key_prefix .. key)

    if not value then
        trip_breaker(conf, "get", err)
        red:close()
        return nil
    end

    release(conf, red)

    -- ngx.null is redis saying the key is not there
    if value == ngx.null or value == "" then
        return nil
    end

    return value
end

-- Stores the value with an expiry. A failure is logged and ignored, because the
-- token in hand is still good to use.
function _M.set(conf, key, value, ttl)
    if breaker_is_open(conf) then
        return
    end

    -- milliseconds, so a fractional cache_ttl survives. SETEX takes whole
    -- seconds and redis rejects a fractional argument.
    local px = math_floor((tonumber(ttl) or 0) * 1000)

    if px <= 0 then
        return
    end

    local red = get_connection(conf)
    if not red then
        return
    end

    local ok, err = red:set(conf.redis_key_prefix .. key, value, "PX", px)
    if not ok then
        kong.log.warn("redis rejected the write: ", err)
        red:close()
        return
    end

    release(conf, red)
end

return _M
