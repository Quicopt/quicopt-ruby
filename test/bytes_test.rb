# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "test_helper"

# +Wire.encode+ writes a model's bytes directly (+Wire::Bytes+). These tests hold
# them to the bytes of the message tree, +PB::Program.encode(Wire.program(m))+,
# on models with every kind of declaration, row and term.
class BytesTest < Minitest::Test
  W = Quicopt::Wire

  # The bytes written directly equal those of the message tree.
  def assert_same_bytes(model)
    assert_equal W::PB::Program.encode(W.program(model)), W.encode(model)
  end

  def setup
    @m = Quicopt::Model.new
    @x = @m.int_var(0, 4, "x", start: 2)
    @y = @m.bin_var("y")
    @z = @m.num_var(-Float::INFINITY, Float::INFINITY, "z")
    @q = @m.int_var(10, 25, "q", semi: true)
    @s = @m.num_var(0.5, 2.0, "s", semi: true, start: 1.5)
  end

  def test_a_model_with_nothing_in_it
    assert_same_bytes Quicopt::Model.new
  end

  def test_declarations_and_an_unset_objective
    @m.num_var(-0.0, 3.0, "w", start: -0.0)
    assert_same_bytes @m
  end

  def test_rows_of_every_sense_with_and_without_a_bound
    @m.add(@x + @y <= 5)
    @m.add(@x + @y <= 0)
    @m.add(3 * @x - @z >= -2.5)
    @m.add(@x - @z >= 0)
    @m.add(2 * @x + @q == 7)
    @m.add(@x - @y == 0)
    @m.add(-1 * @x <= -0.0)
    assert_same_bytes @m
  end

  def test_coefficients_of_one_zero_and_minus_one_and_a_constant_term
    @m.minimize(4.5 + @x + (0 * @y) - @z + (1e-300 * @q) + (-2.0 * @s))
    assert_same_bytes @m
    @m.maximize(Quicopt::Expression.new(constant: 3.0))
    assert_same_bytes @m
    @m.maximize(@x.to_expr)
    assert_same_bytes @m
    @m.maximize(7 * @x)
    assert_same_bytes @m
  end

  def test_quadratic_terms_and_squares
    @m.minimize((2 * @x * @y) + (@z * @z) + @x - 1)
    @m.add((@x * @y) + @q <= 3)
    assert_same_bytes @m
  end

  def test_indicators_steps_tolerances_and_extrema
    @m.minimize(@q + (30 * @q.active) + @s.active + Quicopt.holds(@x >= @y) + (2 * Quicopt.holds(@x < 3)) +
                Quicopt.holds(@x == 3, tol: 0.5) + Quicopt.holds(@x >= 3, tol: 0.5) +
                (4 * Quicopt.min(1, @x, @y)) + Quicopt.max(@x, @y) + (@q * @q.active))
    @m.add((5 * @q.active) - @x >= 1)
    @m.add(Quicopt.holds((2 * @x) + 1 >= @z) + @y <= 1)
    assert_same_bytes @m
  end

  def test_structures_lookup_tables_and_blocks
    dist = @m.lookup_table("dist", [[0, 3, 1], [3, 0, 2], [1, 2, 0]])
    cost = @m.lookup_table("cost", [2.0, 0.5])
    route = @m.permutation("route", 3, start: [2, 0, 1])
    route.precede(1, 0)
    teams = @m.partition("teams", 3, 2)
    @m.minimize(dist[route.item_at(0), route.item_at(1)] + (3 * route.slot_of(2)) + teams.part_of(1) +
                teams.size_of(0) + cost[teams.part_of(0)] + dist[@x, 1] + @x)
    @m.block("b2", [@q, @s])
    @m.block("b1", [@x])
    assert_same_bytes @m
  end

  def test_names_outside_ascii
    v = @m.num_var(0, 1, "größe")
    @m.minimize(v + (2 * v.active))
    @m.block("räume", [v])
    assert_same_bytes @m
  end

  def test_a_large_model_with_long_rows
    rng = Random.new(7)
    vars = Array.new(300) { |k| @m.int_var(0, 50, "v#{k}", semi: k.odd?) }
    vars.each_slice(40).with_index { |slice, k| @m.block("blk#{k}", slice) }
    60.times do
      row = vars.sample(130, random: rng).sum do |v|
        c = [1.0, -1.0, rng.rand * 100, 0.0, rng.rand(1..9).to_f].sample(random: rng)
        rng.rand < 0.5 ? c * v.active : c * v
      end
      @m.add(row <= (rng.rand * 1000).round(3))
    end
    @m.minimize(vars.sum { |v| (rng.rand * 10) * v } + vars.first(20).sum(&:active))
    assert_same_bytes @m
  end
end
