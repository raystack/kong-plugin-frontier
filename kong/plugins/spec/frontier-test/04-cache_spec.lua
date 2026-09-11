local PLUGIN_NAME = "frontier"

-- cache.lua logs through kong and takes its reference to both kong and the
-- redis module at load time, so both are set up before it is required.
_G.kong = _G.kong or {
    log = {
        debug = function() end,
        info = function() end,
        warn = function() end,
        err = function() end
    }
}

-- Reaching a real redis needs a cosocket, which only works inside a request, so
-- a table stands in for it.
local store = {}
local calls = { get = 0, set = 0 }
local raise_on = {}

package.loaded["kong.plugins." .. PLUGIN_NAME .. ".redis"] = {
    enabled = function(conf)
        return conf.redis_host ~= nil and conf.redis_host ~= ""
    end,

    get = function(_, key)
        calls.get = calls.get + 1

        if raise_on.get then
            error("redis blew up")
        end

        local entry = store[key]
        if not entry then
            return nil
        end

        -- expire the way redis would
        if entry.expires_at <= ngx.now() then
            store[key] = nil
            return nil
        end

        return entry.value
    end,

    set = function(_, key, value, ttl)
        calls.set = calls.set + 1

        if raise_on.set then
            error("redis blew up")
        end

        store[key] = { value = value, ttl = ttl, expires_at = ngx.now() + ttl }
    end
}

local cache = require("kong.plugins."..PLUGIN_NAME..".cache")
local utils = require("kong.plugins."..PLUGIN_NAME..".utils")
local jwt_parser = require "kong.plugins.jwt.jwt_parser"
local pkey = require "resty.openssl.pkey"

local signing_key = assert(pkey.new({ type = "RSA", bits = 2048 }))

local function token_expiring_in(seconds)
    return assert(jwt_parser.encode({
        sub = "u1",
        exp = ngx.time() + seconds
    }, signing_key:to_PEM("private"), "RS256"))
end

local function b64(input)
    return (ngx.encode_base64(input, true):gsub("%+", "-"):gsub("/", "_"))
end

local function conf(overrides)
    local c = {
        authn_url = "http://frontier/v1beta1/auth/token",
        cache_ttl = 5,
        cache_cookie_names = { "sid" },
        cache_exp_skew = 2,
        redis_host = "127.0.0.1",
        redis_port = 6379,
        redis_timeout = 100,
        redis_database = 0,
        redis_key_prefix = "frontier:authn:test:",
        redis_breaker_seconds = 10
    }
    for k, val in pairs(overrides or {}) do
        c[k] = val
    end
    return c
end

local function reset()
    store = {}
    calls.get, calls.set = 0, 0
    raise_on.get, raise_on.set = nil, nil
end

-- an auth server that hands back `token` and counts how often it was asked
local function auth_server(token, err)
    local count = 0
    return function()
        count = count + 1
        return token, err
    end, function()
        return count
    end
end


describe("Plugin: " .. PLUGIN_NAME .. " (cache), ", function()

    describe("parse_cookies", function()
        it("reads a name to values table", function()
            local jar = utils.parse_cookies("sid=abc; _ga=GA1.2.3; consent=yes")
            assert.same({ "abc" }, jar.sid)
            assert.same({ "GA1.2.3" }, jar._ga)
            assert.same({ "yes" }, jar.consent)
        end)

        it("returns an empty table when there is no header", function()
            assert.same({}, utils.parse_cookies(nil))
        end)

        it("keeps every occurrence of a repeated name, in order", function()
            local jar = utils.parse_cookies("sid=first; other=x; sid=second")
            assert.same({ "first", "second" }, jar.sid)
            assert.same({ "x" }, jar.other)
        end)

        it("trims surrounding spaces", function()
            assert.same({ "abc" }, utils.parse_cookies("  sid = abc  ").sid)
        end)
    end)

    describe("build_key", function()
        it("ignores cookies that are not in cache_cookie_names", function()
            local a = cache.build_key(conf(), "sid=abc; _ga=1", nil)
            local b = cache.build_key(conf(), "sid=abc; _ga=999; theme=dark", nil)
            assert.equal(a, b)
        end)

        it("changes when the session changes", function()
            local a = cache.build_key(conf(), "sid=abc", nil)
            local b = cache.build_key(conf(), "sid=xyz", nil)
            assert.not_equal(a, b)
        end)

        it("separates two routes pointing at different auth servers", function()
            local a = cache.build_key(conf(), "sid=abc", nil)
            local b = cache.build_key(conf({ authn_url = "http://other/token" }), "sid=abc", nil)
            assert.not_equal(a, b)
        end)

        it("keys on the authorization header too", function()
            local a = cache.build_key(conf(), nil, "Bearer one")
            local b = cache.build_key(conf(), nil, "Bearer two")
            assert.not_equal(a, b)
            assert.not_nil(a)
        end)

        it("returns nil when there is no credential, so anonymous requests never share an entry", function()
            assert.is_nil(cache.build_key(conf(), "_ga=1; theme=dark", nil))
            assert.is_nil(cache.build_key(conf(), nil, nil))
            assert.is_nil(cache.build_key(conf(), "sid=", ""))
        end)

        it("does not leak the session value into the key", function()
            local key = cache.build_key(conf(), "sid=supersecretsession", nil)
            assert.is_nil(key:find("supersecretsession", 1, true))
        end)

        it("two headers that authenticate differently cannot share a key", function()
            -- frontier walks every cookie it is sent and acts on the last `sid`
            -- that decodes. A stale undecodable cookie shared by everyone must
            -- not collapse two users onto one entry, so every occurrence is in
            -- the key.
            local a = cache.build_key(conf(), "sid=USER_A; sid=STALE", nil)
            local b = cache.build_key(conf(), "sid=USER_B; sid=STALE", nil)
            assert.not_equal(a, b)
        end)

        it("order of repeated cookies changes the key", function()
            local a = cache.build_key(conf(), "sid=ONE; sid=TWO", nil)
            local b = cache.build_key(conf(), "sid=TWO; sid=ONE", nil)
            assert.not_equal(a, b)
        end)

        it("includes the fields that decide which value is read out", function()
            local base = cache.build_key(conf(), "sid=abc", nil)
            assert.not_equal(base, cache.build_key(conf({ token_response_field = "accessToken" }), "sid=abc", nil))
            assert.not_equal(base, cache.build_key(conf({ header_name = "x-other" }), "sid=abc", nil))
            assert.not_equal(base, cache.build_key(conf({ http_method = "GET" }), "sid=abc", nil))
        end)

        it("a different cache_ttl is a different entry", function()
            -- otherwise a route with a short window can be handed an entry a
            -- neighbouring route cached for much longer
            local a = cache.build_key(conf({ cache_ttl = 5 }), "sid=abc", nil)
            local b = cache.build_key(conf({ cache_ttl = 2.5 }), "sid=abc", nil)
            local c = cache.build_key(conf({ cache_ttl = 3600 }), "sid=abc", nil)
            assert.not_equal(a, b)
            assert.not_equal(a, c)
            assert.not_equal(b, c)
        end)

        it("a different cache_exp_skew is a different entry", function()
            assert.not_equal(
                cache.build_key(conf({ cache_exp_skew = 2 }), "sid=abc", nil),
                cache.build_key(conf({ cache_exp_skew = 30 }), "sid=abc", nil))
        end)

        it("the order cookie names are listed in does not matter", function()
            assert.equal(
                cache.build_key(conf({ cache_cookie_names = { "sid", "other" } }), "sid=abc; other=1", nil),
                cache.build_key(conf({ cache_cookie_names = { "other", "sid" } }), "sid=abc; other=1", nil))
        end)
    end)

    describe("get", function()
        it("asks the auth server once, then serves from redis", function()
            reset()
            local c = conf()
            local fetch, fetched = auth_server("tok")
            local key = cache.build_key(c, "sid=user-a", nil)

            assert.equal("tok", cache.get(c, key, fetch))
            for _ = 1, 5 do
                assert.equal("tok", cache.get(c, key, fetch))
            end

            assert.equal(1, fetched())
            assert.equal(1, calls.set)
        end)

        it("stores the token with the configured ttl", function()
            reset()
            local c = conf()
            local fetch = auth_server("tok")
            local key = cache.build_key(c, "sid=user-b", nil)

            cache.get(c, key, fetch)
            assert.equal("tok", store[key].value)
            assert.equal(5, store[key].ttl)
        end)

        it("asks again once the entry has expired", function()
            reset()
            local c = conf()
            local fetch, fetched = auth_server("tok")
            local key = cache.build_key(c, "sid=user-c", nil)

            cache.get(c, key, fetch)
            cache.get(c, key, fetch)
            assert.equal(1, fetched())

            -- let the entry age out the way redis would drop it
            store[key].expires_at = ngx.now() - 1

            cache.get(c, key, fetch)
            assert.equal(2, fetched())
        end)

        it("does not store a failure", function()
            reset()
            local c = conf()
            local fetch, fetched = auth_server(nil, "no dice")
            local key = cache.build_key(c, "sid=rejected", nil)

            local token, err = cache.get(c, key, fetch)
            assert.is_nil(token)
            assert.equal("no dice", err)

            -- a second request asks again, so somebody who has just been
            -- granted access is not locked out for the window
            assert.is_nil(cache.get(c, key, fetch))
            assert.equal(2, fetched())
            assert.equal(0, calls.set)
        end)

        it("does not touch redis when there is no credential to key on", function()
            reset()
            local c = conf()
            local fetch, fetched = auth_server("tok")

            assert.equal("tok", cache.get(c, nil, fetch))
            assert.equal("tok", cache.get(c, nil, fetch))

            assert.equal(2, fetched())
            assert.equal(0, calls.get)
            assert.equal(0, calls.set)
        end)

        it("goes straight to the auth server when redis is not configured", function()
            reset()
            local c = conf()
            c.redis_host = nil
            local fetch, fetched = auth_server("tok")
            local key = cache.build_key(c, "sid=user-d", nil)

            assert.equal("tok", cache.get(c, key, fetch))
            assert.equal("tok", cache.get(c, key, fetch))

            assert.equal(2, fetched())
            assert.equal(0, calls.get)
        end)

        it("does not store a token with nothing left after the skew", function()
            reset()
            local c = conf()
            -- exp is cache_exp_skew away, so the clamp leaves nothing
            local token = token_expiring_in(c.cache_exp_skew)
            assert.is_true(cache.ttl_for(c, token) <= 0)

            local fetch, fetched = auth_server(token)
            local key = cache.build_key(c, "sid=nearly-dead", nil)

            assert.equal(token, cache.get(c, key, fetch))
            assert.equal(token, cache.get(c, key, fetch))

            assert.equal(2, fetched())
            assert.equal(0, calls.set)
        end)

        it("does not store an already expired token", function()
            reset()
            local c = conf()
            local fetch = auth_server(token_expiring_in(-60))

            cache.get(c, cache.build_key(c, "sid=expired", nil), fetch)
            assert.equal(0, calls.set)
        end)

        it("stores with the expiry clamped to the token", function()
            reset()
            local c = conf()
            local fetch = auth_server(token_expiring_in(4))
            local key = cache.build_key(c, "sid=short-lived", nil)

            cache.get(c, key, fetch)
            -- about 4 - 2 = 2, to the fraction
            assert.is_true(store[key].ttl > 1 and store[key].ttl <= 2)
        end)

        it("a redis read that raises falls through to the auth server", function()
            reset()
            raise_on.get = true
            local c = conf()
            local fetch, fetched = auth_server("tok")

            assert.equal("tok", cache.get(c, cache.build_key(c, "sid=user-e", nil), fetch))
            assert.equal(1, fetched())
        end)

        it("a redis write that raises does not fail the request", function()
            reset()
            raise_on.set = true
            local c = conf()
            local fetch = auth_server("tok")

            assert.equal("tok", cache.get(c, cache.build_key(c, "sid=user-f", nil), fetch))
        end)
    end)

    describe("ttl_for", function()
        it("uses the configured ttl for an opaque token", function()
            assert.equal(5, cache.ttl_for(conf(), "not-a-jwt"))
        end)

        it("keeps the configured ttl when the token outlives it", function()
            assert.equal(5, cache.ttl_for(conf(), token_expiring_in(10)))
        end)

        it("clamps to the token expiry, minus the skew", function()
            -- sub second, because the clamp works to the fraction so an entry
            -- cannot outlive the token it holds
            local ttl = cache.ttl_for(conf(), token_expiring_in(4))
            assert.is_true(ttl > 1 and ttl <= 2)
        end)

        it("is not positive for a token that is already gone", function()
            assert.is_true(cache.ttl_for(conf(), token_expiring_in(-60)) <= 0)
        end)
    end)

    describe("hostile input", function()
        -- anything with write access to the cache can put a value in it, so a
        -- malformed entry must not raise. Under the old node cache a raise came
        -- back as a cache error and turned into a 401 for a valid credential.
        local function jwt_with(header, payload)
            return b64(header) .. "." .. b64(payload) .. ".signature"
        end

        it("a payload that is not an object does not raise", function()
            for _, payload in ipairs({ "1", "null", '"a string"', "[1,2]", "{}", "not json" }) do
                local ok, ttl = pcall(cache.ttl_for, conf(), jwt_with('{"alg":"RS256"}', payload))
                assert.is_true(ok)
                assert.is_true(type(ttl) == "number")
            end
        end)

        it("a header that is not an object does not raise", function()
            -- jwt_parser reads header.alg without checking the header's type,
            -- so these raise inside it
            for _, header in ipairs({ "1", "null", "true", '"a string"', "[1]", "{}" }) do
                local ok, ttl = pcall(cache.ttl_for, conf(), jwt_with(header, '{"sub":"u1"}'))
                assert.is_true(ok)
                assert.is_true(type(ttl) == "number")
            end
        end)

        it("a token that cannot be read is still usable, just not trusted for its expiry", function()
            assert.equal(5, cache.ttl_for(conf(), jwt_with("1", '{"exp":1}')))
            assert.equal(5, cache.ttl_for(conf(), "not-a-jwt"))
        end)
    end)
end)
