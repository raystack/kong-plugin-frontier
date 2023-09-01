local typedefs = require "kong.db.schema.typedefs"
local PLUGIN_NAME = "frontier"

-- https://github.com/Kong/kong-plugin/blob/master/kong/plugins/myplugin/schema.lua
local schema = {
    name = PLUGIN_NAME,
    fields = {{
        consumer = typedefs.no_consumer
    }, {
        config = {
            type = "record",
            fields = {{
                http_connect_timeout = {
                    type = "number",
                    default = 2000
                }
            }, {
                http_send_timeout = {
                    type = "number",
                    default = 2000
                }
            }, {
                http_read_timeout = {
                    type = "number",
                    default = 2000
                }
            }, {
                header_name = {
                    type = "string",
                    default = "x-user-token"
                }
            }, {
                authn_url = {
                    type = "string",
                    required = true
                }
            }, {
                http_method = {
                    type = "string",
                    default = "POST"
                }
            }, {
                authz_url = {
                    type = "string"
                }
            }, {
                rule = {
                    type = "record",
                    fields = {{
                        namespace = {
                            type = "string"
                        }
                    }, {
                        id = {
                            type = "string"
                        }
                    }, {
                        methods = {
                            type = "array",
                            elements = {
                                type = "string"
                            }
                        }
                    }}
                }
            }}
        }
    }}
}

return schema
