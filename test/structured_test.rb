# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "test_helper"

# Permutations and lookup tables: what they build, and what they refuse.
#
# The DSL counts items, slots and table positions from 0, like Ruby; the service
# counts them from 1. Every test that inspects a built +Program+ is therefore also
# a test of that shift, which is where an off-by-one would hide.
class StructuredTest < Minitest::Test
  PB = Quicopt::Wire::PB
  W = Quicopt::Wire

  # The running example: five stops on a road, stop 3 visited before stop 0.
  def route_model
    position = [0, 3, 1, 4, 2]
    m = Quicopt::Model.new
    dist = m.lookup_table("dist", position.map { |a| position.map { |b| (a - b).abs } })
    route = m.permutation("route", 5)
    route.precede(3, 0)
    m.minimize((0...4).sum { |k| dist[route.item_at(k), route.item_at(k + 1)] })
    [m, route, dist]
  end

  # +item_at+ as the service reads it: slot and result counted from 1.
  def item_at(slot, name)
    W.apply("item_at", [W.const(slot), W.structure(name)])
  end

  # ── what gets built ───────────────────────────────────────────────────────

  def test_the_route_counts_from_one_on_the_wire
    m, = route_model
    program = m.to_program
    legs = (1..4).map { |k| W.table("dist", [item_at(k, "route"), item_at(k + 1, "route")]) }
    assert_equal W.apply("+", legs), program.objective
    assert_equal [PB::StructureDecl.new(name: "route", kind: "permutation", size: 5,
                                        precede: [PB::Precedence.new(before: 4, after: 1)])],
                 program.structures.to_a
    assert_empty program.vars
    dist = program.params.first
    assert_equal ["dist", 25], [dist.name, dist.entries.size]
    assert_equal [[1, 2], 3.0], [dist.entries[1].key.elems.map(&:int), dist.entries[1].value]
  end

  def test_a_read_outside_a_table_is_counted_from_zero
    m = Quicopt::Model.new
    office = m.permutation("office", 3)
    m.add(office.slot_of(2) <= 0)                           # department 2 gets office 0
    m.minimize(office.item_at(1))
    program = m.to_program
    slot_of2 = W.apply("slot_of", [W.const(3), W.structure("office")])
    assert_equal W.apply("-", [item_at(2, "office"), W.const(1)]), program.objective
    assert_equal W.apply("-", [W.const(0), W.apply("-", [slot_of2, W.const(1)])]),
                 program.constraints.first.f
  end

  def test_start_and_precedences_shift_to_one
    m = Quicopt::Model.new
    jobs = m.permutation("jobs", 4, start: [1, 0, 3, 2])
    jobs.precede(1, 0).precede(0, 3)
    m.minimize(jobs.slot_of(0))
    decl = m.to_program.structures.first
    assert_equal [2, 1, 4, 3], decl.start.to_a
    assert_equal [[2, 1], [1, 4]], decl.precede.map { |p| [p.before, p.after] }
    assert_equal [[1, 0], [0, 3]], jobs.precedences
  end

  def test_a_table_read_at_an_integer_variable
    m = Quicopt::Model.new
    price = m.lookup_table("price", [3.0, 1.0, 4.0, 1.5])
    choice = m.int_var(0, 3, "choice")
    m.minimize(price[choice])
    program = m.to_program
    assert_equal W.table("price", [W.apply("+", [W.var("choice"), W.const(1)])]), program.objective
    assert_equal [[[1], 3.0], [[2], 1.0], [[3], 4.0], [[4], 1.5]],
                 program.params.first.entries.map { |e| [e.key.elems.map(&:int), e.value] }
    assert_in_delta 4.0, price[2]                           # plain data, no expression
    assert_equal [4], price.shape
  end

  def test_a_whole_number_beside_an_expression_shifts_too
    m, route, dist = route_model
    m.minimize(dist[route.item_at(0), 2])
    assert_equal W.table("dist", [item_at(1, "route"), W.const(3)]), m.to_program.objective
  end

  def test_reads_are_terms_of_the_polynomial
    m, route, dist = route_model
    x = m.int_var(0, 3, "x")
    assert_equal 0, (route.item_at(0) - route.item_at(0)).degree
    leg = dist[route.item_at(0), route.item_at(1)]
    assert_equal 1, (2 * leg + 1).degree
    product = (x * leg) + (leg * x)
    assert_equal [2.0], product.quadratic.values
    assert_raises(Quicopt::UnsupportedExpression) { x * leg * leg }
    assert_equal [x], dist[x, 0].variables
  end

  def test_the_model_renders_what_was_written
    m, = route_model
    assert_equal <<~TEXT.chomp, m.to_s
      min dist[route.item_at(0), route.item_at(1)] + dist[route.item_at(1), route.item_at(2)] + dist[route.item_at(2), route.item_at(3)] + dist[route.item_at(3), route.item_at(4)]
        route is an ordering of items 0 to 4, with 3 before 0
        dist is a 5 × 5 lookup table
    TEXT
  end

  def test_the_message_round_trips
    m, = route_model
    assert_equal m.to_program, Quicopt.decode(m.encode)
  end

  def test_a_model_without_structures_is_unchanged
    m = Quicopt::Model.new
    x = m.num_var(0, 1, "x")
    m.minimize(x)
    assert_empty m.to_program.structures
    assert_empty m.to_program.params
  end

  # ── what gets refused ─────────────────────────────────────────────────────

  def test_permutation_arguments_are_checked
    m = Quicopt::Model.new
    assert_raises(ArgumentError) { m.permutation("p", 1) }
    assert_raises(TypeError) { m.permutation("p", 2.5) }
    assert_raises(ArgumentError) { m.permutation("p", 3, start: [0, 1, 1]) }
    assert_raises(ArgumentError) { m.permutation("p", 3, start: [1, 2, 3]) }      # counted from 0
    p = m.permutation("p", 3)
    assert_raises(ArgumentError) { m.permutation("p", 4) }                       # name taken
    assert_raises(ArgumentError) { p.item_at(3) }
    assert_raises(TypeError) { p.slot_of(1.0) }
    assert_raises(ArgumentError) { p.precede(1, 1) }
    p.precede(0, 1).precede(1, 2)
    assert_includes assert_raises(ArgumentError) { p.precede(2, 0) }.message, "contradicts"
  end

  def test_the_start_must_respect_the_precedences
    m = Quicopt::Model.new
    p = m.permutation("p", 3, start: [0, 1, 2])
    assert_includes assert_raises(ArgumentError) { p.precede(2, 0) }.message, "precede"
  end

  def test_table_arguments_are_checked
    m = Quicopt::Model.new
    assert_raises(ArgumentError) { m.lookup_table("t", []) }
    assert_raises(ArgumentError) { m.lookup_table("t", [[1.0, 2.0], [3.0]]) }
    assert_raises(ArgumentError) { m.lookup_table("t", [1.0, Float::NAN]) }
    assert_raises(TypeError) { m.lookup_table("t", [1.0, [2.0]]) }
    t = m.lookup_table("t", [[1.0, 2.0], [3.0, 4.0]])
    assert_raises(ArgumentError) { t[0] }                                         # two positions needed
    assert_raises(ArgumentError) { t[0, 2] }
    assert_raises(TypeError) { t[0, 0.5] }
    assert_in_delta 3.0, t[1, 0]
  end

  def test_names_are_shared_with_variables
    m = Quicopt::Model.new
    m.num_var(0, 1, "x1")
    assert_raises(ArgumentError) { m.permutation("x1", 2) }
    m.lookup_table("t", [1.0, 2.0])
    assert_raises(ArgumentError) { m.int_var(0, 1, "t") }
    m.permutation("x2", 2)
    assert_equal "x3", m.num_var.name                       # an automatic name skips taken ones
  end

  def test_reads_from_another_model_are_refused
    mine = Quicopt::Model.new
    theirs = Quicopt::Model.new
    route = theirs.permutation("route", 3)
    assert_raises(ArgumentError) { mine.minimize(route.item_at(0)) }
    table = mine.lookup_table("t", [1.0, 2.0, 3.0])
    assert_raises(ArgumentError) { table[route.item_at(0)] }
  end
end
