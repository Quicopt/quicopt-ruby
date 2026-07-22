# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "lib/quicopt/version"

Gem::Specification.new do |spec|
  spec.name = "quicopt"
  spec.version = Quicopt::VERSION
  spec.authors = ["Tim Bode"]
  spec.email = ["9047234+timbode@users.noreply.github.com"]

  spec.summary = "Ruby client for the Quicopt service — author models, emit the Quicopt wire IR."
  spec.description = "Author an optimization model in a small native Ruby DSL, encode it to the " \
                     "versioned Quicopt wire IR, and solve it on the Quicopt service."
  spec.homepage = "https://github.com/timbode/quicopt-ruby"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship the library, the vendored wire contract, and the licence/readme — but
  # not the dev-only scaffolding (tests, the codec generator, bin/).
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) || f.start_with?(*%w[bin/ gen/ test/ Gemfile Rakefile .gitignore])
    end
  end
  spec.require_paths = ["lib"]

  # The generated codec is the only runtime dependency; transport is stdlib net/http.
  spec.add_dependency "google-protobuf", "~> 4.0"
end
