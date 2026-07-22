# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

# Copy the brand marks out alongside the stylesheets.
#
# YARD only copies files it knows about — the ones named in its stylesheet and
# javascript lists — so an image referenced from CSS never reaches the output
# directory unless it is registered here. The theming itself is entirely in
# css/common.css, which YARD ships as an explicit override hook and loads into
# both the main pages and the class-list iframe.
def generate_assets
  super
  %w[css/quicopt-icon-color.svg css/quicopt-icon-white.svg].each do |mark|
    asset(mark, file(mark, true))
  end
end
