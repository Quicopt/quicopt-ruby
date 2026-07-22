# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "test_helper"

# The lowering: a DSL model → the wire IR.
#
# Goldens here are *decoded +Program+ values*, never hex. Generated proto3 output
# omits zero-valued scalars and does not canonicalize field order, so these bytes
# are decode-equivalent to the service's reference codec rather than
# byte-identical — the same position the Julia client is in. A hex golden would
# fail confusingly for a model that is in fact correct.
class WireTest < Minitest::Test
  PB = Quicopt::Wire::PB

  def setup
    @m = Quicopt::Model.new
    @x = @m.int_var(0, 4, "x")
    @y = @m.bin_var("y")
    @z = @m.num_var(0, 10, "z")
  end

  # ── node helpers, mirroring the canonical forms ───────────────────────────

  def const(value)
    PB::Expression.new(constant: value)
  end

  def var(name)
    PB::Expression.new(var: PB::VarRef.new(name: name, index: PB::Index.new))
  end

  def apply(op, args)
    PB::Expression.new(apply: PB::Apply.new(op: op, args: args))
  end

  def nonneg
    PB::ConSet.new(nonneg: PB::Nonneg.new)
  end

  def zero
    PB::ConSet.new(zero: PB::Zero.new)
  end

  # ── variables ─────────────────────────────────────────────────────────────

  def test_var_decls_carry_domain_bounds_and_start
    decls = @m.to_program.vars
    assert_equal %w[x y z], decls.map(&:name)
    assert_equal %i[INTEGER BINARY CONTINUOUS], decls.map(&:domain)
    assert_equal [0.0, 0.0, 0.0], decls.map { |d| d.lower.scalar }
    assert_equal [4.0, 1.0, 10.0], decls.map { |d| d.upper.scalar }
    assert_equal [0.0, 0.0, 0.0], decls.map(&:start)
    assert_empty decls.first.axes
  end

  def test_infinite_bounds_pass_through_as_free_directions
    free = Quicopt::Model.new
    free.num_var(nil, nil, "w")
    decl = free.to_program.vars.first
    assert_equal(-Float::INFINITY, decl.lower.scalar)
    assert_equal Float::INFINITY, decl.upper.scalar
    assert_equal 0.0, decl.start
  end

  # ── expressions ───────────────────────────────────────────────────────────

  def test_objective_lowers_to_an_n_ary_sum_with_unit_coefficients_dropped
    @m.maximize((3 * @x) + (2 * @y) + @z)
    program = @m.to_program
    assert_equal "max", program.sense
    assert_equal apply("+", [apply("*", [const(3.0), var("x")]),
                             apply("*", [const(2.0), var("y")]),
                             var("z")]),
                 program.objective
  end

  def test_objective_offset_leads_the_sum
    @m.minimize(@x - 4)
    assert_equal apply("+", [const(-4.0), var("x")]), @m.to_program.objective
  end

  def test_an_unset_objective_is_the_zero_constant
    # Const(0.0) is a set oneof case, so it survives the round-trip rather than
    # vanishing as a proto3 default.
    program = @m.to_program
    assert_equal const(0.0), program.objective
    assert_equal const(0.0), Quicopt.decode(@m.encode).objective
    assert_equal "min", program.sense
  end

  def test_a_single_term_objective_is_not_wrapped_in_a_sum
    @m.minimize(@z)
    assert_equal var("z"), @m.to_program.objective
  end

  def test_quadratic_terms_lower_to_a_product_of_two_var_refs
    @m.minimize(2 * @x * @y)
    assert_equal apply("*", [const(2.0), apply("*", [var("x"), var("y")])]),
                 @m.to_program.objective
  end

  def test_a_square_lowers_to_the_diagonal_product
    @m.minimize(@z**2)
    assert_equal apply("*", [var("z"), var("z")]), @m.to_program.objective
  end

  def test_var_refs_carry_a_present_but_empty_index
    @m.minimize(@z)
    ref = @m.to_program.objective.var
    refute_nil ref.index, "the Index message must be present, matching the reference codec"
    assert_empty ref.index.elems
  end

  # ── constraint rows ───────────────────────────────────────────────────────

  def test_upper_bound_row_becomes_nonneg_of_bound_minus_body
    @m.add(@x + @y <= 5)
    row = @m.to_program.constraints.first
    assert_equal nonneg, row.set
    assert_equal apply("-", [const(5.0), apply("+", [var("x"), var("y")])]), row.f
    assert_empty row.over
  end

  def test_lower_bound_row_becomes_nonneg_of_body_minus_bound
    @m.add(@x - @z >= -1)
    row = @m.to_program.constraints.first
    assert_equal nonneg, row.set
    assert_equal apply("-", [apply("+", [var("x"), apply("*", [const(-1.0), var("z")])]),
                             const(-1.0)]),
                 row.f
  end

  def test_equality_row_becomes_zero_of_body_minus_bound
    @m.add(@x + @z == 3)
    row = @m.to_program.constraints.first
    assert_equal zero, row.set
    assert_equal apply("-", [apply("+", [var("x"), var("z")]), const(3.0)]), row.f
  end

  def test_a_zero_bound_drops_the_subtraction
    @m.add(@x + @y >= 0)
    assert_equal apply("+", [var("x"), var("y")]), @m.to_program.constraints.first.f
  end

  def test_a_zero_upper_bound_still_emits_the_subtraction
    # `u − f ≥ 0` has no additive zero to drop: the constant is the minuend.
    @m.add(@x <= 0)
    assert_equal apply("-", [const(0.0), var("x")]), @m.to_program.constraints.first.f
  end

  def test_negative_zero_never_reaches_the_wire
    # Moving a zero bound across an inequality negates it into IEEE -0.0, which
    # protobuf keeps distinct from 0.0. The sibling clients emit 0.0.
    @m.add(@x <= 0)
    emitted = @m.to_program.constraints.first.f.apply.args.first.constant
    assert_equal 0.0, emitted
    assert_equal Float::INFINITY, 1.0 / emitted, "expected +0.0, got -0.0"

    negative_zero = Quicopt::Model.new
    negative_zero.num_var(-0.0, 1, "n")
    assert_equal Float::INFINITY, 1.0 / negative_zero.to_program.vars.first.lower.scalar
  end

  def test_rows_keep_insertion_order
    @m.add(@x <= 4)
    @m.add(@y <= 1)
    @m.add(@z == 2)
    assert_equal [nonneg, nonneg, zero], @m.to_program.constraints.map(&:set)
  end

  # ── serialization ─────────────────────────────────────────────────────────

  def test_encode_decode_round_trips
    @m.maximize((3 * @x) + (2 * @y) + @z)
    @m.add(@x + @y <= 5)
    program = @m.to_program
    assert_equal program, Quicopt.decode(@m.encode)
  end

  def test_encoding_is_deterministic
    @m.maximize((3 * @x) + (2 * @y) + @z)
    @m.add(@x + @y <= 5)
    assert_equal @m.encode, @m.encode
    assert_equal @m.encode, Quicopt.encode(@m.to_program)
  end

  def test_the_readme_model_lowers_to_the_expected_program
    @m.maximize((3 * @x) + (2 * @y) + @z)
    @m.add(@x + @y <= 5)

    expected = PB::Program.new(
      vars: [
        PB::VarDecl.new(name: "x", domain: :INTEGER,
                        lower: PB::Bound.new(scalar: 0.0), upper: PB::Bound.new(scalar: 4.0),
                        start: 0.0),
        PB::VarDecl.new(name: "y", domain: :BINARY,
                        lower: PB::Bound.new(scalar: 0.0), upper: PB::Bound.new(scalar: 1.0),
                        start: 0.0),
        PB::VarDecl.new(name: "z", domain: :CONTINUOUS,
                        lower: PB::Bound.new(scalar: 0.0), upper: PB::Bound.new(scalar: 10.0),
                        start: 0.0)
      ],
      objective: apply("+", [apply("*", [const(3.0), var("x")]),
                             apply("*", [const(2.0), var("y")]),
                             var("z")]),
      sense: "max",
      constraints: [
        PB::Constraint.new(f: apply("-", [const(5.0), apply("+", [var("x"), var("y")])]),
                           set: nonneg)
      ]
    )

    assert_equal expected, @m.to_program
    assert_equal expected, Quicopt.decode(@m.encode)
  end
end
