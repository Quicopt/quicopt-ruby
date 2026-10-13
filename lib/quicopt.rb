# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "quicopt/version"
require_relative "quicopt/model"
require_relative "quicopt/structured"
require_relative "quicopt/indicators"
require_relative "quicopt/wire"
require_relative "quicopt/client"

# Quicopt — a Ruby client for the Quicopt optimization service.
#
# Write a model in the native DSL, encode it, and let the service solve it:
#
#   require "quicopt"
#
#   m = Quicopt::Model.new
#   x = m.int_var(0, 4, "x")
#   y = m.bin_var("y")
#   z = m.num_var(0, 10, "z")
#   m.maximize(3 * x + 2 * y + z)
#   m.add(x + y <= 5)
#
#   result = Quicopt::Client.new.solve(m)
#   puts result.display
#
# Three pieces, nothing more: +Model+ authors, +Wire+ encodes, +Client+ ships.
module Quicopt
  # The structured message a model becomes, re-exported so callers can inspect
  # the bytes or route them themselves rather than going through +Client+.
  Program = Wire::PB::Program

  class << self
    # Encode a model to bytes.
    #
    # @param model [Model, Program]
    # @return [String] binary protobuf bytes
    def encode(model)
      Wire.encode(model)
    end

    # Parse bytes back into a +Program+.
    #
    # @param bytes [String]
    # @return [Program]
    def decode(bytes)
      Wire.decode(bytes)
    end
  end
end
