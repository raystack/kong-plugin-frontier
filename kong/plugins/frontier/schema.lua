local typedefs = require "kong.db.schema.typedefs"
local PLUGIN_NAME = "frontier"

local DEFAULT_TOKEN_HEADERS = {
    "sub",
    "org_ids",
    "sub_type",
    "sid",
    "user_id"
}

local DEFAULT_CACHE_COOKIE_NAMES = {
    "sid"
}

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
                    default = 2000,
                    between = { 1, 60000 }
                }
            }, {
                http_send_timeout = {
                    type = "number",
                    default = 2000,
                    between = { 1, 60000 }
                }
            }, {
                http_read_timeout = {
                    type = "number",
                    default = 2000,
                    between = { 1, 60000 }
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
                override_authz_header = {
                    type = "boolean",
                    default = true
                }
            }, {
                token_claims_to_append_as_headers = {
                    type = "array",
                    default = DEFAULT_TOKEN_HEADERS,
                    elements = {
                        type = "string"
                    }
                }
            }, {
                frontier_header_prefix = {
                    type = "string",
                    default = "X-Frontier-"
                }
            }, {
                request_organization_id_header = {
                    type = "string",
                    default = "X-Organization-Id"
                }
            }, {
                verify_request_organization_id_header = {
                    type = "boolean",
                    default = false
                }
            }, {
                disabled = {
                    type = "boolean",
                    default = false
                }
            }, {
                token_response_field = {
                    type = "string",
                    default = "accessToken"
                }
            }, {
                correlation_header_name = {
                    type = "string",
                    default = "X-Request-Id"
                }
            }, {
                -- how long a fetched user token is reused for, in seconds.
                -- Kept short so that an access change is picked up quickly.
                -- Set to 0 to turn caching off. Caching needs redis_host set;
                -- without it there is nowhere to keep a token and every request
                -- goes to the auth server.
                --
                -- The token is never read for its own expiry, so this has to
                -- stay well under the auth server's token lifetime. Frontier
                -- mints a fresh token per call and defaults to an hour, so the
                -- 300 ceiling leaves a wide margin.
                cache_ttl = {
                    type = "number",
                    default = 5,
                    between = { 0, 300 }
                }
            }, {
                -- only these cookies go into the cache key. Browsers send many
                -- other cookies that change often, and keying on all of them
                -- would miss on nearly every request. `sid` is the cookie
                -- frontier uses for the session.
                cache_cookie_names = {
                    type = "array",
                    default = DEFAULT_CACHE_COOKIE_NAMES,
                    elements = {
                        type = "string"
                    }
                }

            }, {
                -- setting a host turns caching on. Leave it unset and every
                -- request goes to the auth server.
                redis_host = typedefs.host
            }, {
                redis_port = typedefs.port({
                    default = 6379
                })
            }, {
                -- deliberately much lower than the bundled rate limiting
                -- plugin's 2000ms. A healthy redis answers in well under a
                -- millisecond, and this sits in the auth path, so a slow one
                -- should be given up on quickly in favour of the auth server.
                redis_timeout = {
                    type = "number",
                    default = 100,
                    between = { 1, 10000 }
                }
            }, {
                redis_username = {
                    type = "string",
                    referenceable = true
                }
            }, {
                redis_password = {
                    type = "string",
                    len_min = 0,
                    referenceable = true
                }
            }, {
                redis_database = {
                    type = "integer",
                    default = 0,
                    between = { 0, 15 }
                }
            }, {
                redis_ssl = {
                    type = "boolean",
                    default = false
                }
            }, {
                redis_ssl_verify = {
                    type = "boolean",
                    default = false
                }
            }, {
                redis_server_name = typedefs.sni
            }, {
                -- prefix on every key, so this cannot collide with anything
                -- else sharing the same redis
                redis_key_prefix = {
                    type = "string",
                    default = "frontier:authn:"
                }
            }, {
                -- after a redis failure a worker stops trying for this long, so
                -- a redis outage cannot make every request pay the timeout
                redis_breaker_seconds = {
                    type = "number",
                    default = 10,
                    between = { 0, 600 }
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
