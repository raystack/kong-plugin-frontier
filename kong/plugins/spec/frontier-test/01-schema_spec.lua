local PLUGIN_NAME = "frontier"
local schema_def = require("kong.plugins."..PLUGIN_NAME..".schema")
local v = require("spec.helpers").validate_plugin_config_schema


describe("Plugin: " .. PLUGIN_NAME .. " (schema), ", function()
    it("minimal conf validates", function()
        assert(v({ 
            authn_url = "my_auth_url"
        }, schema_def))
    end)

    it("caching defaults are applied", function()
        local ok = assert(v({
            authn_url = "my_auth_url"
        }, schema_def))

        assert.equal(5, ok.config.cache_ttl)
        assert.same({ "sid" }, ok.config.cache_cookie_names)
    end)

    it("caching can be turned off with a zero ttl", function()
        local ok = assert(v({
            authn_url = "my_auth_url",
            cache_ttl = 0
        }, schema_def))

        assert.equal(0, ok.config.cache_ttl)
    end)

    it("cache cookie names can be overridden", function()
        local ok = assert(v({
            authn_url = "my_auth_url",
            cache_cookie_names = { "sid", "other_session" }
        }, schema_def))

        assert.same({ "sid", "other_session" }, ok.config.cache_cookie_names)
    end)

    it("the cache ttl ceiling is enforced", function()
        -- nothing else keeps the cache under the auth server's token lifetime,
        -- so this bound has to hold
        assert(v({ authn_url = "my_auth_url", cache_ttl = 300 }, schema_def))

        local ok, err = v({ authn_url = "my_auth_url", cache_ttl = 301 }, schema_def)
        assert.is_nil(ok)
        assert.not_nil(err)
    end)

    it("a zero redis timeout is rejected", function()
        assert(v({ authn_url = "my_auth_url", redis_timeout = 1 }, schema_def))

        local ok, err = v({ authn_url = "my_auth_url", redis_timeout = 0 }, schema_def)
        assert.is_nil(ok)
        assert.not_nil(err)
    end)

    it("the fields the cache no longer has are gone", function()
        for _, field in ipairs({ "cache_exp_skew", "redis_keepalive_ms", "redis_pool_size" }) do
            local ok = v({ authn_url = "my_auth_url", [field] = 1 }, schema_def)
            assert.is_nil(ok, field .. " should not be accepted")
        end
    end)
end)