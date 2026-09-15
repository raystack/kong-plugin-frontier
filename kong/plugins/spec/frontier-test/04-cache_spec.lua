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

local function conf(overrides)
    local c = {
        authn_url = "http://frontier/v1beta1/auth/token",
        cache_ttl = 5,
        cache_cookie_names = { "sid" },
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

        it("parses a value exactly the way frontier does", function()
            -- go's net/http trims the pair and the name but keeps whatever
            -- follows the `=`, so a value with a leading space is a different
            -- credential and has to stay a different cache key
            assert.same({ "abc" }, utils.parse_cookies("  sid =abc  ").sid)
            assert.same({ " abc" }, utils.parse_cookies("  sid = abc  ").sid)
            assert.same({ " abc" }, utils.parse_cookies("sid= abc").sid)
            assert.same({ "  abc" }, utils.parse_cookies("sid=  abc  ").sid)
            assert.same({ "a b c" }, utils.parse_cookies("sid=a b c").sid)
            assert.same({ "" }, utils.parse_cookies("sid=").sid)
            assert.same({ "a=b" }, utils.parse_cookies("sid=a=b").sid)
        end)

        it("strips surrounding quotes, as go does", function()
            assert.same({ "quoted" }, utils.parse_cookies('sid="quoted"').sid)
            assert.same({ "" }, utils.parse_cookies('sid=""').sid)
            assert.same({ " abc " }, utils.parse_cookies('sid=" abc "').sid)
        end)

        it("drops a value holding a byte go would reject", function()
            -- go drops the whole cookie, so keeping it would make our key
            -- disagree with the session frontier actually sees
            assert.is_nil(utils.parse_cookies('sid="').sid)
            assert.is_nil(utils.parse_cookies('sid="a"b"').sid)
            assert.is_nil(utils.parse_cookies("sid=a\\b").sid)
            assert.is_nil(utils.parse_cookies("sid=ab\tcd").sid)
            assert.is_nil(utils.parse_cookies("sid=caf\xc3\xa9").sid)
        end)

        it("the recipe is pinned, so changing it forces a version bump", function()
            -- every pod shares these keys, so during a rollout two plugin
            -- versions read each other's entries. If this value changes, bump
            -- ENTRY_FORMAT_VERSION in cache.lua and update it here
            local pinned = {
                authn_url = "http://auth.test/AuthToken",
                http_method = "POST",
                header_name = "x-user-token",
                token_response_field = "access_token",
                cache_ttl = 5,
                cache_cookie_names = { "sid" }
            }

            assert.equal("m0rQX7ob88P9M0tTpourWk93bnvOoio9E1qp-UvHqo4",
                cache.build_key(pinned, "sid=abc", nil))
        end)

        it("a leading space makes a different cache key", function()
            local plain = cache.build_key(conf(), "sid=abc", nil)
            local spaced = cache.build_key(conf(), "sid= abc", nil)

            assert.not_equal(plain, spaced)
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
            local c = cache.build_key(conf({ cache_ttl = 300 }), "sid=abc", nil)
            assert.not_equal(a, b)
            assert.not_equal(a, c)
            assert.not_equal(b, c)
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

        it("stores for exactly the configured ttl", function()
            reset()
            local c = conf()
            local fetch = auth_server("tok")
            local key = cache.build_key(c, "sid=plain-ttl", nil)

            cache.get(c, key, fetch)
            assert.equal(c.cache_ttl, store[key].ttl)
        end)

        it("stores an opaque token the same way", function()
            -- the token is never parsed here, so one that is not a jwt at all
            -- is stored and served like any other
            reset()
            local c = conf()
            local fetch, fetched = auth_server("not-a-jwt")
            local key = cache.build_key(c, "sid=opaque", nil)

            assert.equal("not-a-jwt", cache.get(c, key, fetch))
            assert.equal("not-a-jwt", cache.get(c, key, fetch))
            assert.equal(1, fetched())
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
end)
