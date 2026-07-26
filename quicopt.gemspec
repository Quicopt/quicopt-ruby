# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "lib/quicopt/version"

Gem::Specification.new do |spec|
  spec.name = "quicopt"
  spec.version = Quicopt::VERSION
  spec.authors = ["Tim Bode"]
  spec.email = ["9047234+timbode@users.noreply.github.com"]

  spec.summary = "Ruby client for the Quicopt optimization service."
  spec.description = "Describe an optimization problem in a small native Ruby DSL — the " \
                     "variables you choose, the constraints that must hold, and the quantity " \
                     "to minimize or maximize — and solve it on the Quicopt service. There is " \
                     "no local solver: the service does the solving."
  spec.homepage = "https://github.com/timbode/quicopt-ruby"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  # These become the links on the gem's RubyGems page, so "Documentation" points
  # at the site this repo deploys rather than defaulting to RubyDoc.info.
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://timbode.github.io/quicopt-ruby/"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship the library, the vendored message schema, and the licence/readme — but
  # not the dev-only scaffolding (tests, the code generator, bin/, CI config).
  #
  # `.yardopts` and `templates/` are deliberately kept: RubyDoc.info builds a
  # published gem's documentation from what is inside the gem, so shipping them
  # is what lets the hosted docs pick up the same configuration and theming as
  # the site this repo deploys.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ gen/ test/ .github/ Gemfile Rakefile .gitignore])
    end
  end
  spec.require_paths = ["lib"]

  # The generated protobuf classes are the only runtime dependency; requests go
  # out over stdlib net/http.
  spec.add_dependency "google-protobuf", "~> 4.0"
end
