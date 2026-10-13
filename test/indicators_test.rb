# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "test_helper"

# Variables that may also be 0, +active+, +Quicopt.holds+, +Quicopt.min+ and
# +Quicopt.max+, blocks and partitions: what they build, and what they refuse.
#
# A partition counts items and parts from 0 here and from 1 on the wire, except
# a part's size, which is a count and is never shifted.
class IndicatorsTest < Minitest::Test
  PB = Quicopt::Wire::PB
  W = Quicopt::Wire

  def setup
    @m = Quicopt::Model.new
    @x = @m.num_var(0, 9, "x")
    @y = @m.num_var(0, 9, "y")
  end

  # The objective of +@m+ after minimizing +expr+, as the service reads it.
  def objective_of(expr)
    @m.minimize(expr)
    @m.to_program.objective
  end

  def step(arg) = W.apply("step", [arg])
  def minus(a, b) = W.apply("-", [a, b])
  # 1 − t, as the encoder writes it: 1 + (−1)·t
  def complement(t) = W.apply("+", [W.const(1), W.apply("*", [W.const(-1), t])])

  # ── variables that may also be 0 ──────────────────────────────────────────

  def test_semi_gives_the_two_domains_and_a_start_at_zero
    m = Quicopt::Model.new
    q = m.int_var(10, 25, "q", semi: true)
    r = m.num_var(2.5, 8, "r", semi: true)
    s = m.num_var(1, 4, "s", semi: true, start: 3)
    m.minimize(q + r + s)
    vars = m.to_program.vars.to_a
    assert_equal %i[SEMIINTEGER SEMICONTINUOUS SEMICONTINUOUS], vars.map(&:domain)
    assert_equal [0.0, 0.0, 3.0], vars.map(&:start)
    assert_equal [10.0, 25.0], [vars[0].lower.scalar, vars[0].upper.scalar]
  end

  def test_semi_needs_finite_bounds
    assert_raises(ArgumentError) { @m.num_var(1, nil, "u", semi: true) }
    assert_raises(ArgumentError) { @m.int_var(nil, 5, "v", semi: true) }
  end

  def test_semi_on_zero_to_one_is_not_binary
    assert_equal :SEMIINTEGER, @m.int_var(0, 1, "b", semi: true).domain
  end

  # ── active, holds, min and max ────────────────────────────────────────────

  def test_active_is_the_indicator_and_a_factor_of_degree_one
    q = @m.int_var(10, 25, "q", semi: true)
    assert_equal W.apply("+", [W.var("q"), W.apply("*", [W.const(30), W.apply("indicator", [W.var("q")])])]),
                 objective_of(q + 30 * q.active)
    assert_equal 1, (30 * q.active).degree
    assert_equal 2, (q * q.active).degree
    assert_equal 0, (q.active - q.active).degree                # equal terms are one object
  end

  # Each comparison's 0/1 form, its argument written as the encoder writes any
  # expression.
  def test_each_comparison_maps_to_its_zero_one_form
    e = ->(expr) { W.expression(expr) }
    y_minus_x = (-1 * @x) + @y                                   # x first, as in the comparison
    assert_equal step(e.(@x - @y)), objective_of(Quicopt.holds(@x >= @y))
    assert_equal step(e.(y_minus_x)), objective_of(Quicopt.holds(@x <= @y))
    assert_equal complement(step(e.(y_minus_x))), objective_of(Quicopt.holds(@x > @y))
    assert_equal complement(step(e.(@x - @y))), objective_of(Quicopt.holds(@x < @y))
    assert_equal complement(W.apply("indicator", [e.(@x - @y)])), objective_of(Quicopt.holds(@x == @y))
    assert_equal W.apply("indicator", [e.(@x - @y)]), objective_of(Quicopt.holds(@x != @y))
  end

  def test_a_tolerance_folds_into_the_argument
    # x >= 3 within 0.5: step(x − 3 + 0.5); x > 3 beyond 0.5: 1 − step(3 − x − 0.5)
    assert_equal step(W.expression(@x - 2.5)), objective_of(Quicopt.holds(@x >= 3, tol: 0.5))
    assert_equal complement(step(W.expression(2.5 - @x))), objective_of(Quicopt.holds(@x > 3, tol: 0.5))
    near = objective_of(Quicopt.holds(@x == 3, tol: 0.5))
    assert_equal "step", near.apply.op
    assert_raises(ArgumentError) { Quicopt.holds(@x >= 3, tol: -1) }
  end

  def test_a_comparison_of_numbers_is_a_number
    assert_equal 1.0, Quicopt.holds(Quicopt::Expression.new(constant: 4.0) >= 3).constant
    assert_raises(TypeError) { Quicopt.holds(4 >= 3) }
  end

  def test_strict_and_unequal_comparisons_are_not_rows
    assert_raises(ArgumentError) { @m.add(@x < 3) }
    assert_raises(ArgumentError) { @m.add(@x > 3) }
    assert_raises(ArgumentError) { @m.add(@x != 3) }
  end

  def test_min_and_max_nest_from_the_left
    assert_equal W.apply("min", [W.apply("min", [W.const(1), W.var("x")]), W.var("y")]),
                 objective_of(Quicopt.min(1, @x, @y))
    assert_equal W.apply("max", [W.var("x"), W.var("y")]), objective_of(Quicopt.max(@x, @y))
    assert_equal 3.0, Quicopt.max(1, 3).constant
    assert_raises(ArgumentError) { Quicopt.min(@x) }
  end

  def test_terms_from_two_models_are_refused
    other = Quicopt::Model.new.num_var(0, 1, "z")
    assert_raises(ArgumentError) { Quicopt.max(@x, other) }
  end

  # ── blocks ────────────────────────────────────────────────────────────────

  def test_blocks_go_out_sorted_by_name_members_in_the_order_given
    s = @m.bin_var("s")
    @m.block("supply", [@y, @x, s])
    q = @m.int_var(0, 4, "q")
    @m.block("pair", [q])
    @m.minimize(@x + @y + s + q)
    blocks = @m.to_program.blocks.to_a
    assert_equal %w[pair supply], blocks.map(&:name)
    assert_equal %w[y x s], blocks[1].members.map(&:name)
  end

  def test_block_arguments_are_checked
    @m.block("a", [@x])
    assert_raises(ArgumentError) { @m.block("a", [@y]) }             # name taken
    assert_raises(ArgumentError) { @m.block("b", []) }               # empty
    assert_raises(ArgumentError) { @m.block("b", [@y, @y]) }         # twice
    assert_raises(ArgumentError) { @m.block("b", [@x]) }             # already in a
    assert_raises(ArgumentError) { @m.block("b", [Quicopt::Model.new.num_var(0, 1, "z")]) }
    assert_raises(ArgumentError) { @m.block("b", [@m.num_var(0, nil, "free")]) }
    assert_raises(TypeError) { @m.block("b", [3]) }
  end

  # ── partitions ────────────────────────────────────────────────────────────

  def test_a_partition_counts_from_one_on_the_wire_except_a_size
    teams = @m.partition("teams", 5, 2, start: [0, 1, 0, 1, 0])
    part3 = W.apply("part_of", [W.const(4), W.structure("teams")])
    size1 = W.apply("size_of", [W.const(2), W.structure("teams")])
    assert_equal W.apply("+", [minus(part3, W.const(1)), size1]), objective_of(teams.part_of(3) + teams.size_of(1))
    assert_equal [PB::StructureDecl.new(name: "teams", kind: "partition", size: 5, parts: 2, start: [1, 2, 1, 2, 1])],
                 @m.to_program.structures.to_a
  end

  def test_a_part_read_as_a_table_position_loses_both_shifts
    cost = @m.lookup_table("cost", [2.0, 0.5])
    teams = @m.partition("teams", 3, 2)
    assert_equal W.table("cost", [W.apply("part_of", [W.const(1), W.structure("teams")])]),
                 objective_of(cost[teams.part_of(0)])
  end

  def test_partition_arguments_are_checked
    assert_raises(ArgumentError) { @m.partition("p", 0, 2) }
    assert_raises(ArgumentError) { @m.partition("p", 3, 1) }
    assert_raises(TypeError) { @m.partition("p", 2.5, 2) }
    assert_raises(ArgumentError) { @m.partition("p", 3, 2, start: [0, 2, 1]) }
    p = @m.partition("p", 3, 2)
    assert_raises(ArgumentError) { @m.permutation("p", 3) }            # name taken
    assert_raises(ArgumentError) { p.part_of(3) }
    assert_raises(ArgumentError) { p.size_of(2) }
    assert_raises(TypeError) { p.part_of(1.0) }
  end

  def test_the_message_round_trips
    teams = @m.partition("teams", 4, 2)
    q = @m.int_var(10, 25, "q", semi: true)
    @m.block("b", [q])
    @m.minimize(q + 5 * q.active + teams.size_of(0) + Quicopt.holds(q >= 12))
    program = @m.to_program
    assert_equal program, PB::Program.decode(@m.encode)
  end
end
