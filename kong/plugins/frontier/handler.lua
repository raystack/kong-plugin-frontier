local plugin = {
    VERSION = "0.1.0",
    PRIORITY = 900
}
local access = require "kong.plugins.frontier.access"

-- Executed for every request from a client and before it is being proxied to the upstream service.
function plugin:access(config)
    access.run(config)
end

-- return the created table, so that Kong can execute it
return plugin
