# quicopt

[![Gem](https://img.shields.io/gem/v/quicopt.svg)](https://rubygems.org/gems/quicopt)
[![Ruby 3.2+](https://img.shields.io/badge/ruby-3.2%2B-CC342D.svg)](https://rubygems.org/gems/quicopt)
[![Docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://quicopt.github.io/quicopt-ruby/)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A Ruby client for the [Quicopt](https://quicopt.com) optimization service.

You describe a decision: what you get to choose, what has to hold, and what you
want as much (or as little) of as possible. Quicopt finds the best choice there is.

The gem does three things: it lets you write that description in plain Ruby, packs
it into a compact message, and sends it to the service, which solves it and sends
the answer back. It is the Ruby counterpart of the Python and Julia clients, and
all three send the same message — so the same model gets the same answer whichever
language wrote it.

There is no solver on your machine. The service does the solving.

## Documentation

- **[API reference](https://quicopt.github.io/quicopt-ruby/)** — every public class
  and method, with examples.
- [`Quicopt::Model`](https://quicopt.github.io/quicopt-ruby/Quicopt/Model.html) —
  variables, constraints, objective.
- [`Quicopt::Permutation`](https://quicopt.github.io/quicopt-ruby/Quicopt/Permutation.html)
  and [`Quicopt::LookupTable`](https://quicopt.github.io/quicopt-ruby/Quicopt/LookupTable.html) —
  orders as decisions, and data read along them.
- [`Quicopt::Client`](https://quicopt.github.io/quicopt-ruby/Quicopt/Client.html) —
  sending a model, API keys, long-running jobs, errors.
- [`Quicopt::Result`](https://quicopt.github.io/quicopt-ruby/Quicopt/Result.html) —
  what comes back.

## Install

```ruby
gem "quicopt"
```

or

```sh
gem install quicopt
```

Ruby 3.2 or newer. The only library it needs at runtime is `google-protobuf`;
requests go out over Ruby's built-in `net/http`.

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

## A first realistic example: Sourcing & Procurement

Suppose you are running a webshop for electronic parts. A customer wants to order 200 *resistor packs*, 150 *terminal blocks* and 95 *sensor modules*. You have three suppliers (*Nordwind*, *BitBazaar* and *CircuitCellar*) who each offer all of these parts at different price tags. We can express this as

```ruby
parts  = %w[resistor_pack terminal_block sensor_module]
demand = { "resistor_pack" => 200, "terminal_block" => 150, "sensor_module" => 95 }

suppliers = %w[Nordwind BitBazaar CircuitCellar]
price = {
  ["Nordwind",      "resistor_pack"] => 1.00, ["BitBazaar",     "terminal_block"] => 1.50, ["CircuitCellar", "sensor_module"] => 2.90,
  ["BitBazaar",     "resistor_pack"] => 1.15, ["Nordwind",      "terminal_block"] => 1.90, ["Nordwind",      "sensor_module"] => 3.30,
  ["CircuitCellar", "resistor_pack"] => 1.30, ["CircuitCellar", "terminal_block"] => 2.10, ["BitBazaar",     "sensor_module"] => 3.50,
}
```
So far, so simple. Each supplier also has shipping fees as well as a "free-shipping threshold", which we can write as
```ruby
ship_fee   = { "Nordwind" => 40.0,  "BitBazaar" => 40.0,  "CircuitCellar" => 40.0 }
free_above = { "Nordwind" => 300.0, "BitBazaar" => 300.0, "CircuitCellar" => 300.0 }
```
It's obvious what to order where, right? Picking the cheapest option for each part, we pay
```ruby
demand["resistor_pack"]  * price[["Nordwind",      "resistor_pack"]]  +
demand["terminal_block"] * price[["BitBazaar",     "terminal_block"]] +
demand["sensor_module"]  * price[["CircuitCellar", "sensor_module"]]  +
ship_fee.values.sum # == 820.5
```
Let's check what a professional optimization solver has to say - we have `Quicopt` at hand:
```ruby
# new model
m = Quicopt::Model.new
```

### Variables

```ruby
# empty hash literal to hold "quantity of part p ordered from supplier s"
order_qty = {}

# order quantities: integers with lower bounds 0 and no (nil) upper bounds
suppliers.each { |s| parts.each { |p| order_qty[[s, p]] = m.int_var(0, nil, "x_#{s}_#{p}") } }

# binary usage variables: are we using supplier s?
use = suppliers.to_h { |s| [s, m.bin_var("use_#{s}")]  }

# binary free-shipping variables: have we ordered enough to qualify?
free = suppliers.to_h { |s| [s, m.bin_var("free_#{s}")] }

# define a helper expression (sum over price times order quantity)
cart_value = suppliers.to_h { |s| [s, parts.sum { |p| price[[s, p]] * order_qty[[s, p]] }] }
```

### Constraints & Objective

```ruby
# demand satisfaction: a constraint to enforce that the ordered quantity is AT LEAST the demand
parts.each { |p| m.add(suppliers.sum { |s| order_qty[[s, p]] } >= demand[p]) }

# introduce a "large" number to enfore a so-called "big-M" constraint
big = demand.values.sum * 2
# => as soon as order_qty is NOT zero, use is forced to one
suppliers.each { |s| parts.each { |p| m.add(order_qty[[s, p]] <= big * use[s]) } }

# free-shipping binaries must be zero when use is zero
suppliers.each { |s| m.add(free[s] <= use[s]) }

# since free occurs with a minus in the objective below,
# it will be set to one if not forced to zero as long as free_above is not cleared
suppliers.each { |s| m.add(free_above[s] * free[s] <= cart_value[s]) }

# our cost objective function to be minimized
# the shipping fee is not charged if both use and free are one
m.minimize(suppliers.sum { |s| cart_value[s] + ship_fee[s] * (use[s] - free[s]) })
```
Now all we have to do is to send this to the Quicopt API service:
```ruby
# get the results from the API service
result = Quicopt::Client.new.solve(m)

# inspect the result
puts result.display
```

```
▄▀▀▀▄        ▄                     █
█   █ █   █ ▄▄  ▄▀▀▀▄ ▄▀▀▀▄ █▀▀▀▄ ▀█▀▀
█ ▀▄▀ █   █  █  █   ▄ █   █ █▄▄▄▀  █  ▄
 ▀▀ ▀  ▀▀▀▀ ▀▀▀  ▀▀▀   ▀▀▀  █       ▀▀
├── status:     optimal
├── feasible:   true
├── objective:  733.35
├── x:          free_BitBazaar=1, free_CircuitCellar=1, free_Nordwind=0, use_BitBazaar=1, use_CircuitCellar=1, use_Nordwind=0, …  (15 variables)
└── solve_time: 0.0497 s
```
But wait, it says `objective: 733.35`! We have *saved* `87.15`, or more than 10%! How have we achieved that? The solver gave us `use_Nordwind=0`, i.e. we are *not* using *Nordwind* at all. Looking at the other variables via `puts result.solution`, we find
```ruby
"x_BitBazaar_resistor_pack"     => 181.0,
"x_CircuitCellar_resistor_pack" => 19.0
```
So we aren't buying *any* resistor packs at the *cheapest* supplier! The catch is, of course, that splitting the resistor packs in this way, we save the shipping fees *twice*. While one could still figure this out on a piece of paper for this small example, that does not scale to real scenarios. `Quicopt` does: try it out on [quicopt.com](https://quicopt.com).


## Building a model

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
rule the Python and Julia clients apply, so the same model means the same thing
whichever language wrote it.

### Expressions

`+`, `-`, `*`, `/` and `**` build expressions, and a number may sit on either
side:

```ruby
3 * x + 2 * y - 4
(x + 1) * (y + 2)      # quadratic
z**2                   # quadratic
x / 2                  # division by a constant
```

Like terms are collected as you write them — a constant, plus linear terms, plus
quadratic terms — so `x * y` and `y * x` are the same term, and `x - x` is zero.

Only linear and quadratic expressions exist. Anything beyond that raises where you
wrote it, rather than being silently dropped or approximated:

```ruby
x * y * z    # Quicopt::UnsupportedExpression — that would be cubic
x / y        # Quicopt::UnsupportedExpression — you can only divide by a number
x**3         # Quicopt::UnsupportedExpression — exponents are 0, 1 or 2
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
- `!=` is not a constraint Quicopt can express, so it raises rather than quietly
  answering `false`.
- A number on the left works (`5 <= x`), because Ruby hands the comparison back
  to the expression. `5 == x`, however, is Ruby's own `Integer#==` and is just
  `false` — write `x == 5`.

Chained comparisons (`1 <= x <= 5`) are not a thing in Ruby. Add two rows.

## Choosing an order

Some decisions are orders: the route a van drives through its stops, or the sequence in which a machine works through its jobs. Declare such an order with `permutation`, and read data along it with a lookup table. Here are five stops along a road; find the shortest route through all of them that visits stop 3 before stop 0:

```ruby
position = [0, 3, 1, 4, 2]                    # km along the road, stops 0 to 4

m = Quicopt::Model.new
dist  = m.lookup_table("dist", position.map { |a| position.map { |b| (a - b).abs } })
route = m.permutation("route", 5)
route.precede(3, 0)                           # stop 3 is visited before stop 0
m.minimize((0...4).sum { |k| dist[route.item_at(k), route.item_at(k + 1)] })

result = Quicopt::Client.new.solve(m)
result.objective                              # 4.0
result.structures["route"].item_at            # [3, 1, 4, 2, 0]: the stops in the order visited
```

A permutation places `n` items in `n` slots, one item per slot, both counted from 0. Here the items are the stops and the slots are the visits, so slot 0 holds the first stop visited:

- `route.item_at(k)` is the stop in slot `k`: `route.item_at(0)` is the first stop visited.
- `route.slot_of(i)` is the slot of stop `i`: when it is visited.
- `route.precede(a, b)` requires stop `a` to be visited before stop `b`. Every solution meets every such requirement.
- `start:` gives the order the service's search starts from: `m.permutation("route", 5, start: [4, 3, 2, 1, 0])` starts with stop 0 in slot 4, stop 1 in slot 3, and so on.

The result holds each permutation's order both ways round, again counted from 0: `item_at`, the item in each slot, and `slot_of`, the slot of each item. Orders are found by a search, which cannot prove that no better order exists, so a model with a permutation comes back with the status `"heuristic"`.

A Ruby array cannot be indexed by a decision the service has not made yet, such as which stop comes first; a lookup table can. `dist[route.item_at(k), route.item_at(k + 1)]` is the length of the leg from the `k`-th stop to the next, whichever stops those turn out to be. A table is a vector, indexed `table[i]`, or a matrix, indexed `table[i, j]`. Indexed by whole numbers only, it gives the entry itself (`dist[0, 1]` is `3.0`). It can also be indexed by an integer variable, to read the entry the service picks:

```ruby
m = Quicopt::Model.new
price  = m.lookup_table("price", [3.0, 1.0, 4.0, 1.5])
choice = m.int_var(0, 3, "choice")
m.minimize(price[choice])

result = Quicopt::Client.new.solve(m)
result.solution                               # {"choice" => 1.0}: option 1 is the cheapest
result.objective                              # 1.0
```

A value read from a permutation or a table counts as one factor in an expression, like a variable: `2 * dist[i, j]` is linear and `x * dist[i, j]` is quadratic. The whole table is sent with the model, so a very large table makes the request large.

## The encoded model

`solve` encodes the model for you, but the encoded form is not hidden. Inspect it,
store it, or send it by some other route:

```ruby
bytes   = m.encode          # the message itself: protobuf bytes, ready to POST
program = m.to_program      # the same content as a structured object you can read
Quicopt.decode(bytes)       # bytes back into that object

Quicopt::Client.new.solve(bytes)   # solve an already-encoded model
```

The message format is a [protobuf](https://protobuf.dev) schema,
`proto/quicopt/modeler/v1/program.proto`, vendored in this repository; `gen/gen.sh`
regenerates the Ruby classes from it. The Python and Julia clients send that same
format, which is what makes a model portable between them.

One caveat if you ever compare two encoded models: protobuf omits fields that hold
their default value and does not fix the order of map entries, so two encodings of
the same model can differ byte for byte while meaning exactly the same thing.
Compare decoded models, never the raw bytes.

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

**Time limit.** The service chooses how long a solve may run. `time_limit:` sets that time instead, in seconds. A solver that proves its answer sooner still stops sooner; a search, which cannot prove it is done, runs for all of it:

```ruby
result = client.solve(m, time_limit: 30)
result.solver_data["time_budget_s"]    # 30.0: the time the service granted
```

The service grants at most its maximum (120 s on the free tier). Asked for more, it runs for its maximum, and the client warns that the solve got less time than requested. `submit` takes `time_limit:` too, and `job.result` then waits at least that long.

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
gen/gen.sh              # regenerate the protobuf classes after a schema change
```

The client tests run against a real local HTTP server rather than a stubbed
`Net::HTTP`, so the whole request path — headers, query encoding, gzip framing, key
capture, the error path — is covered end to end.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
