# Kong Plugin - Frontier

Kong plugin to use with [frontier](https://github.com/raystack/frontier/) auth server.
- Can exchange browser cookies/bearer header with user token
- Inject user token in all proxy request as bearer token
- Can verify if an endpoint is allowed based on user credentials by hitting frontier check APIs

### TODO
- Add test cases
- https://github.com/lunarmodules/luacheck
- cache frontier response - https://docs.konghq.com/gateway/latest/plugin-development/entities-cache/#cache-custom-entities

### Notes
- Add plugin configuration in kong.yml file where url is a required field
```yml
plugins:
- name: frontier
  service: backend-app
  config: 
    url: http://host.docker.internal:7400/admin/v1beta1/users/self
```
- Configurable items
```
http_connect_timeout = {
    type = "number",
    default = 2000
},
http_send_timeout = {
    type = "number",
    default = 2000
},
http_read_timeout = {
    type = "number",
    default = 2000
},
header_name = {
    type = "string",
    default = "x-user-token"
},
http_method = {
    type = "string",
    default = "GET"
},
token_claims_to_append_as_headers = {
    type = "array",
    default = DEFAULT_TOKEN_HEADERS,
    elements = {
        type = "string"
    }
},
frontier_header_prefix = {
    type = "string",
    default = "X-Frontier-"
}
```
- For local development linting
```
brew install wget
brew install luarocks
luarocks install luacheck
```

- For running tests locally
Unit tests are written in [Kong Pongo](https://github.com/Kong/kong-pongo)

Installation:
```
git clone git@github.com:Kong/kong-pongo.git
PATH=$PATH:~/.local/bin
git clone https://github.com/Kong/kong-pongo.git
mkdir -p ~/.local/bin
ln -s $(realpath kong-pongo/pongo.sh) ~/.local/bin/pongo
```

Running tests:
```
pongo up
cd <root_folder_of_plugin>
pongo run ./
```

If you get a `pongo: command not found` error after installation, add the pongo binary to path with `PATH=$PATH:~/.local/bin`

### References
- https://github.com/Kong/kong-plugin
- https://docs.konghq.com/gateway/3.2.x/plugin-development/pdk/