local PLUGIN_NAME = "frontier"

-- redis.lua talks to a real socket, so resty.redis stands in as a table here.
-- The stub records every command and can be told to fail any of them, which is
-- what lets the pause, the login and the not-found reply be driven directly.

-- redis.lua binds `kong` at require time, so this table has to be in place
-- before it is required and must not be swapped out afterwards
local warnings = 0

_G.kong = {
    log = {
        debug = function() end,
        info = function() end,
        err = function() end,
        warn = function() warnings = warnings + 1 end
    }
}

local server = {}

local function reset_server()
    server.store = {}
    server.calls = {}
    server.fail = {}
    server.reused_times = 0
    server.closed = 0
    server.kept_alive = 0
    warnings = 0
end

local function record(name, ...)
    server.calls[#server.calls + 1] = name
    return ...
end

local function calls_named(name)
    local n = 0
    for _, call in ipairs(server.calls) do
        if call == name then
            n = n + 1
        end
    end
    return n
end

package.loaded["resty.redis"] = {
    new = function()
        return {
            set_timeouts = function() end,

            connect = function(_, host, port)
                record("connect")
                if server.fail.connect then
                    return nil, "connection refused"
                end
                server.last_host, server.last_port = host, port
                return true
            end,

            get_reused_times = function()
                record("get_reused_times")
                if server.fail.get_reused_times then
                    return nil, "broken pool"
                end
                return server.reused_times
            end,

            auth = function(_, a, b)
                record("auth")
                server.auth_args = { a, b }
                if server.fail.auth then
                    return nil, "WRONGPASS"
                end
                return true
            end,

            select = function(_, db)
                record("select")
                server.selected = db
                if server.fail.select then
                    return nil, "DB index out of range"
                end
                return true
            end,

            get = function(_, key)
                record("get")
                if server.fail.get then
                    return nil, "read timeout"
                end
                local value = server.store[key]
                if value == nil then
                    return ngx.null
                end
                return value
            end,

            set = function(_, key, value, unit, amount)
                record("set")
                if server.fail.set then
                    return nil, "OOM"
                end
                server.store[key] = value
                server.last_expiry = { unit = unit, amount = amount }
                return true
            end,

            set_keepalive = function()
                record("set_keepalive")
                server.kept_alive = server.kept_alive + 1
                return true
            end,

            close = function()
                record("close")
                server.closed = server.closed + 1
                return true
            end
        }
    end
}

-- 04-cache_spec swaps this module for a table of its own, so it is cleared
-- here to be sure these tests drive the real one
package.loaded["kong.plugins." .. PLUGIN_NAME .. ".redis"] = nil

local redis = require("kong.plugins." .. PLUGIN_NAME .. ".redis")

local function conf(overrides)
    local c = {
        redis_host = "10.0.0.1",
        redis_port = 6379,
        redis_timeout = 100,
        redis_database = 0,
        redis_key_prefix = "frontier:authn:",
        redis_breaker_seconds = 10,
        redis_ssl = false,
        redis_ssl_verify = false
    }
    for k, v in pairs(overrides or {}) do
        c[k] = v
    end
    return c
end

-- each test uses its own host so the pause from one cannot reach another
local next_host = 0
local function fresh_conf(overrides)
    next_host = next_host + 1
    local c = conf(overrides)
    c.redis_host = "10.0.0." .. next_host
    return c
end


describe("Plugin: " .. PLUGIN_NAME .. " (redis), ", function()
    describe("enabled", function()
        it("needs a host", function()
            assert.is_false(redis.enabled(conf({ redis_host = "" })))
            assert.is_true(redis.enabled(conf()))
        end)
    end)

    describe("reading", function()
        it("returns the stored value", function()
            reset_server()
            local c = fresh_conf()
            server.store["frontier:authn:k"] = "a-token"

            assert.equal("a-token", redis.get(c, "k"))
        end)

        it("reads a not-found reply as a miss", function()
            reset_server()
            local c = fresh_conf()

            assert.is_nil(redis.get(c, "missing"))
            assert.equal(1, calls_named("get"))
        end)

        it("reads an empty value as a miss", function()
            reset_server()
            local c = fresh_conf()
            server.store["frontier:authn:k"] = ""

            assert.is_nil(redis.get(c, "k"))
        end)

        it("prefixes the key", function()
            reset_server()
            local c = fresh_conf({ redis_key_prefix = "other:" })
            server.store["other:k"] = "v"

            assert.equal("v", redis.get(c, "k"))
        end)

        it("returns the connection to the pool on the way out", function()
            reset_server()
            local c = fresh_conf()
            server.store["frontier:authn:k"] = "v"

            redis.get(c, "k")
            assert.equal(1, server.kept_alive)
            assert.equal(0, server.closed)
        end)
    end)

    describe("writing", function()
        it("stores with a millisecond expiry", function()
            reset_server()
            local c = fresh_conf()

            redis.set(c, "k", "v", 5)
            assert.equal("v", server.store["frontier:authn:k"])
            assert.same({ unit = "PX", amount = 5000 }, server.last_expiry)
        end)

        it("keeps a fractional ttl", function()
            reset_server()
            local c = fresh_conf()

            redis.set(c, "k", "v", 0.5)
            assert.same({ unit = "PX", amount = 500 }, server.last_expiry)
        end)

        it("writes nothing for a ttl of zero or less", function()
            reset_server()
            local c = fresh_conf()

            redis.set(c, "k", "v", 0)
            redis.set(c, "k", "v", -1)
            assert.equal(0, calls_named("set"))
            assert.equal(0, calls_named("connect"))
        end)

        it("a rejected write is swallowed", function()
            reset_server()
            local c = fresh_conf()
            server.fail.set = true

            redis.set(c, "k", "v", 5)
            assert.equal(1, server.closed)
        end)
    end)

    describe("logging in", function()
        it("logs in and selects on a connection never used before", function()
            reset_server()
            local c = fresh_conf({ redis_password = "s3cret", redis_database = 3 })
            server.reused_times = 0

            redis.get(c, "k")
            assert.equal(1, calls_named("auth"))
            assert.equal(1, calls_named("select"))
            assert.equal(3, server.selected)
        end)

        it("does neither on a connection from the pool", function()
            reset_server()
            local c = fresh_conf({ redis_password = "s3cret", redis_database = 3 })
            server.reused_times = 4

            redis.get(c, "k")
            assert.equal(0, calls_named("auth"))
            assert.equal(0, calls_named("select"))
        end)

        it("sends the user name when there is one", function()
            reset_server()
            local c = fresh_conf({ redis_username = "alice", redis_password = "s3cret" })

            redis.get(c, "k")
            assert.same({ "alice", "s3cret" }, server.auth_args)
        end)

        it("sends only the password when there is no user name", function()
            reset_server()
            local c = fresh_conf({ redis_password = "s3cret" })

            redis.get(c, "k")
            assert.same({ "s3cret" }, server.auth_args)
        end)

        it("skips select on database zero", function()
            reset_server()
            local c = fresh_conf({ redis_database = 0 })

            redis.get(c, "k")
            assert.equal(0, calls_named("select"))
        end)
    end)

    describe("the pause after a failure", function()
        it("starts on a failed get and skips the next command entirely", function()
            reset_server()
            local c = fresh_conf()
            server.fail.get = true

            assert.is_nil(redis.get(c, "k"))
            assert.equal(1, calls_named("connect"))
            assert.equal(1, warnings)

            -- the second call must not reach the socket at all
            assert.is_nil(redis.get(c, "k"))
            assert.equal(1, calls_named("connect"))
            assert.equal(1, warnings)
        end)

        it("skips writes too, not just reads", function()
            reset_server()
            local c = fresh_conf()
            server.fail.connect = true

            redis.get(c, "k")
            assert.equal(1, calls_named("connect"))

            redis.set(c, "k", "v", 5)
            assert.equal(1, calls_named("connect"))
        end)

        it("starts on a refused password", function()
            reset_server()
            local c = fresh_conf({ redis_password = "wrong" })
            server.fail.auth = true

            assert.is_nil(redis.get(c, "k"))
            assert.equal(1, warnings)

            -- a mistyped password must not cost a dial and a login per request
            assert.is_nil(redis.get(c, "k"))
            assert.equal(1, calls_named("connect"))
            assert.equal(1, calls_named("auth"))
            assert.equal(1, warnings)
        end)

        it("starts on a rejected database", function()
            reset_server()
            local c = fresh_conf({ redis_database = 9 })
            server.fail.select = true

            assert.is_nil(redis.get(c, "k"))
            assert.is_nil(redis.get(c, "k"))
            assert.equal(1, calls_named("connect"))
            assert.equal(1, warnings)
        end)

        it("is kept per instance, so one bad redis does not stop a good one", function()
            reset_server()
            local bad = fresh_conf()
            local good = fresh_conf()
            server.fail.connect = true

            redis.get(bad, "k")
            server.fail.connect = false
            server.store["frontier:authn:k"] = "v"

            assert.equal("v", redis.get(good, "k"))
        end)

        it("treats a different database as a different instance", function()
            reset_server()
            local c = fresh_conf()
            local other_db = conf({ redis_host = c.redis_host, redis_database = 7 })
            server.fail.connect = true

            redis.get(c, "k")
            server.fail.connect = false
            server.store["frontier:authn:k"] = "v"

            assert.equal("v", redis.get(other_db, "k"))
        end)

        it("treats a different password as a different instance", function()
            -- the pool name carries the hashed password, so a config with the
            -- wrong one cannot pause the config with the right one
            reset_server()
            local right = fresh_conf({ redis_password = "right" })
            local wrong = conf({ redis_host = right.redis_host, redis_password = "wrong" })
            server.fail.auth = true

            assert.is_nil(redis.get(wrong, "k"))

            server.fail.auth = false
            server.store["frontier:authn:k"] = "v"

            assert.equal("v", redis.get(right, "k"))
        end)

        it("closes the connection when the pool check fails", function()
            reset_server()
            local c = fresh_conf()
            server.fail.get_reused_times = true

            assert.is_nil(redis.get(c, "k"))
            assert.equal(1, server.closed)
            assert.equal(0, server.kept_alive)
        end)
    end)
end)
