local PLUGIN_NAME = "frontier"
local schema_def = require("kong.plugins."..PLUGIN_NAME..".schema")
local v = require("spec.helpers").validate_plugin_config_schema


describe("Plugin: " .. PLUGIN_NAME .. " (schema), ", function()
    it("minimal conf validates", function()
        assert(v({ 
            authn_url = "my_auth_url"
        }, schema_def))
    end)
end)