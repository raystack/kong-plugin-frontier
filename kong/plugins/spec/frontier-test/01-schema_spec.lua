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
end)