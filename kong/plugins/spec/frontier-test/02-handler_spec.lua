local PLUGIN_NAME = "frontier"
local helpers = require "spec.helpers"
local cjson   = require "cjson"

for _, strategy in helpers.each_strategy() do
    describe("Plugin: " .. PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
        local client

        lazy_setup(function()
            local bp = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })
            local route1 = bp.routes:insert({
                hosts = { "test1.com" },
        })
        local route2 = bp.routes:insert({
            hosts = { "test2.com" },
        })
        bp.plugins:insert {
            name = PLUGIN_NAME,
            route = { id = route1.id },
            config = {
            authn_url = "my_sample_url"
            },
        }
        bp.plugins:insert {
            name = PLUGIN_NAME,
            route = { id = route2.id },
            config = {
                authn_url = "my_sample_url"
            },
        }
        -- start kong
        assert(helpers.start_kong({
            -- set the strategy
            database   = strategy,
            -- use the custom test template to create a local mock server
            nginx_conf = "spec/fixtures/custom_nginx.template",
            -- make sure our plugin gets loaded
            plugins = "bundled," .. PLUGIN_NAME,
        }))
        end)

        lazy_teardown(function()
            helpers.stop_kong(nil, true)
        end)

        before_each(function()
            client = helpers.proxy_client()
        end)

        after_each(function()
            if client then client:close() end
        end)

        describe("Basic", function()
            it("a request when no authorization header is passed", function()
            local res = assert(client:send {
                method  = "GET",
                path    = "/status/200",
                headers = {
                ["Host"] = "test1.com",
                ["Authorization"] = "",
                }
            })
            local body = assert.res_status(401, res)
            local json = cjson.decode(body)
            print(json)
            assert.equal("unauthorized", json["message"])
            end)
        end)
    end)
end