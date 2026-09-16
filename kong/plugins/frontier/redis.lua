local _M = {}

local resty_redis = require "resty.redis"
local utils = require "kong.plugins.frontier.utils"

local kong = kong
local ngx = ngx
local fmt = string.format
local math_floor = math.floor
local tonumber = tonumber

local KEEPALIVE_MS = 60000
local POOL_SIZE = 30
local KEY_NOT_FOUND = ngx.null
local NEVER_USED_BEFORE = 0

local skip_instance_until = {}

local instance_ids_by_conf = setmetatable({}, { __mode = "k" })

local function instance_id(conf)
    local id = instance_ids_by_conf[conf]

    if not id then
        local secret = ""

        if conf.redis_password and conf.redis_password ~= "" then
            secret = utils.hash(conf.redis_password)
        end

        id = fmt("frontier:%s:%d:%d:%s:%s:%s",
            conf.redis_host,
            conf.redis_port,
            conf.redis_database,
            conf.redis_username or "",
            secret,
            conf.redis_ssl and "s" or "p")

        instance_ids_by_conf[conf] = id
    end

    return id
end

local function instance_is_being_skipped(conf)
    local until_when = skip_instance_until[instance_id(conf)]

    return until_when ~= nil and ngx.now() < until_when
end

local function skip_instance_for_a_while(conf, action, err)
    skip_instance_until[instance_id(conf)] = ngx.now() + conf.redis_breaker_seconds

    kong.log.warn("redis at ", conf.redis_host, ":", conf.redis_port, " failed (",
        action, ": ", err, "), skipping it for ", conf.redis_breaker_seconds, "s")
end

function _M.enabled(conf)
    return conf.redis_host ~= nil and conf.redis_host ~= ""
end

local function authenticate_and_select_database(red, conf)
    if conf.redis_password and conf.redis_password ~= "" then
        local accepted, err

        if conf.redis_username and conf.redis_username ~= "" then
            accepted, err = red:auth(conf.redis_username, conf.redis_password)
        else
            accepted, err = red:auth(conf.redis_password)
        end

        if not accepted then
            skip_instance_for_a_while(conf, "auth", err)
            return false
        end
    end

    if conf.redis_database ~= 0 then
        local selected, err = red:select(conf.redis_database)

        if not selected then
            skip_instance_for_a_while(conf, "select", err)
            return false
        end
    end

    return true
end

local function borrow_connection(conf)
    local red = resty_redis:new()
    red:set_timeouts(conf.redis_timeout, conf.redis_timeout, conf.redis_timeout)

    local connected, connect_err = red:connect(conf.redis_host, conf.redis_port, {
        ssl = conf.redis_ssl,
        ssl_verify = conf.redis_ssl_verify,
        server_name = conf.redis_server_name,
        pool = instance_id(conf)
    })

    if not connected then
        skip_instance_for_a_while(conf, "connect", connect_err)
        return nil
    end

    local times_used_before, reuse_err = red:get_reused_times()

    if reuse_err then
        skip_instance_for_a_while(conf, "get_reused_times", reuse_err)
        red:close()
        return nil
    end

    if times_used_before == NEVER_USED_BEFORE and not authenticate_and_select_database(red, conf) then
        red:close()
        return nil
    end

    return red
end

local function return_connection(red)
    local returned, err = red:set_keepalive(KEEPALIVE_MS, POOL_SIZE)

    if not returned then
        kong.log.debug("failed to return redis connection to the pool: ", err)
        red:close()
    end
end

function _M.get(conf, key)
    if instance_is_being_skipped(conf) then
        return nil
    end

    local red = borrow_connection(conf)

    if not red then
        return nil
    end

    local value, err = red:get(conf.redis_key_prefix .. key)

    if not value then
        skip_instance_for_a_while(conf, "get", err)
        red:close()
        return nil
    end

    return_connection(red)

    if value == KEY_NOT_FOUND or value == "" then
        return nil
    end

    return value
end

function _M.set(conf, key, value, ttl_seconds)
    if instance_is_being_skipped(conf) then
        return
    end

    local expires_in_ms = math_floor((tonumber(ttl_seconds) or 0) * 1000)

    if expires_in_ms <= 0 then
        return
    end

    local red = borrow_connection(conf)

    if not red then
        return
    end

    local stored, err = red:set(conf.redis_key_prefix .. key, value, "PX", expires_in_ms)

    if not stored then
        kong.log.warn("redis rejected the write: ", err)
        red:close()
        return
    end

    return_connection(red)
end

return _M
