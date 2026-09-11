# Kong Plugin - Frontier

Kong plugin to use with [frontier](https://github.com/raystack/frontier/) auth server.
- Can exchange browser cookies/bearer header with user token
- Inject user token in all proxy request as bearer token
- Can verify if an endpoint is allowed based on user credentials by hitting frontier check APIs

### TODO
- Add test cases
- https://github.com/lunarmodules/luacheck

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
request_organization_id_header = {
    type = "string",
    default = "X-Organization-Id"
},
verify_request_organization_id_header = {
    type = "boolean",
    default = false
},
disabled = {
    type = "boolean",
    default = false
}
```
### Token caching

Works on Kong 3.4 and later. It only uses modules that ship with Kong and
OpenResty, so there is nothing extra to install.

The plugin exchanges the incoming cookie or bearer for a user token on every
request. Setting `redis_host` caches that exchange in redis, so the same
credential is not exchanged again for a few seconds. The lookup is redis first,
then the auth server on a miss.

Redis is shared by every pod, so a token is fetched once for the whole fleet
rather than once per pod.

The default ttl is 5 seconds. It is deliberately short: a cached token means a
change to someone's access is not picked up until the entry expires.

**Caching needs redis.** Without `redis_host` there is nowhere to keep a token,
so `cache_ttl` does nothing on its own and every request goes to the auth
server, exactly as it did before this existed.

```yaml
plugins:
- name: frontier
  config:
    authn_url: ...
    redis_host: redis.internal
    redis_port: 6379
```

| Field | Default | What it does |
|---|---|---|
| `cache_ttl` | `5` | Seconds a token is reused for. `0` turns caching off. Max `300` |
| `cache_cookie_names` | `["sid"]` | Only these cookies go into the cache key |
| `redis_host` | unset | Setting it turns caching on |
| `redis_port` | `6379` | |
| `redis_timeout` | `100` | Milliseconds, for connect, send and read |
| `redis_username` | unset | Redis 6 ACL user, if you use one |
| `redis_password` | unset | |
| `redis_database` | `0` | |
| `redis_ssl` | `false` | |
| `redis_ssl_verify` | `false` | Needs `lua_ssl_trusted_certificate` set on the gateway |
| `redis_server_name` | unset | SNI, when using SSL |
| `redis_key_prefix` | `frontier:authn:` | Prefix on every key |
| `redis_breaker_seconds` | `10` | How long a worker stops trying after a failure |

Connections are reused through OpenResty's own connection pool, keyed by host,
port, database, user and whether SSL is on. Two plugin configs that mean the
same thing share a pool; two that differ do not. The pool is not configurable,
the same way it is not in the bundled rate limiting plugin.

The timeout default is 100ms, much lower than the bundled rate limiting
plugin's 2000ms. A healthy redis answers in well under a millisecond, so 100ms
is already a hundred times the expected latency. This sits in the auth path, so
a redis slower than that should be given up on rather than held onto. The cost
of being wrong is small: the request goes to the auth server instead, and the
worker stops trying redis for `redis_breaker_seconds`.

#### How redis behaves

**It never fails a request.** Redis is a cache, not an authority. A connect
error, a timeout, a bad reply, even a raise, is logged and the plugin carries on
to the auth server.

When a command to an instance fails, the worker stops trying that instance for
`redis_breaker_seconds`, so an outage cannot make every request pay the timeout
first. The pause is per instance, so a fault on one redis does not stop the
worker talking to another. A wrong password or a bad database index is a config
mistake rather than a broken instance, so those are logged without starting the
pause.

**Treat write access to this redis as equal to being any user.** The plugin
never checks the token signature, with or without redis. It trusts whatever the
auth server hands back. So anything that can write these keys can put a token of
its choosing in front of the upstream. The entries also hold live user tokens,
which is more sensitive than something like rate limit counters. Turn on auth
and SSL if the instance is shared or reachable from outside the cluster, and
keep `redis_key_prefix` set so the keys cannot collide with anything else using
it.

#### What it does and does not cache

- The cache key is a sha256 of the cookies named in `cache_cookie_names`, the
  authorization header, and the config that decides what an entry means:
  `authn_url`, `http_method`, `header_name`, `token_response_field` and
  `cache_ttl`. The session value is never stored in plain text, and two routes
  that would resolve a credential differently cannot share an entry.
- Only the named cookies go into the key. Browsers send analytics and consent
  cookies that change constantly, so keying on the whole cookie header would
  miss on nearly every request.
- A request with none of those credentials is never cached, so anonymous
  requests cannot share an entry.
- A failed exchange is never cached. A user who has just been given access is
  not locked out for the length of the ttl.
- The entry lives for exactly `cache_ttl`. The token is never parsed, so
  **`cache_ttl` has to stay well under your auth server's token lifetime**, or
  the cache will hand out tokens that have already expired. Frontier mints a
  fresh token on every call and its `token.validity` defaults to an hour, so
  the default of 5 seconds leaves a very wide margin. The ceiling of 300 is
  there so a careless value cannot get close.
- Only the authn call is cached. The authz check in `authz_url` still runs on
  every request.
- There is no lock, so several requests arriving together with the same new
  credential will each fetch a token. They all write an equivalent entry, and
  every request after that is served from redis.
- A token is read for its `exp` when it is stored, and for the claims that
  become headers when it is used. Nothing else about it is assumed, so a token
  that is valid JSON but is not shaped like a JWT is refused rather than half
  applied.

#### What it costs and saves

Measured against a real Frontier and a real redis, with Kong in DB-less mode.
Absolute numbers come from docker on macOS, where container networking is slow,
so read the gaps rather than the values.

One session making requests as fast as it can for 20 seconds, `cache_ttl` at 5:

| | Requests served | Auth server calls |
|---|---|---|
| Caching on | 455 | 4 |
| Caching off | 262 | 262 |

Four calls in a 20 second window is what a 5 second ttl should give. The same
client also got through 1.7 times as many requests, because it was not waiting
on an auth call every time.

Kong's own CPU per request, from the container's cgroup accounting, 500 requests
per run over one reused connection, median of 5 runs:

| | Kong CPU per request | requests/sec |
|---|---|---|
| No plugin | 0.224 ms | 293 |
| Plugin, redis hit | 0.330 ms | 264 |
| Plugin, caching off | 1.731 ms | 26 |

A redis hit costs 0.11ms more CPU than plain proxying, for the cookie parse, the
hash and the redis round trip. The auth call it replaces costs 1.5ms, about
fourteen times more.

Latency, with the plain route and the cached route interleaved to cancel drift:

| Path | Median | p95 |
|---|---|---|
| No plugin | 6.8 ms | 13.8 ms |
| Redis hit | 7.4 ms | 16.1 ms |
| Auth server fetch | 39.2 ms | 52.0 ms |

So the redis hop adds about 0.6ms and saves about 32ms.

An entry costs about 1KB in redis, for a token of roughly 950 bytes, so size it
as `users active within the ttl window x 1KB`.

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