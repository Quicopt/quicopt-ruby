# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

# quicopt/indicators — terms that switch: whether a variable is in use
# (+Variable#active+), whether a comparison holds (+Quicopt.holds+), and the
# smaller or larger of several expressions (+Quicopt.min+, +Quicopt.max+).
#
# None of them is a polynomial, and each enters an +Expression+ the way a read of
# a permutation does (+quicopt/structured+): as one factor of degree 1, a key of
# the expression's linear terms. So +fee * x.active+ is linear, +q * x.active+
# quadratic, and the degree check stays exact.
#
# Factors are interned per model — asking twice for the same term returns the
# same object — so +x.active - x.active+ cancels and two equal terms meet on one
# coefficient. A comparison is mapped to its 0/1 form once, in +Quicopt.holds+,
# the same mapping as the R client's +holds()+:
#
#   a <= b  ⇒  step(b − a + tol)          a >= b  ⇒  step(a − b + tol)
#   a <  b  ⇒  1 − step(a − b − tol)      a >  b  ⇒  1 − step(b − a − tol)
#   a == b  ⇒  1 − indicator(a − b)       a != b  ⇒  indicator(a − b)
#
# where +step(e)+ is 1 when +e ≥ 0+ and +indicator(e)+ is 1 when +e ≠ 0+; with a
# tolerance, +==+ and +!=+ compare +|a − b|+ against it instead.

module Quicopt
  class << self
    # 1 where the comparison holds and 0 where it does not, as an expression the
    # service evaluates at the values it chooses. Its main use is a cost or a
    # discount that applies once a total crosses a level: a warehouse's opening
    # fee, due once it ships anything, is
    #
    #   opening_fee * Quicopt.holds(shipped >= 1)
    #
    # and a discount of 30 from 60 units on is +-30 * Quicopt.holds(shipped >= 60)+.
    #
    # @param comparison [Constraint] built with +<=+, +>=+, +<+, +>+, +==+ or
    #   +!=+ between expressions, such as +shipped >= 60+
    # @param tol [Numeric] how far a comparison may miss and still count as
    #   holding: +a >= b+ holds from +a = b − tol+ on, +a > b+ from
    #   <tt>a > b + tol</tt>. Non-negative.
    # @return [Expression] a 0/1 expression; a number when the comparison
    #   involves no decision
    # @raise [TypeError] if +comparison+ is not a comparison — often one Ruby
    #   already reduced to +true+ or +false+ because both sides were numbers
    # @raise [ArgumentError] if +tol+ is negative, or the two sides belong to
    #   different models
    def holds(comparison, tol: 0.0)
      unless comparison.is_a?(Constraint)
        raise TypeError, "holds takes a comparison such as `x >= 3`, got #{comparison.inspect}"
      end
      raise ArgumentError, "tol is a non-negative number, got #{tol.inspect}" unless tol.is_a?(Numeric) && tol >= 0

      Conditions.holds(comparison.expr, comparison.sense, tol.to_f)
    end

    # The smallest of the given expressions, as an expression the service
    # evaluates. <tt>fee * Quicopt.min(1, a.active + b.active)</tt> is a fee
    # that is due once, however many of +a+ and +b+ are in use.
    #
    # @param args [Array<Expression, Variable, Numeric>] at least two
    # @return [Expression] a number when every argument is one
    # @raise [ArgumentError] on fewer than two arguments, or arguments from
    #   different models
    def min(*args)
      Extremum.build(:min, args)
    end

    # The largest of the given expressions, as an expression the service
    # evaluates.
    #
    # @param args [Array<Expression, Variable, Numeric>] at least two
    # @return [Expression] a number when every argument is one
    # @raise [ArgumentError] on fewer than two arguments, or arguments from
    #   different models
    def max(*args)
      Extremum.build(:max, args)
    end
  end

  # The mapping from a comparison to its 0/1 form, and the model a term belongs
  # to.
  #
  # @api private
  module Conditions
    module_function

    # +residual+ is +lhs − rhs+; the result follows the table in this file's
    # header.
    def holds(residual, sense, tol)
      return Expression.new(constant: truth(residual.constant, sense, tol) ? 1.0 : 0.0) if residual.constant?

      negated = residual.scale(-1.0)
      case sense
      when :le then term(:step, negated.plus(Expression.new(constant: tol)))
      when :ge then term(:step, residual.plus(Expression.new(constant: tol)))
      when :lt then one_minus(term(:step, residual.plus(Expression.new(constant: -tol))))
      when :gt then one_minus(term(:step, negated.plus(Expression.new(constant: -tol))))
      when :eq then tol.positive? ? term(:near, residual, tol) : one_minus(term(:indicator, residual))
      when :ne then tol.positive? ? one_minus(term(:near, residual, tol)) : term(:indicator, residual)
      end
    end

    # Whether a comparison between two numbers (<tt>value = lhs − rhs</tt>) holds.
    def truth(value, sense, tol)
      case sense
      when :le then -value + tol >= 0
      when :ge then value + tol >= 0
      when :lt then (value - tol).negative?
      when :gt then (-value - tol).negative?
      when :eq then tol.positive? ? value.abs <= tol : value.zero?
      when :ne then tol.positive? ? value.abs > tol : !value.zero?
      end
    end

    # The interned +Condition+ +op+ over +argument+, as an expression.
    def term(op, argument, tol = 0.0)
      model = owner(argument.factors)
      key = [:condition, op, argument_key(argument), tol]
      Expression.new(linear: { model.intern(key) { Condition.new(model, op, argument, tol, model.next_order) } => 1.0 })
    end

    # +1 − e+.
    def one_minus(expr)
      Expression.new(constant: 1.0).plus(expr.scale(-1.0))
    end

    # The one model every factor in +factors+ belongs to.
    #
    # @raise [ArgumentError] if they belong to more than one
    def owner(factors)
      models = factors.map(&:model).uniq(&:object_id)
      raise ArgumentError, "the terms of one expression belong to different Quicopt::Models" if models.size > 1

      models.first
    end

    # An expression as an interning key: its constant and its terms in model
    # order. Factors are interned, so they key by identity.
    def argument_key(expr)
      [expr.constant, expr.linear.sort_by { |f, _| f.order }, expr.quadratic.sort_by { |(a, b), _| [a.order, b.order] }]
    end
  end

  # A 0/1 term: +indicator(e)+ (1 when +e ≠ 0+), +step(e)+ (1 when +e ≥ 0+) or
  # the near test +step(tol − |e|)+. One factor of an +Expression+.
  #
  # @api private
  class Condition
    # @return [Model]
    attr_reader :model
    # @return [Symbol] +:indicator+, +:step+ or +:near+
    attr_reader :op
    # @return [Expression] the expression tested
    attr_reader :argument
    # @return [Float] the tolerance of +:near+, 0 otherwise
    attr_reader :tol
    # @return [Array] where this term sorts among a model's terms
    attr_reader :order

    def initialize(model, op, argument, tol, order)
      @model = model
      @op = op
      @argument = argument
      @tol = tol
      @order = order
      freeze
    end

    # @return [Array<Variable>] the variables the tested expression mentions
    def variables
      @argument.variables
    end

    # @return [String] the term as sent, e.g. <tt>step(x + y - 1)</tt>; the
    #   indicator of a bare variable reads +x.active+
    def to_s
      bare = @argument.constant.zero? && @argument.quadratic.empty? && @argument.linear.size == 1 &&
             @argument.linear.first[0].is_a?(Variable) && @argument.linear.first[1] == 1.0
      case @op
      when :indicator then bare ? "#{@argument}.active" : "indicator(#{@argument})"
      when :step then "step(#{@argument})"
      when :near then "step(#{Format.number(@tol)} - |#{@argument}|)"
      end
    end
  end

  # The smaller or the larger of several expressions. One factor of an
  # +Expression+.
  #
  # @api private
  class Extremum
    # @return [Model]
    attr_reader :model
    # @return [Symbol] +:min+ or +:max+
    attr_reader :op
    # @return [Array<Expression>] the arguments, in the order given
    attr_reader :args
    # @return [Array] where this term sorts among a model's terms
    attr_reader :order

    # The interned +op+ over +args+ as an expression, or the number itself when
    # every argument is one.
    def self.build(op, args)
      raise ArgumentError, "#{op} takes at least two arguments, got #{args.size}" if args.size < 2

      exprs = args.map { |a| Expression.cast(a) }
      if exprs.all?(&:constant?)
        values = exprs.map(&:constant)
        return Expression.new(constant: op == :min ? values.min : values.max)
      end
      model = Conditions.owner(exprs.flat_map(&:factors))
      key = [:extremum, op, exprs.map { |e| Conditions.argument_key(e) }]
      Expression.new(linear: { model.intern(key) { new(model, op, exprs.freeze, model.next_order) } => 1.0 })
    end

    def initialize(model, op, args, order)
      @model = model
      @op = op
      @args = args
      @order = order
      freeze
    end

    # @return [Array<Variable>] the variables the arguments mention
    def variables
      @args.flat_map(&:variables).uniq
    end

    # @return [String] the term as written, e.g.
    #   <tt>min(1, a.active + b.active)</tt>
    def to_s
      "#{@op}(#{@args.join(', ')})"
    end
  end
end
