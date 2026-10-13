# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "test_helper"

# The DSL: what the operators build, and what they refuse to build.
class ModelTest < Minitest::Test
  def setup
    @m = Quicopt::Model.new
    @x = @m.int_var(0, 4, "x")
    @y = @m.bin_var("y")
    @z = @m.num_var(0, 10, "z")
  end

  # ── expressions ───────────────────────────────────────────────────────────

  def test_linear_expression_normalises_terms
    e = (3 * @x) + (2 * @y) + @z
    assert_equal 1, e.degree
    assert_equal 0.0, e.constant
    assert_equal [3.0, 2.0, 1.0], e.linear.values
    assert_equal [@x, @y, @z], e.linear.keys
  end

  def test_numeric_on_the_left_coerces
    assert (3 * @x).eq?(@x * 3)
    assert (10 - @x).eq?((-1 * @x) + 10)
    assert_equal 1, (5 + @x).degree
    assert_equal 5.0, (5 + @x).constant
  end

  def test_repeated_terms_accumulate
    e = @x + @x + (2 * @x)
    assert_equal({ @x => 4.0 }, e.linear)
  end

  def test_cancelling_terms_leave_no_trace
    e = @x - @x
    assert_equal 0, e.degree
    assert_empty e.linear
    assert_equal 0.0, e.constant
  end

  def test_quadratic_factors_are_order_independent
    e = (@x * @y) + (@y * @x)
    assert_equal 2, e.degree
    assert_equal 1, e.quadratic.size
    assert_equal 2.0, e.quadratic.values.first
  end

  def test_square_lands_on_the_diagonal
    assert_equal({ [@z, @z] => 1.0 }, (@z**2).quadratic)
    assert (@z**2).eq?(@z * @z)
  end

  def test_expansion_of_a_product_of_sums
    e = (@x + 1) * (@y + 2)          # xy + 2x + y + 2
    assert_equal 2.0, e.constant
    assert_equal({ @x => 2.0, @y => 1.0 }, e.linear)
    assert_equal({ [@x, @y] => 1.0 }, e.quadratic)
  end

  def test_division_by_a_constant
    assert_equal({ @x => 0.5 }, (@x / 2).linear)
    assert_raises(ZeroDivisionError) { @x / 0 }
  end

  def test_negation_and_unary_plus
    assert_equal({ @x => -1.0 }, (-@x).linear)
    assert_equal({ @x => 1.0 }, (+@x).linear)
  end

  # ── the loud edges ────────────────────────────────────────────────────────

  def test_cubic_products_raise
    assert_raises(Quicopt::UnsupportedExpression) { @x * @y * @z }
    assert_raises(Quicopt::UnsupportedExpression) { (@x * @y) * (@y * @z) }
  end

  def test_division_by_a_variable_raises
    assert_raises(Quicopt::UnsupportedExpression) { @x / @y }
  end

  def test_unsupported_exponents_raise
    assert_raises(Quicopt::UnsupportedExpression) { @x**3 }
    assert_raises(Quicopt::UnsupportedExpression) { @x**0.5 }
  end

  def test_disequality_is_a_comparison_rather_than_false
    ne = @x != 3
    assert_instance_of Quicopt::Constraint, ne                   # never a silent `false`
    assert_equal :ne, ne.sense
    assert_raises(ArgumentError) { @m.add(ne) }                  # no row can hold it
    assert_raises(ArgumentError) { @m.add(@x < 3) }
    assert_raises(ArgumentError) { @m.add(@x > 3) }
    assert(@x != nil)                                            # anything else compares by identity
  end

  def test_non_numeric_operands_raise
    assert_raises(TypeError) { @x + "1" }
  end

  # ── comparisons build rows, not booleans ──────────────────────────────────

  def test_comparisons_build_constraints
    assert_kind_of Quicopt::Constraint, (@x <= 5)
    assert_kind_of Quicopt::Constraint, (@x >= 5)
    assert_kind_of Quicopt::Constraint, (@x == 5)
  end

  def test_constraint_splits_into_body_and_bound
    c = ((@x + @y) <= 5)
    assert_equal :le, c.sense
    assert_equal 5.0, c.bound
    assert_equal({ @x => 1.0, @y => 1.0 }, c.body.linear)
    assert_equal 0.0, c.body.constant
  end

  def test_constants_on_both_sides_collapse_into_the_bound
    c = ((@x + 2) >= (@y - 1))
    assert_equal :ge, c.sense
    assert_equal(-3.0, c.bound)
    assert_equal({ @x => 1.0, @y => -1.0 }, c.body.linear)
  end

  def test_equality_against_a_non_expression_falls_back_to_identity
    refute_equal @x, nil
    refute_equal @x, "x"
    # Against another expression it is a row, not a boolean — so identity is
    # asserted with assert_same, which does not route through +==+ at all.
    assert_same @x, @m.variable("x")
    assert_kind_of Quicopt::Constraint, (@x == @x)
  end

  def test_variables_stay_usable_as_hash_keys
    table = { @x => "first", @y => "second" }
    assert_equal "first", table[@x]
    assert_equal "second", table[@y]
    assert_equal 2, table.size
  end

  # ── declarations ──────────────────────────────────────────────────────────

  def test_domains
    assert_equal :INTEGER, @x.domain
    assert_equal :BINARY, @y.domain
    assert_equal :CONTINUOUS, @z.domain
  end

  def test_unit_range_integers_are_declared_binary
    # The same normalisation the sibling front-ends apply, so one model reaches
    # the service as one IR whichever client authored it.
    assert_equal :BINARY, @m.int_var(0, 1, "b").domain
    assert_equal :INTEGER, @m.int_var(0, 2, "i").domain
  end

  def test_omitted_bounds_are_infinite
    free = @m.num_var(nil, nil, "free")
    assert_equal(-Float::INFINITY, free.lower)
    assert_equal Float::INFINITY, free.upper
  end

  def test_start_defaults_to_zero_clamped_into_the_bounds
    assert_equal 0.0, @x.start
    assert_equal 2.0, @m.num_var(2, 8, "above").start
    assert_equal(-1.0, @m.num_var(-5, -1, "below").start)
    assert_equal 3.0, @m.num_var(0, 10, "explicit", start: 3).start
  end

  def test_auto_generated_names_do_not_collide
    anon = @m.num_var(0, 1)
    refute_includes %w[x y z], anon.name
    assert_same anon, @m.variable(anon.name)
  end

  def test_duplicate_names_raise
    assert_raises(ArgumentError) { @m.num_var(0, 1, "x") }
  end

  def test_inverted_bounds_raise
    assert_raises(ArgumentError) { @m.num_var(5, 1, "bad") }
  end

  # ── the model ─────────────────────────────────────────────────────────────

  def test_objective_and_sense
    assert_equal "min", @m.sense
    assert_equal 0, @m.objective.degree

    @m.maximize((3 * @x) + @z)
    assert_equal "max", @m.sense
    assert_equal({ @x => 3.0, @z => 1.0 }, @m.objective.linear)

    @m.minimize(@z)
    assert_equal "min", @m.sense
  end

  def test_add_returns_and_records_the_row
    row = @m.add(@x + @y <= 5)
    assert_equal [row], @m.constraints
  end

  def test_add_rejects_anything_that_is_not_a_row
    assert_raises(TypeError) { @m.add(@x + @y) }
    assert_raises(TypeError) { @m.add(true) }
  end

  def test_variables_from_another_model_are_rejected
    other = Quicopt::Model.new
    stranger = other.num_var(0, 1, "s")
    assert_raises(ArgumentError) { @m.add(@x + stranger <= 1) }
    assert_raises(ArgumentError) { @m.minimize(stranger) }
  end

  def test_to_s_renders_the_model
    @m.maximize((3 * @x) + (2 * @y) + @z)
    @m.add(@x + @y <= 5)
    assert_equal "max 3*x + 2*y + z", @m.to_s.lines.first.chomp
    assert_includes @m.to_s, "x + y <= 5"
  end
end
