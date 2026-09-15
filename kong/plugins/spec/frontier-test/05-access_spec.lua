local PLUGIN_NAME = "frontier"

-- access.lua makes an http call and talks to kong, so both are stubbed here.
-- These tests cover what the plugin does with the token it gets back, which
-- matters more now that a token can come out of a shared redis.

local function b64url(input)
    return (ngx.encode_base64(input, true):gsub("%+", "-"):gsub("/", "_"))
end

local function token_with_payload(payload)
    return b64url('{"alg":"RS256","typ":"JWT"}') .. "." .. b64url(payload) .. ".sig"
end

local function token_with_header(header)
    return b64url(header) .. "." .. b64url('{"sub":"u1"}') .. ".sig"
end

local function base_conf()
    return {
        disabled = false,
        http_connect_timeout = 2000,
        http_send_timeout = 2000,
        http_read_timeout = 2000,
        header_name = "x-user-token",
        authn_url = "http://auth.test/AuthToken",
        http_method = "POST",
        token_response_field = "accessToken",
        correlation_header_name = "X-Request-Id",
        override_authz_header = false,
        token_claims_to_append_as_headers = { "sub", "org_ids", "user_id" },
        frontier_header_prefix = "X-Frontier-",
        request_organization_id_header = "X-Organization-Id",
        verify_request_organization_id_header = false,
        -- caching off, so these tests exercise the token handling only
        cache_ttl = 0
    }
end

-- runs the plugin against an auth server and reports what reached the upstream.
-- `answer` is either a token the server hands back in a 200, or a table
-- describing the raw reply so the failure paths can be driven.
local function run_plugin(conf, answer, request_headers)
    local result = { set = {}, cleared = {}, status = nil, exit_headers = nil }

    local reply, reply_err
    if type(answer) == "table" then
        reply, reply_err = answer.response, answer.err
    else
        reply = {
            status = 200,
            headers = {},
            body = '{"' .. conf.token_response_field .. '":"' .. answer .. '"}'
        }
    end

    package.loaded["resty.http"] = {
        new = function()
            return {
                set_timeouts = function() end,
                request_uri = function()
                    return reply, reply_err
                end
            }
        end
    }

    local exited = {}

    _G.kong = {
        log = {
            debug = function() end,
            info = function() end,
            warn = function() end,
            err = function() end
        },
        request = {
            get_header = function(name)
                return request_headers[string.lower(name)]
            end,
            get_headers = function()
                return request_headers
            end,
            get_method = function()
                return "GET"
            end
        },
        service = {
            request = {
                set_header = function(name, value)
                    -- kong itself rejects anything else, and rejecting it here
                    -- too is what makes a function value show up as a failure
                    local t = type(value)
                    if t ~= "string" and t ~= "number" and t ~= "boolean" then
                        error("invalid header value for " .. name .. ": got " .. t)
                    end
                    result.set[name] = value
                end,
                clear_header = function(name)
                    result.cleared[#result.cleared + 1] = name
                end
            }
        },
        response = {
            exit = function(status, _, headers)
                result.status = status
                result.exit_headers = headers
                -- kong ends the request here, so nothing after it runs
                error(exited)
            end
        }
    }

    for _, mod in ipairs({ "access", "cache", "utils", "jwt_decoder" }) do
        package.loaded["kong.plugins." .. PLUGIN_NAME .. "." .. mod] = nil
    end

    local access = require("kong.plugins." .. PLUGIN_NAME .. ".access")

    local ok, err = pcall(access.run, conf)
    if not ok and err ~= exited then
        result.raised = err
    end

    return result
end


describe("Plugin: " .. PLUGIN_NAME .. " (access), ", function()
    describe("claims to headers", function()
        it("appends the claims the token has", function()
            local token = token_with_payload('{"sub":"u1","org_ids":"o1,o2"}')
            local out = run_plugin(base_conf(), token, {})

            assert.is_nil(out.raised)
            assert.equal("u1", out.set["X-Frontier-sub"])
            assert.equal("o1,o2", out.set["X-Frontier-org_ids"])
            -- the token has no user_id, so no header is invented for it
            assert.is_nil(out.set["X-Frontier-user_id"])
            assert.equal(token, out.set["x-user-token"])
        end)

        it("refuses a token whose payload is a json string", function()
            -- indexing a lua string does not fail, it hands back the matching
            -- function from the string library. `sub` is one of them and is in
            -- the default claim list, so this used to set a header to a
            -- function value and fail the request with a 500
            local out = run_plugin(base_conf(), token_with_payload('"just a string"'), {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
            assert.is_nil(out.set["X-Frontier-sub"])
        end)

        it("refuses a token whose payload is a number", function()
            local out = run_plugin(base_conf(), token_with_payload("1"), {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
        end)

        it("passes a json array payload through with no claim headers", function()
            -- an array is a table, so it cannot be told apart from an object
            -- that simply has none of the configured claims, which is a real
            -- case. It is forwarded with no identity headers rather than
            -- refused, and the upstream sees a request that claims nothing
            local out = run_plugin(base_conf(), token_with_payload("[1,2]"), {})

            assert.is_nil(out.raised)
            assert.is_nil(out.status)
            assert.is_nil(out.set["X-Frontier-sub"])
            assert.is_nil(out.set["X-Frontier-org_ids"])
        end)

        it("refuses a token whose header is not an object", function()
            -- jwt_parser reads header.alg without checking the header's type,
            -- so this raised inside the decoder. A cached token can come from
            -- anywhere with write access to the cache, so a raise here would
            -- have been a 500 on a request carrying a valid credential.
            for _, header in ipairs({ "1", "null", "true" }) do
                local out = run_plugin(base_conf(), token_with_header(header), {})

                assert.is_nil(out.raised)
                assert.equal(401, out.status)
                assert.is_nil(out.set["X-Frontier-sub"])
            end
        end)

        it("refuses a token that does not decode at all", function()
            local out = run_plugin(base_conf(), "not-a-jwt", {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
        end)
    end)

    describe("what the auth server answers", function()
        it("a 200 with no token in it gives a 401, not a 500", function()
            -- the one behaviour change in this work. it used to pass nil into
            -- set_header and fail with `invalid header value ... got nil`
            local out = run_plugin(base_conf(), { response = { status = 200, headers = {}, body = "{}" } }, {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
            assert.is_nil(out.set["x-user-token"])
        end)

        it("a 200 with an empty body gives a 401", function()
            local out = run_plugin(base_conf(), { response = { status = 200, headers = {}, body = "" } }, {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
        end)

        it("a 200 whose body names a different field gives a 401", function()
            local out = run_plugin(base_conf(),
                { response = { status = 200, headers = {}, body = '{"some_other_field":"tok"}' } }, {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
        end)

        it("a 401 is passed on as a 401 carrying the upstream status", function()
            local out = run_plugin(base_conf(), { response = { status = 401, headers = {}, body = "" } }, {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
            assert.equal(401, out.exit_headers["x-upstream-status"])
        end)

        it("a 500 from the auth server becomes a 401 carrying the upstream status", function()
            local out = run_plugin(base_conf(), { response = { status = 500, headers = {}, body = "" } }, {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
            assert.equal(500, out.exit_headers["x-upstream-status"])
        end)

        it("an unreachable auth server gives a 401 with no upstream status", function()
            local out = run_plugin(base_conf(), { response = nil, err = "connection refused" }, {})

            assert.is_nil(out.raised)
            assert.equal(401, out.status)
            assert.is_nil(out.exit_headers)
        end)

        it("the token can come back in a header instead of the body", function()
            local token = token_with_payload('{"sub":"u1"}')
            local out = run_plugin(base_conf(),
                { response = { status = 200, headers = { ["x-user-token"] = token }, body = "{}" } }, {})

            assert.is_nil(out.raised)
            assert.is_nil(out.status)
            assert.equal(token, out.set["x-user-token"])
        end)
    end)

    describe("organization id header", function()
        it("keeps a header the token's org_ids claim allows", function()
            local conf = base_conf()
            conf.verify_request_organization_id_header = true

            local out = run_plugin(conf, token_with_payload('{"sub":"u1","org_ids":"o1,o2"}'),
                { ["x-organization-id"] = "o2" })

            assert.is_nil(out.raised)
            assert.is_nil(out.status)
            assert.same({}, out.cleared)
        end)

        it("drops a header the token's org_ids claim does not allow", function()
            local conf = base_conf()
            conf.verify_request_organization_id_header = true

            local out = run_plugin(conf, token_with_payload('{"sub":"u1","org_ids":"o1"}'),
                { ["x-organization-id"] = "other" })

            assert.is_nil(out.raised)
            assert.same({ "X-Organization-Id" }, out.cleared)
        end)

        it("drops the header when the token has no org_ids claim", function()
            -- a missing claim used to reach string.gmatch as nil and fail the
            -- request with a 500. A claim we cannot read is one we cannot
            -- verify against, so the header goes
            local conf = base_conf()
            conf.verify_request_organization_id_header = true

            local out = run_plugin(conf, token_with_payload('{"sub":"u1"}'),
                { ["x-organization-id"] = "o1" })

            assert.is_nil(out.raised)
            assert.same({ "X-Organization-Id" }, out.cleared)
        end)
    end)
end)
