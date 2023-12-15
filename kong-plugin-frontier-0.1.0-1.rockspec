local plugin_name = "frontier"
local package_name = "kong-plugin-" .. plugin_name
local package_version = "0.1.0"
local rockspec_revision = "1"

local github_account_name = "raystack"
local github_repo_name = package_name

package = package_name
version = package_version .. "-" .. rockspec_revision
supported_platforms = { "linux", "macosx" }
source = {
  url = "git+https://github.com/"..github_account_name.."/"..github_repo_name..".git",
  branch = "main",
}

description = {
  summary = "Kong is a scalable and customizable API Management Layer built on top of Nginx.",
  homepage = "https://"..github_account_name..".github.io/"..github_repo_name,
  license = "Apache 2.0",
}

dependencies = {
  "lua ~> 5.1",
}

build = {
  type = "builtin",
  modules = {
    -- TODO: add any additional code files added to the plugin
    ["kong.plugins."..plugin_name..".handler"] = "kong/plugins/"..plugin_name.."/handler.lua",
    ["kong.plugins."..plugin_name..".jwt_decoder"] = "kong/plugins/"..plugin_name.."/jwt_decoder.lua",
    ["kong.plugins."..plugin_name..".schema"] = "kong/plugins/"..plugin_name.."/schema.lua",
    ["kong.plugins."..plugin_name..".access"] = "kong/plugins/"..plugin_name.."/access.lua",
    ["kong.plugins."..plugin_name..".utils"] = "kong/plugins/"..plugin_name.."/utils.lua",
  }
}