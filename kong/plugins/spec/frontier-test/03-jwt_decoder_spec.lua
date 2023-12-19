local PLUGIN_NAME = "frontier"
local decoder = require("kong.plugins."..PLUGIN_NAME..".jwt_decoder")

describe("Plugin: " .. PLUGIN_NAME .. " (decoder), ", function()
    describe("Success", function()
        it("successfully decodes JWT", function()
            local token = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImxjN29RV25SNFFoOE5Yal9VeGVKbWROTGJkX0RkNHVSZUxBMWVmUGZPZkUiLCJ0eXAiOiJKV1QifQ.eyJleHAiOjE3MDA1NTE2MTUsImdlbiI6InN5c3RlbSIsImlhdCI6MTcwMDU0ODAxNSwiaXNzIjoiZnJvbnRpZXIiLCJqdGkiOiIyM2I0MjA4Yi1mMThhLTQ3MmUtYTkyZS00YzRjZDQzYThlNDUiLCJraWQiOiJsYzdvUVduUjRRaDhOWGpfVXhlSm1kTkxiZF9EZDR1UmVMQTFlZlBmT2ZFIiwibmJmIjoxNzAwNTQ4MDE1LCJvcmdfaWRzIjoiNjc4MDE0MzItZDExNS00YTAzLTlmYjAtODM5MzQxYzU2NjMyIiwic3ViIjoiOGI0ZWRlNDYtYWQ5YS00ZTNiLTlkNjMtMjI2MzIyNjc5MDIzIn0.zGcC_iO1ht6hAyBLvWB2P_aXm57KSKOPhngqJjZHNdEEcy_cmNHeos8EB9h3tU6gNdX0dmJpUjZOkGbdA6hV1nZhEyoeeH8zBSdyTjyy3t2X376dDFzULGbbGXKOsPB6E9YwwJ6HtL_UYjVWqsuMKgHcyVA_lyR2tMqqToTYooMsGsTQKddT7p3lRHfkyUhAhaqBtUOOW_Qu8FnR3a60eXN5SUDmT8K864eqgjGw2xDkjMUF5NY6wX1ahIORhDiYjYyWm5onlWMQGkn_ugKuFX0Vs7EbD6Ur9YN7wO4kw2dazIRtGYvICmZgp92oofatfN43bDtR59ljYFf5k45KyA"
            local res, err = decoder.decode_token(token)

            assert.equal(nil, err)
            assert.is.truthy(res["claims"])
        end)
    end)
end)


