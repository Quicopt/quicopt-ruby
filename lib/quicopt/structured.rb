# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

# quicopt/structured — orderings as decisions (+Permutation+), assignments to
# groups as decisions (+Partition+) and data read at decided positions
# (+LookupTable+).
#
# All three are declared on a +Model+ (+Model#permutation+, +Model#partition+,
# +Model#lookup_table+) and enter its expressions as *reads*: +route.item_at(0)+
# is an +Expression+ whose one linear term is a +Placement+, +teams.part_of(2)+
# one whose term is a +PartRead+, +dist[i, j]+ one whose term is a +TableEntry+.
# A read takes a variable's place in the collected polynomial — it is a factor
# of degree 1 — so the degree check stays exact and the arithmetic needs no new
# cases.
#
# Reads are interned: asking twice for the same read returns the same object.
# Terms are hashed by identity (like +Variable+), so interning is what lets
# +route.item_at(0) - route.item_at(0)+ cancel and +x * dist[i, j]+ meet
# +dist[i, j] * x+ on one coefficient.
#
# The DSL counts items, slots, parts and table positions from 0, like Ruby; the
# service counts them from 1. A part's size is a count and is never shifted. The shift happens once, in +Quicopt::Wire+: a read stands for
# its 0-based value everywhere on this side, so +to_s+ prints what the user wrote.

module Quicopt
  # Position checks shared by +Permutation+ and +LookupTable+.
  #
  # @api private
  module Positions
    module_function

    # +k+, checked to be an Integer in +0...extent+.
    #
    # @raise [TypeError] if +k+ is not an Integer
    # @raise [ArgumentError] if it is out of range
    def check(k, extent, what, owner)
      raise TypeError, "#{owner}: a #{what} is a whole number, got #{k.inspect}" unless k.is_a?(Integer)
      unless k >= 0 && k < extent
        raise ArgumentError, "#{owner} has #{what}s 0 to #{extent - 1}, got #{k}"
      end

      k
    end
  end

  # A permutation declared by +Model#permutation+: +size+ items placed in +size+
  # slots, one item per slot, both numbered from 0. Read it with +item_at+ and
  # +slot_of+; constrain it with +precede+.
  #
  #   route = m.permutation("route", 5)
  #   route.item_at(0)     # the first stop visited
  #   route.slot_of(3)     # when stop 3 is visited
  #   route.precede(3, 0)  # stop 3 is visited before stop 0
  class Permutation
    # @return [Model] the model that declared this permutation
    attr_reader :model
    # @return [String] the permutation's name; its arrangement comes back keyed by it
    attr_reader :name
    # @return [Integer] the number of items, which is also the number of slots
    attr_reader :size
    # @return [Array<Integer>, nil] the slot each item starts in, or +nil+ for the
    #   default (item +i+ in slot +i+)
    attr_reader :start

    # Declared with +Model#permutation+, not built directly.
    #
    # @api private
    def initialize(model, name, size, start)
      @model = model
      @name = name
      @size = size
      @start = start&.freeze
      @precedences = []
      @reads = {}
    end

    # The item in slot +slot+, an expression whose value the service chooses. For
    # a route whose items are stops, +route.item_at(0)+ is the first stop visited.
    # Index a +LookupTable+ with it to read data about that item.
    #
    # @param slot [Integer] from 0 to +size - 1+
    # @return [Expression]
    # @raise [TypeError, ArgumentError] if +slot+ is not one of the slots
    def item_at(slot)
      read(:item_at, Positions.check(slot, @size, "slot", owner))
    end

    # The slot item +item+ is placed in, an expression whose value the service
    # chooses. For a route whose items are stops, +route.slot_of(3)+ is when stop 3
    # is visited.
    #
    # @param item [Integer] from 0 to +size - 1+
    # @return [Expression]
    # @raise [TypeError, ArgumentError] if +item+ is not one of the items
    def slot_of(item)
      read(:slot_of, Positions.check(item, @size, "item", owner))
    end

    # Require item +before+ to be in an earlier slot than item +after+: a pickup
    # before its delivery, or a job before the job that needs its output. The
    # service only considers arrangements that meet every such requirement, so
    # every solution meets it.
    #
    # @param before [Integer] an item
    # @param after [Integer] another item
    # @return [Permutation] +self+, so requirements can be chained
    # @raise [ArgumentError] if the two items are the same, if the requirement
    #   contradicts those already given (1 before 2 and 2 before 1), or if the
    #   +start+ places +before+ after +after+
    def precede(before, after)
      a = Positions.check(before, @size, "item", owner)
      b = Positions.check(after, @size, "item", owner)
      raise ArgumentError, "an item cannot precede itself" if a == b
      if @start && @start[a] > @start[b]
        raise ArgumentError, "#{owner}: the start places item #{a} after item #{b}, which it must precede"
      end
      if Permutation.cycle?(@precedences + [[a, b]], @size)
        raise ArgumentError, "requiring #{a} before #{b} contradicts the requirements already given for #{owner}"
      end

      @precedences << [a, b].freeze
      self
    end

    # @return [Array<Array(Integer, Integer)>] the +[before, after]+ requirements,
    #   in the order given
    def precedences
      @precedences.dup.freeze
    end

    # @return [String] name and size
    def inspect
      "#<Quicopt::Permutation #{@name} (#{@size} items in #{@size} slots)>"
    end

    # Whether the +[before, after]+ requirements over items +0...n+ contradict
    # each other: Kahn's algorithm leaves an item unplaced exactly when they
    # contain a cycle.
    #
    # @api private
    def self.cycle?(edges, n)
      indegree = Array.new(n, 0)
      edges.each { |_, b| indegree[b] += 1 }
      ready = (0...n).select { |i| indegree[i].zero? }
      placed = 0
      until ready.empty?
        x = ready.pop
        placed += 1
        edges.each do |a, b|
          next unless a == x

          indegree[b] -= 1
          ready << b if indegree[b].zero?
        end
      end
      placed < n
    end

    private

    def owner
      "permutation #{@name.inspect}"
    end

    def read(op, position)
      placement = (@reads[[op, position]] ||= Placement.new(self, op, position, @model.next_order))
      Expression.new(linear: { placement => 1.0 })
    end
  end

  # A partition declared by +Model#partition+: +size+ items in +parts+ parts,
  # both numbered from 0. Read it with +part_of+ and +size_of+.
  #
  #   teams = m.partition("teams", 6, 2)
  #   teams.part_of(4)     # the team person 4 joins
  #   teams.size_of(0)     # how many people team 0 has
  class Partition
    # @return [Model] the model that declared this partition
    attr_reader :model
    # @return [String] the partition's name; its assignment comes back keyed by it
    attr_reader :name
    # @return [Integer] the number of items
    attr_reader :size
    # @return [Integer] the number of parts
    attr_reader :parts
    # @return [Array<Integer>, nil] the part each item starts in, or +nil+ for the
    #   default (item +i+ in part +i % parts+)
    attr_reader :start

    # Declared with +Model#partition+, not built directly.
    #
    # @api private
    def initialize(model, name, size, parts, start)
      @model = model
      @name = name
      @size = size
      @parts = parts
      @start = start&.freeze
      @reads = {}
    end

    # The part item +item+ is in, an expression whose value the service
    # chooses. Index a +LookupTable+ with it to read data about that part.
    #
    # @param item [Integer] from 0 to +size - 1+
    # @return [Expression]
    # @raise [TypeError, ArgumentError] if +item+ is not one of the items
    def part_of(item)
      read(:part_of, Positions.check(item, @size, "item", owner))
    end

    # The number of items in part +part+, an expression whose value the service
    # chooses: a count from 0 to +size+.
    #
    # @param part [Integer] from 0 to +parts - 1+
    # @return [Expression]
    # @raise [TypeError, ArgumentError] if +part+ is not one of the parts
    def size_of(part)
      read(:size_of, Positions.check(part, @parts, "part", owner))
    end

    # @return [String] name and sizes
    def inspect
      "#<Quicopt::Partition #{@name} (#{@size} items in #{@parts} parts)>"
    end

    private

    def owner
      "partition #{@name.inspect}"
    end

    def read(op, position)
      entry = (@reads[[op, position]] ||= PartRead.new(self, op, position, @model.next_order))
      Expression.new(linear: { entry => 1.0 })
    end
  end

  # A table of data declared by +Model#lookup_table+, to be indexed with
  # expressions: +table[i]+ for a vector, +table[i, j]+ for a matrix, positions
  # counted from 0.
  #
  #   price  = m.lookup_table("price", [3.0, 1.0, 4.0, 1.5])
  #   choice = m.int_var(0, 3, "choice")
  #   price[choice]   # the price of the option the service picks
  #   price[2]        # 4.0, the number itself
  class LookupTable
    # @return [Model] the model that declared this table
    attr_reader :model
    # @return [String] the table's name
    attr_reader :name
    # @return [Array<Float>, Array<Array<Float>>] the entries, as given
    attr_reader :values
    # @return [Array<Integer>] the extent of each dimension: +[n]+ or +[rows, columns]+
    attr_reader :shape

    # Declared with +Model#lookup_table+, not built directly.
    #
    # @api private
    def initialize(model, name, values, shape)
      @model = model
      @name = name
      @values = values
      @shape = shape.freeze
      @reads = {}
    end

    # The entry at the given positions. With whole numbers only, that is the number
    # itself. With an expression among them — +route.item_at(k)+, an integer
    # variable — it is an expression whose value is the entry at the positions the
    # service chooses. A position that is not a whole number is rounded, and one
    # outside the table is moved to its nearest end.
    #
    # @param index [Array<Integer, Variable, Expression>] one position per dimension
    # @return [Float, Expression]
    # @raise [ArgumentError] on the wrong number of positions, or a whole number
    #   outside the table
    # @raise [TypeError] on a position that is neither a whole number nor an
    #   expression
    def [](*index)
      unless index.size == @shape.size
        raise ArgumentError, "#{owner} has #{@shape.size} dimension(s), so it takes #{@shape.size} " \
                             "position(s), got #{index.size}"
      end
      index.zip(@shape).each do |k, extent|
        if k.is_a?(Integer)
          Positions.check(k, extent, "position", owner)
        elsif k.is_a?(Numeric)
          raise TypeError, "#{owner}: a position is a whole number or an expression, got #{k}"
        end
      end
      return index.reduce(@values) { |row, k| row[k] } if index.all?(Integer)

      read(index.map { |k| Expression.cast(k) })
    end

    # @return [String] name and shape
    def inspect
      "#<Quicopt::LookupTable #{@name} (#{@shape.join(' × ')})>"
    end

    private

    def owner
      "lookup table #{@name.inspect}"
    end

    # One +TableEntry+ per distinct index, keyed by each position's terms in
    # canonical order (the terms are interned, so they key by identity).
    def read(index)
      index.each do |e|
        e.factors.each do |f|
          next if f.model.equal?(@model)

          raise ArgumentError, "#{f} belongs to a different Quicopt::Model than #{owner}"
        end
      end
      key = index.map do |e|
        [e.constant, e.linear.sort_by { |f, _| f.order }, e.quadratic.sort_by { |(a, b), _| [a.order, b.order] }]
      end
      entry = (@reads[key] ||= TableEntry.new(self, index.freeze, @model.next_order))
      Expression.new(linear: { entry => 1.0 })
    end
  end

  # A read of a permutation: the item in a slot, or the slot of an item. One
  # factor of an +Expression+, standing for its value counted from 0.
  #
  # @api private
  class Placement
    # @return [Permutation]
    attr_reader :permutation
    # @return [Symbol] +:item_at+ or +:slot_of+
    attr_reader :op
    # @return [Integer] the slot (for +:item_at+) or the item (for +:slot_of+)
    attr_reader :position
    # @return [Array] where this term sorts among a model's terms
    attr_reader :order

    def initialize(permutation, op, position, order)
      @permutation = permutation
      @op = op
      @position = position
      @order = order
      freeze
    end

    # @return [Model]
    def model
      @permutation.model
    end

    # @return [Array<Variable>] none: a read of a permutation involves no variable
    def variables
      []
    end

    # @return [String] the read as written, e.g. +route.item_at(0)+
    def to_s
      "#{@permutation.name}.#{@op}(#{@position})"
    end
  end

  # A read of a partition: the part of an item (counted from 0), or the number
  # of items in a part. One factor of an +Expression+.
  #
  # @api private
  class PartRead
    # @return [Partition]
    attr_reader :partition
    # @return [Symbol] +:part_of+ or +:size_of+
    attr_reader :op
    # @return [Integer] the item (for +:part_of+) or the part (for +:size_of+)
    attr_reader :position
    # @return [Array] where this term sorts among a model's terms
    attr_reader :order

    def initialize(partition, op, position, order)
      @partition = partition
      @op = op
      @position = position
      @order = order
      freeze
    end

    # @return [Model]
    def model
      @partition.model
    end

    # @return [Array<Variable>] none: a read of a partition involves no variable
    def variables
      []
    end

    # @return [String] the read as written, e.g. +teams.part_of(2)+
    def to_s
      "#{@partition.name}.#{@op}(#{@position})"
    end
  end

  # A read of a lookup table at positions given by expressions. One factor of an
  # +Expression+.
  #
  # @api private
  class TableEntry
    # @return [LookupTable]
    attr_reader :table
    # @return [Array<Expression>] one position per dimension, counted from 0
    attr_reader :index
    # @return [Array] where this term sorts among a model's terms
    attr_reader :order

    def initialize(table, index, order)
      @table = table
      @index = index
      @order = order
      freeze
    end

    # @return [Model]
    def model
      @table.model
    end

    # @return [Array<Variable>] the variables the positions mention
    def variables
      @index.flat_map(&:variables).uniq
    end

    # @return [String] the read as written, e.g. +dist[route.item_at(0), route.item_at(1)]+
    def to_s
      "#{@table.name}[#{@index.join(', ')}]"
    end
  end
end
