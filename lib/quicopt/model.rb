# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

# quicopt/model — the native Ruby modelling DSL and the model it builds.
#
# A +Model+ owns decision variables, an objective and constraint rows. Arithmetic
# on variables (+3 * x + 2 * y+) builds an +Expression+, and comparing two
# expressions (+x + y <= 5+) builds a +Constraint+ — neither evaluates to a number
# or a boolean.
#
# Expressions are collected as they are built: an +Expression+ is always a
# constant plus a map of linear terms plus a map of quadratic terms, never an
# unreduced operator tree. That is what makes the degree check exact — anything
# that would exceed degree 2 raises at the point of multiplication rather than
# reaching the service, per the "raise loudly, never approximate" rule the other
# clients follow.
#
# Only flat (unindexed) variables exist here. The message format also carries
# index sets and quantified constraints; the Ruby DSL deliberately does not — the
# Python and Julia clients reach those. It does carry permutations and lookup
# tables (+quicopt/structured+), whose reads enter an +Expression+ as factors of
# degree 1, alongside the variables.

module Quicopt
  # Base class of every error this gem raises.
  class Error < StandardError; end

  # An expression Quicopt cannot express, because it is neither linear nor
  # quadratic — a product of three variables, say, or a division by a variable.
  # Raised at the point of construction so the offending term is still in the
  # backtrace.
  class UnsupportedExpression < Error; end

  # Number and term rendering shared by the DSL's +to_s+ methods. Presentation
  # only — nothing here touches the wire.
  #
  # @api private
  module Format
    module_function

    # A float without its trailing +.0+ when it is whole.
    def number(value)
      return value.to_s unless value.finite?

      value == value.to_i ? value.to_i.to_s : value.to_s
    end

    # One term, dropping a unit coefficient (+x+, +-x+, +3*x+).
    def term(coefficient, factors)
      return factors if coefficient == 1.0
      return "-#{factors}" if coefficient == -1.0

      "#{number(coefficient)}*#{factors}"
    end
  end

  # The operator surface shared by +Variable+ and +Expression+.
  #
  # Every operator is written against +to_expr+, so a variable and an expression
  # behave identically. +coerce+ makes a numeric on the left work too, which is
  # what lets +3 * x+ parse: Ruby hands the multiplication back to us rather than
  # failing in +Integer#*+.
  module Operators
    # @return [Expression] +self + other+
    def +(other)
      to_expr.plus(Expression.cast(other))
    end

    # @return [Expression] +self - other+
    def -(other)
      to_expr.plus(Expression.cast(other).scale(-1.0))
    end

    # @return [Expression] +self * other+
    # @raise [UnsupportedExpression] if the product would exceed degree 2
    def *(other)
      to_expr.times(Expression.cast(other))
    end

    # Division by a numeric constant only — dividing by an expression is not a
    # polynomial, and a Quicopt model is a polynomial.
    #
    # @return [Expression] +self / divisor+
    # @raise [UnsupportedExpression] if +divisor+ is not a nonzero number
    def /(divisor)
      unless divisor.is_a?(Numeric)
        raise UnsupportedExpression,
              "cannot divide by #{divisor.class}: only division by a numeric constant is supported"
      end
      raise ZeroDivisionError, "divided by 0" if divisor.zero?

      to_expr.scale(1.0 / divisor)
    end

    # Integer powers 0, 1 and 2 only — a Quicopt model is linear or quadratic.
    #
    # @return [Expression] +self ** exponent+
    # @raise [UnsupportedExpression] on any other exponent
    def **(exponent)
      case exponent
      when 0 then Expression.new(constant: 1.0)
      when 1 then to_expr
      when 2 then to_expr.times(to_expr)
      else
        raise UnsupportedExpression,
              "exponent #{exponent.inspect} is not supported: a Quicopt model is " \
              "linear or quadratic, so the exponent must be 0, 1 or 2"
      end
    end

    # @return [Expression] the negation of +self+
    def -@
      to_expr.scale(-1.0)
    end

    # @return [Expression] +self+, unchanged
    def +@
      to_expr
    end

    # @return [Constraint] the row +self <= other+
    def <=(other)
      Constraint.build(self, other, :le)
    end

    # @return [Constraint] the row +self >= other+
    def >=(other)
      Constraint.build(self, other, :ge)
    end

    # Builds an *equality row*, not a boolean — +x == 5+ is a constraint.
    #
    # A non-numeric, non-expression operand falls back to identity, so an
    # incidental comparison (+x == nil+, +x == "x"+) still answers +false+ instead
    # of raising. Hash and Set membership are unaffected either way: they key off
    # +hash+/+eql?+, which +Variable+ defines separately.
    #
    # @return [Constraint, Boolean]
    def ==(other)
      return equal?(other) unless Expression.castable?(other)

      Constraint.build(self, other, :eq)
    end

    # Quicopt has no "not equal to" constraint, and Ruby would otherwise derive
    # +!=+ from +==+ and silently answer +false+ for every row.
    #
    # @raise [UnsupportedExpression] always, for an expression-like operand
    def !=(other)
      return !equal?(other) unless Expression.castable?(other)

      raise UnsupportedExpression,
            "!= is not a constraint Quicopt can express; model it with a binary " \
            "variable and two big-M rows"
    end

    # Lets Ruby fold a numeric on the left into an expression, so +3 * x+ and
    # +10 - x+ dispatch here instead of failing inside +Integer+/+Float+.
    #
    # @param other [Numeric]
    # @return [Array(Expression, Expression)]
    def coerce(other)
      [Expression.cast(other), to_expr]
    end
  end

  # A decision variable, owned by the +Model+ that created it.
  #
  # +index+ is the variable's position in its model; it also fixes the order of a
  # quadratic term's two factors (see +order+), so +x * y+ and +y * x+ land on the
  # same coefficient.
  class Variable
    include Operators

    # @return [Model] the model that declared this variable
    attr_reader :model
    # @return [String] the variable's name; solutions come back keyed by it
    attr_reader :name
    # @return [Symbol] +:CONTINUOUS+, +:INTEGER+ or +:BINARY+
    attr_reader :domain
    # @return [Float] the lower bound (may be +-Float::INFINITY+)
    attr_reader :lower
    # @return [Float] the upper bound (may be +Float::INFINITY+)
    attr_reader :upper
    # @return [Float] the starting point handed to the solver
    attr_reader :start
    # @return [Integer] the variable's position in its model
    attr_reader :index

    def initialize(model, name, domain, lower, upper, start, index)
      @model = model
      @name = name
      @domain = domain
      @lower = lower
      @upper = upper
      @start = start
      @index = index
      freeze
    end

    # @return [Expression] this variable as a degree-1 expression
    def to_expr
      Expression.new(linear: { self => 1.0 })
    end

    # Where this variable sorts among its model's terms: before every read of a
    # permutation or lookup table, then by +index+.
    #
    # @api private
    def order
      [0, @index]
    end

    # @return [Array<Variable>] this variable alone
    # @api private
    def variables
      [self]
    end

    # Identity equality, kept separate from +==+ (which builds a constraint) so
    # variables stay usable as Hash and Set keys.
    def eql?(other)
      equal?(other)
    end

    # Hashes by identity, to match +eql?+.
    def hash
      object_id.hash
    end

    # @return [String] the variable's name
    def to_s
      @name
    end

    # @return [String] name, domain and bounds
    def inspect
      "#<Quicopt::Variable #{@name} #{@domain} [#{@lower}, #{@upper}]>"
    end
  end

  # A polynomial of degree ≤ 2 over a model's variables, always kept in collected
  # form: +constant + Σ cᵢ·xᵢ + Σ qᵢⱼ·xᵢxⱼ+.
  #
  # A value read from a permutation (+route.item_at(0)+) or a lookup table
  # (+dist[i, j]+) counts as one factor, like a variable: +2 * dist[i, j]+ is
  # linear, +x * dist[i, j]+ quadratic.
  #
  # Instances are immutable — every operator returns a new expression — so an
  # expression can be shared, reused and stored without aliasing surprises.
  class Expression
    include Operators

    # @return [Float] the constant term
    attr_reader :constant
    # @return [Hash{Variable=>Float}] linear coefficients, in insertion order.
    #   A read of a permutation or lookup table is a key here too.
    attr_reader :linear
    # @return [Hash{Array(Variable,Variable)=>Float}] quadratic coefficients,
    #   keyed by the factor pair in model order, in insertion order
    attr_reader :quadratic

    def initialize(constant: 0.0, linear: {}, quadratic: {})
      @constant = constant.to_f
      @linear = linear.freeze
      @quadratic = quadratic.freeze
      freeze
    end

    # @return [Boolean] whether +value+ can become an expression
    def self.castable?(value)
      value.is_a?(Expression) || value.is_a?(Variable) || value.is_a?(Numeric)
    end

    # Coerce a number, variable or expression into an +Expression+.
    #
    # @raise [TypeError] for anything else
    def self.cast(value)
      case value
      when Expression then value
      when Variable then value.to_expr
      when Numeric then new(constant: value)
      else
        raise TypeError, "cannot use #{value.class} in a Quicopt expression"
      end
    end

    # @return [Expression] self
    def to_expr
      self
    end

    # @return [Integer] 0, 1 or 2 — the highest degree present
    def degree
      return 2 unless @quadratic.empty?
      return 1 unless @linear.empty?

      0
    end

    # @return [Boolean] whether this is a bare constant
    def constant?
      degree.zero?
    end

    # @return [Expression] +self + other+
    def plus(other)
      Expression.new(constant: @constant + other.constant,
                     linear: Expression.merge(@linear, other.linear),
                     quadratic: Expression.merge(@quadratic, other.quadratic))
    end

    # @return [Expression] +self+ scaled by the numeric +factor+
    def scale(factor)
      f = factor.to_f
      return Expression.new if f.zero?

      Expression.new(constant: @constant * f,
                     linear: @linear.transform_values { |c| c * f },
                     quadratic: @quadratic.transform_values { |c| c * f })
    end

    # Multiply two expressions, staying at degree 2 or below.
    #
    # A constant factor just scales; two linear factors expand into quadratic
    # terms. Anything else would exceed degree 2 and raises instead.
    #
    # @return [Expression]
    # @raise [UnsupportedExpression] if the product would exceed degree 2
    def times(other)
      return scale(other.constant) if other.constant?
      return other.scale(@constant) if constant?

      if degree > 1 || other.degree > 1
        raise UnsupportedExpression,
              "multiplying degree #{degree} by degree #{other.degree} gives a cubic or " \
              "higher term; a Quicopt model is linear or quadratic"
      end

      quadratic = {}
      @linear.each do |va, ca|
        other.linear.each do |vb, cb|
          key = Expression.pair(va, vb)
          quadratic[key] = (quadratic[key] || 0.0) + (ca * cb)
        end
      end
      Expression.new(constant: @constant * other.constant,
                     linear: Expression.merge(@linear.transform_values { |c| c * other.constant },
                                              other.linear.transform_values { |c| c * @constant }),
                     quadratic: Expression.prune(quadratic))
    end

    # Every variable this expression mentions, in first-use order — including
    # those in the positions of a lookup table read.
    #
    # @return [Array<Variable>]
    def variables
      factors.flat_map(&:variables).uniq
    end

    # Every factor of every term — variables and reads of permutations and lookup
    # tables — in first-use order.
    #
    # @return [Array<Variable, Placement, TableEntry>]
    # @api private
    def factors
      seen = @linear.keys
      @quadratic.each_key { |a, b| seen |= [a, b] }
      seen
    end

    # Renders the polynomial, e.g. +3*x + 2*y - 4+.
    def to_s
      terms = []
      terms << Format.number(@constant) unless @constant.zero?
      @linear.each { |v, c| terms << Format.term(c, v.to_s) }
      @quadratic.each { |(a, b), c| terms << Format.term(c, "#{a}*#{b}") }
      return "0" if terms.empty?

      terms.join(" + ").gsub(" + -", " - ")
    end

    # @return [String] the polynomial, tagged with the class
    def inspect
      "#<Quicopt::Expression #{self}>"
    end

    # @return [Boolean] value equality — the same constant and the same
    #   coefficient maps. Named +eq?+ because +==+ builds a constraint row.
    def eq?(other)
      other.is_a?(Expression) && @constant == other.constant &&
        @linear == other.linear && @quadratic == other.quadratic
    end

    # Sum two coefficient maps, dropping terms that cancel exactly.
    #
    # @api private
    def self.merge(left, right)
      return left.dup if right.empty?
      return right.dup if left.empty?

      out = left.dup
      right.each { |k, c| out[k] = (out[k] || 0.0) + c }
      prune(out)
    end

    # Drop exactly-zero coefficients, so a cancelled term leaves no trace on the
    # wire.
    #
    # @api private
    def self.prune(terms)
      terms.reject { |_, c| c.zero? }
    end

    # The canonical key for a quadratic term: the two factors in model order, so
    # +x*y+ and +y*x+ accumulate on one coefficient.
    #
    # @api private
    def self.pair(left, right)
      ((left.order <=> right.order) <= 0 ? [left, right] : [right, left]).freeze
    end
  end

  # One constraint row: a residual expression compared against zero.
  #
  # +expr+ is +lhs - rhs+, so the row is +expr <= 0+, +expr >= 0+ or +expr == 0+.
  # +Quicopt::Wire+ then splits that into the body (the variable terms) and the
  # numeric +bound+ (the constant, moved to the other side), which is the form
  # Quicopt sends.
  class Constraint
    # The comparison operator each sense renders as.
    SENSES = { le: "<=", ge: ">=", eq: "==" }.freeze

    # @return [Expression] the residual +lhs - rhs+
    attr_reader :expr
    # @return [Symbol] +:le+, +:ge+ or +:eq+
    attr_reader :sense

    # Build a row from the two sides of a comparison.
    def self.build(lhs, rhs, sense)
      new(Expression.cast(lhs).plus(Expression.cast(rhs).scale(-1.0)), sense)
    end

    def initialize(expr, sense)
      raise ArgumentError, "unknown constraint sense #{sense.inspect}" unless SENSES.key?(sense)

      @expr = expr
      @sense = sense
      freeze
    end

    # The row body: the variable terms alone, with the constant moved to +bound+.
    #
    # @return [Expression]
    def body
      Expression.new(linear: @expr.linear, quadratic: @expr.quadratic)
    end

    # The right-hand side after moving the constant across.
    #
    # @return [Float]
    def bound
      -@expr.constant
    end

    # Renders the row as +body <op> bound+.
    def to_s
      "#{body} #{SENSES[@sense]} #{Format.number(bound)}"
    end

    # @return [String] the row, tagged with the class
    def inspect
      "#<Quicopt::Constraint #{self}>"
    end
  end

  # An optimization model: variables, one objective, and constraint rows.
  #
  #   m = Quicopt::Model.new
  #   x = m.int_var(0, 4, "x")
  #   y = m.bin_var("y")
  #   m.maximize(3 * x + 2 * y)
  #   m.add(x + y <= 5)
  #
  # You build the model; +to_program+ / +encode+ turn it into the message the
  # service reads, and +Quicopt::Client#solve+ sends it.
  class Model
    # @return [Array<Variable>] the declared variables, in declaration order
    attr_reader :variables
    # @return [Array<Constraint>] the constraint rows, in insertion order
    attr_reader :constraints
    # @return [Expression] the objective (the zero expression until set)
    attr_reader :objective
    # @return [String] +"min"+ or +"max"+
    attr_reader :sense
    # @return [Array<Permutation>] the declared permutations, in declaration order
    attr_reader :permutations
    # @return [Array<LookupTable>] the declared lookup tables, in declaration order
    attr_reader :tables

    def initialize
      @variables = []
      @by_name = {}
      @permutations = []
      @tables = []
      @structured = {}
      @reads = 0
      @constraints = []
      @objective = Expression.new
      @sense = "min"
    end

    # Declare a continuous variable.
    #
    # @param lower [Numeric, nil] the lower bound; +nil+ means unbounded below
    # @param upper [Numeric, nil] the upper bound; +nil+ means unbounded above
    # @param name [String, nil] the variable's name; auto-generated when omitted
    # @param start [Numeric, nil] the starting point; defaults to 0 clamped into
    #   the bounds, matching the Python and Julia clients
    # @return [Variable]
    def num_var(lower = nil, upper = nil, name = nil, start: nil)
      declare(:CONTINUOUS, lower, upper, name, start)
    end

    # Declare an integer variable.
    #
    # Bounds of exactly +[0, 1]+ declare a +:BINARY+ variable rather than an
    # integer one — the same rule the Python and Julia clients apply, so the same
    # model means the same thing whichever language wrote it.
    #
    # @return [Variable]
    def int_var(lower = nil, upper = nil, name = nil, start: nil)
      lo = coerce_bound(lower, -Float::INFINITY)
      hi = coerce_bound(upper, Float::INFINITY)
      domain = lo.zero? && hi == 1.0 ? :BINARY : :INTEGER
      declare(domain, lo, hi, name, start)
    end

    # Declare a binary variable.
    #
    # @return [Variable]
    def bin_var(name = nil, start: nil)
      declare(:BINARY, 0.0, 1.0, name, start)
    end

    # Look a variable up by name.
    #
    # @return [Variable, nil]
    def variable(name)
      @by_name[name.to_s]
    end

    # Declare an order as a decision: +n+ items placed in +n+ slots, one item per
    # slot, both numbered from 0. For a route the items are the stops and the
    # slots are the visits, so slot 0 holds the first stop visited; for a machine
    # the items are the jobs and the slots the positions in its queue.
    #
    # Five stops along a road; find the shortest route through all of them that
    # visits stop 3 before stop 0:
    #
    #   position = [0, 3, 1, 4, 2]                  # km along the road, stops 0 to 4
    #   m = Quicopt::Model.new
    #   dist  = m.lookup_table("dist", position.map { |a| position.map { |b| (a - b).abs } })
    #   route = m.permutation("route", 5)
    #   route.precede(3, 0)                         # stop 3 is visited before stop 0
    #   m.minimize((0...4).sum { |k| dist[route.item_at(k), route.item_at(k + 1)] })
    #
    #   result = Quicopt::Client.new.solve(m)
    #   result.objective                            # 4.0
    #   result.structures["route"].item_at          # [3, 1, 4, 2, 0]: the stops in the order visited
    #
    # A model with a permutation is solved by a search, so its result has the
    # status +"heuristic"+.
    #
    # @param name [String, Symbol] identifies the permutation in the result, as
    #   +result.structures[name]+; shares one namespace with the model's variables
    #   and lookup tables
    # @param n [Integer] the number of items, at least 2
    # @param start [Array<Integer>, nil] the arrangement the service's search
    #   starts from: +start[i]+ is the slot of item +i+, so it holds each of
    #   +0...n+ once. Left out, item +i+ starts in slot +i+.
    # @return [Permutation]
    # @raise [TypeError] if +n+ is not an Integer
    # @raise [ArgumentError] if +n+ is below 2, the name is taken, or +start+ is
    #   not an arrangement of +0...n+
    def permutation(name, n, start: nil)
      raise TypeError, "a permutation's size is a whole number, got #{n.inspect}" unless n.is_a?(Integer)
      raise ArgumentError, "a permutation has at least 2 items, got #{n}" if n < 2

      nm = claim(name)
      unless start.nil? || (start.is_a?(Array) && start.all?(Integer) && start.sort == (0...n).to_a)
        raise ArgumentError, "permutation #{nm.inspect}: start must hold each of 0 to #{n - 1} once " \
                             "(start[i] is the slot item i starts in)"
      end
      permutation = Permutation.new(self, nm, n, start&.dup)
      @permutations << permutation
      @structured[nm] = permutation
    end

    # Declare a table of data that can be indexed by decisions. A model sometimes
    # needs a number from a table at a position that is not known yet: the distance
    # between the first and the second stop of a route whose order the service is
    # still choosing, or the price of an option an integer variable picks. A Ruby
    # array cannot be indexed this way; the table returned here can.
    #
    #   price  = m.lookup_table("price", [3.0, 1.0, 4.0, 1.5])
    #   choice = m.int_var(0, 3, "choice")
    #   m.minimize(price[choice])                   # picks option 1, at 1.0
    #
    # Indexing with whole numbers only gives the entry itself; indexing with an
    # expression, such as +Permutation#item_at+ or an integer variable, gives an
    # expression whose value is the entry at the positions the service chooses.
    #
    # The whole table is sent with the model, so a very large table makes the
    # request large.
    #
    # @param name [String, Symbol] the table's name; shares one namespace with the
    #   model's variables and permutations
    # @param values [Array<Numeric>, Array<Array<Numeric>>] a vector (indexed
    #   +table[i]+) or a matrix (+table[i, j]+, every row the same length) of
    #   numbers, none of them NaN
    # @return [LookupTable]
    # @raise [TypeError] if +values+ is neither a vector nor a matrix of numbers
    # @raise [ArgumentError] if it is empty, ragged or holds NaN, or the name is
    #   taken
    def lookup_table(name, values)
      nm = claim(name)
      data, shape = table_data(nm, values)
      table = LookupTable.new(self, nm, data, shape)
      @tables << table
      @structured[nm] = table
    end

    # The +order+ of the next read of a permutation or lookup table: after every
    # variable, then in the order the reads were first made.
    #
    # @api private
    def next_order
      [1, @reads += 1]
    end

    # Minimize +expr+.
    #
    # @return [Expression] the objective now set
    def minimize(expr)
      set_objective(expr, "min")
    end

    # Maximize +expr+.
    #
    # @return [Expression] the objective now set
    def maximize(expr)
      set_objective(expr, "max")
    end

    # Add a constraint row built by +<=+, +>=+ or +==+.
    #
    # @param constraint [Constraint]
    # @return [Constraint] the row just added
    # @raise [TypeError] if handed something that is not a constraint — most
    #   often a bare expression, or a comparison Ruby already reduced to a boolean
    def add(constraint)
      unless constraint.is_a?(Constraint)
        raise TypeError,
              "add expects a constraint such as `x + y <= 5`, got #{constraint.class}"
      end
      check_ownership(constraint.expr)
      @constraints << constraint
      constraint
    end

    # Turn this model into the structured message the service reads.
    #
    # @return [Quicopt::Modeler::V1::Program]
    def to_program
      Wire.program(self)
    end

    # Turn this model into the message the service reads and encode it.
    #
    # @return [String] binary protobuf bytes
    def encode
      Wire.encode(self)
    end

    # Renders the whole model: objective, rows, then declarations.
    def to_s
      lines = ["#{@sense} #{@objective}"]
      lines << "subject to" unless @constraints.empty?
      @constraints.each { |c| lines << "  #{c}" }
      @variables.each do |v|
        lines << "  #{v.name} in #{v.domain} [#{Format.number(v.lower)}, #{Format.number(v.upper)}]"
      end
      @permutations.each do |p|
        order = p.precedences.map { |a, b| ", #{a} before #{b}" }.join
        lines << "  #{p.name} orders items 0 to #{p.size - 1}#{order}"
      end
      @tables.each { |t| lines << "  #{t.name} is a #{t.shape.join(' × ')} lookup table" }
      lines.join("\n")
    end

    # @return [String] a one-line summary: variable and row counts
    def inspect
      "#<Quicopt::Model #{@variables.size} vars, #{@constraints.size} constraints>"
    end

    private

    def declare(domain, lower, upper, name, start)
      lo = coerce_bound(lower, -Float::INFINITY)
      hi = coerce_bound(upper, Float::INFINITY)
      raise ArgumentError, "lower bound #{lo} exceeds upper bound #{hi}" if lo > hi

      nm = name.nil? ? auto_name : name.to_s
      raise ArgumentError, "duplicate variable name #{nm.inspect}" if @by_name.key?(nm)
      raise ArgumentError, "the name #{nm.inspect} is already declared on this model" if @structured.key?(nm)

      variable = Variable.new(self, nm, domain, lo, hi, coerce_start(start, lo, hi), @variables.size)
      @variables << variable
      @by_name[nm] = variable
      variable
    end

    def coerce_bound(value, default)
      return default if value.nil?
      raise ArgumentError, "bound must be a number, got #{value.class}" unless value.is_a?(Numeric)

      value.to_f
    end

    # 0 clamped into the bounds — finite for any bounds, matching the Python and
    # Julia clients so an unset start comes out the same everywhere.
    def coerce_start(start, lower, upper)
      return [[0.0, lower].max, upper].min if start.nil?
      raise ArgumentError, "start must be a number, got #{start.class}" unless start.is_a?(Numeric)

      start.to_f
    end

    def auto_name
      n = @variables.size + 1
      n += 1 while @by_name.key?("x#{n}") || @structured.key?("x#{n}")
      "x#{n}"
    end

    # +name+ as a String, checked to be free among the model's variables,
    # permutations and lookup tables: on the wire one name must mean one thing.
    def claim(name)
      unless name.is_a?(String) || name.is_a?(Symbol)
        raise TypeError, "a name is a String or a Symbol, got #{name.inspect}"
      end

      nm = name.to_s
      raise ArgumentError, "a name cannot be empty" if nm.empty?
      if @by_name.key?(nm) || @structured.key?(nm)
        raise ArgumentError, "the name #{nm.inspect} is already declared on this model"
      end

      nm
    end

    # A table's entries as frozen Floats, and its shape.
    def table_data(name, values)
      raise TypeError, "lookup table #{name.inspect}: values is an Array, got #{values.class}" unless values.is_a?(Array)
      raise ArgumentError, "lookup table #{name.inspect} has no entries" if values.empty?

      if values.all?(Numeric)
        data = values.map(&:to_f)
        shape = [data.size]
        flat = data
      elsif values.all?(Array)
        unless values.all? { |row| row.all?(Numeric) }
          raise TypeError, "lookup table #{name.inspect}: a matrix holds numbers only"
        end
        if values.first.empty? || values.any? { |row| row.size != values.first.size }
          raise ArgumentError, "lookup table #{name.inspect}: every row of a matrix has the same, " \
                               "nonzero number of entries"
        end
        data = values.map { |row| row.map(&:to_f).freeze }
        shape = [data.size, data.first.size]
        flat = data.flatten
      else
        raise TypeError, "lookup table #{name.inspect}: values is a vector or a matrix of numbers"
      end
      raise ArgumentError, "lookup table #{name.inspect} holds NaN" if flat.any?(&:nan?)

      [data.freeze, shape]
    end

    def set_objective(expr, sense)
      objective = Expression.cast(expr)
      check_ownership(objective)
      @objective = objective
      @sense = sense
      objective
    end

    # Reject variables, permutations and tables belonging to another model: their
    # names would collide arbitrarily and their coefficients would silently merge
    # on the wire.
    def check_ownership(expr)
      expr.factors.each do |f|
        next if f.model.equal?(self)

        what = f.is_a?(Variable) ? "variable #{f.name.inspect}" : f.to_s
        raise ArgumentError, "#{what} belongs to a different Quicopt::Model"
      end
    end
  end
end
