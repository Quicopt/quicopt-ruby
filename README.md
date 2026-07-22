# quicopt

A Ruby client for the Quicopt optimization service.

It does exactly three things: author an optimization model in a small native Ruby
DSL, encode it to the versioned Quicopt wire IR, and send it to the service. It is
the Ruby peer of the Python and Julia clients — the same wire contract, the same
results.

There is no local solver here. The service does the solving.

## Install

```ruby
gem "quicopt"
```

or

```sh
gem install quicopt
```

Ruby 3.2 or newer. The only runtime dependency is `google-protobuf`; the transport
is stdlib `net/http`.

## Quick start

```ruby
require "quicopt"

m = Quicopt::Model.new
x = m.int_var(0, 4, "x")
y = m.bin_var("y")
z = m.num_var(0, 10, "z")

m.maximize(3 * x + 2 * y + z)
m.add(x + y <= 5)

result = Quicopt::Client.new.solve(m)
puts result.display
```

`result.display` is rendered by the service and ready to print — the same summary
for every kind of model. The structured fields are there too:

```ruby
result.status              # "optimal", "heuristic", …
result.objective           # Float, or nil where the outcome leaves it undefined
result.feasible            # true / false / nil
result.solution            # {"x" => 4.0, "y" => 1.0, "z" => 10.0}
result.solve_time_seconds
```

## The model

### Variables

```ruby
m.num_var(0, 10, "z")     # continuous
m.int_var(0, 4, "x")      # integer
m.bin_var("y")            # binary
m.num_var(nil, nil, "w")  # free: unbounded in both directions
```

The name is optional and generated when omitted, but solutions come back keyed by
it, so naming your variables is worth it. `start:` sets the initial point; it
defaults to 0 clamped into the bounds.

Integer variables with bounds of exactly `[0, 1]` are declared binary — the same
normalisation the other clients apply, so one model reaches the service as one
program whichever language authored it.

### Expressions

`+`, `-`, `*`, `/` and `**` build expressions, and a number may sit on either
side:

```ruby
3 * x + 2 * y - 4
(x + 1) * (y + 2)      # quadratic
z**2                   # quadratic
x / 2                  # division by a constant
```

Expressions are normalised as they are built — a constant plus linear terms plus
quadratic terms — so `x * y` and `y * x` are the same term, and `x - x` is zero.

Only linear and quadratic expressions exist. Anything beyond that raises at the
point you write it, rather than being silently dropped or approximated:

```ruby
x * y * z    # Quicopt::UnsupportedExpression: exceeds the quadratic subset
x / y        # Quicopt::UnsupportedExpression: division by a variable
x**3         # Quicopt::UnsupportedExpression
```

### Constraints

`<=`, `>=` and `==` build constraint rows, not booleans:

```ruby
m.add(x + y <= 5)
m.add(2 * x - z >= -1)
m.add(x + z == 3)
```

Two consequences of that, both deliberate:

- `x == 5` is a row. Comparing a variable to something that could never be part
  of an expression (`x == nil`) still answers `false`, and variables remain
  usable as Hash and Set keys, but do not expect `==` to test equality.
- `!=` has no wire form and raises rather than quietly answering `false`.
- A number on the left works (`5 <= x`), because Ruby hands the comparison back
  to the expression. `5 == x`, however, is Ruby's own `Integer#==` and is just
  `false` — write `x == 5`.

Chained comparisons (`1 <= x <= 5`) are not a thing in Ruby. Add two rows.

## Working with the wire bytes

The encoded program is not hidden. Inspect it, cache it, or route it yourself:

```ruby
bytes   = m.encode          # binary protobuf, ready to POST
program = m.to_program      # the structured wire IR
Quicopt.decode(bytes)       # back to a program

Quicopt::Client.new.solve(bytes)   # solve pre-encoded bytes directly
```

The wire schema is `proto/quicopt/modeler/v1/program.proto`, vendored in this
repository; `gen/gen.sh` regenerates the codec from it.

Note that the generated codec omits zero-valued scalars and does not canonicalize
field order, so two encodings of the same model are *decode-equivalent* rather
than byte-identical. Compare decoded programs, never hex.

## The client

```ruby
client = Quicopt::Client.new                       # the public free tier
client = Quicopt::Client.new("http://localhost:8137")
client = Quicopt::Client.new(url, "my-api-key", timeout: 120)
```

**Keys.** The first call without a key mints one, cached at
`$XDG_CACHE_HOME/quicopt/free_key` (`~/.cache/…` by default) and replayed as a
bearer token on every later call — including from later runs, so you keep one key
without doing anything. A key you passed in is used as-is, never cached and never
overwritten; `Quicopt::Client.new(url, cache: false)` keeps the minted key in
memory only.

Where the home directory does not survive the run (CI, containers), the cache is
wiped between sessions and each run mints a new key. Set `QUICOPT_KEY_PATH` to a
durable location — or `Client.new(url, key_path: …)` — to keep one key across
sessions.

**Per-project tagging.** `solve(model, project: "atlas")` tags the call so usage on
one key can be attributed per project. It rides the query string and is never
baked into the model.

**Large models.** `solve(model, gzip: true)` compresses the request body.

**Asynchronous solving.** Use this for the first call against a server that may
still be warming up, where a blocking call could time out:

```ruby
job = client.submit(m)
job.status                       # {"status" => "running", …}
result = job.result              # polls until done
job.log                          # the framed log view
job.delete                       # remove the job and its stored data
```

**Errors.** A non-2xx response raises `Quicopt::QuicoptError`, which carries a
stable machine-readable `reason` — match on that, not on the message:

```ruby
begin
  client.solve(m)
rescue Quicopt::QuicoptError => e
  puts e.display                 # ready-to-print, server-rendered
  retry if e.reason == "queue_busy"
  raise
end
```

Everything this gem raises descends from `Quicopt::Error`.

## Development

```sh
bundle install
bundle exec rake        # run the tests
gen/gen.sh              # regenerate the codec after a schema change
```

The client tests run against a real local HTTP server rather than a stubbed
`Net::HTTP`, so the transport — headers, query encoding, gzip framing, key
capture, the error path — is covered end to end.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
