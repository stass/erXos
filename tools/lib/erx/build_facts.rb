# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'source_revision'

module Erx
  # The facts of an image's build that `uname -v`, `-i` and `-K` show
  # (docs/design-shell.md, "Text commands"), as the file the image build
  # writes into the system release at abi/erx_abi.txt's build_facts_path and
  # erx_build reads back. The file is one `name value` line per fact, in
  # Facts' order:
  #
  #   revision master-n1234-5e45e725588e
  #   date 1794163353
  #   configuration qemu-virt/development
  #   kernel fiasco-50bbe8a98119
  #
  # revision is the source revision (SourceRevision#to_s) and date its
  # commit's time in seconds since the epoch, UTC; both are unknown in a
  # tree that is not a git checkout, and they are the only facts of the
  # build host that enter the image. configuration is the platform and the
  # build kind, as FreeBSD's uname -i names a kernel configuration
  # (configuration), and kernel the packed kernel's name and upstream
  # revision. Each is the same for every build of one tree in one state, so
  # the image stays reproducible. A fact the build could not determine is
  # written `unknown`, never made up.
  module BuildFacts
    # nil stands for a fact the build could not determine.
    Facts = Data.define(:revision, :date, :configuration, :kernel)
    # What each fact may hold, which erx_build checks the same way when it
    # reads the file: printable ASCII with no space, so a line splits in two
    # at its first space and the fact needs no escaping to be shown.
    SHAPES = {
      revision: %r{\A[A-Za-z0-9][A-Za-z0-9._+/-]{0,159}\z},
      date: /\A[0-9]{1,12}\z/,
      configuration: %r{\A[a-z0-9][a-z0-9-]{0,63}/[a-z][a-z0-9-]{0,31}\z},
      kernel: /\A[a-z0-9][a-z0-9.-]{0,63}\z/
    }.freeze
    UNKNOWN = 'unknown'

    module_function

    # The configuration uname -i names: the platform record's name, a slash and
    # the build kind (development or release), each as it is, so a build of
    # qemu-virt for development is qemu-virt/development. It follows the
    # records, not where they lie in the tree.
    def configuration(platform:, build_kind:) = "#{platform}/#{build_kind}"

    # The facts of an image of the tree at root built for configuration with the
    # kernel named kernel (Fiasco#kernel_name).
    def gather(root:, runner:, configuration:, kernel:)
      revision = SourceRevision.read(root: root, runner: runner)
      Facts.new(revision: revision&.to_s, date: revision&.committed_at&.to_i, configuration: configuration, kernel: kernel)
    end

    # The file's text. A fact of the wrong shape raises, so the build never
    # writes a file erx_build would refuse.
    def render(facts)
      facts.to_h.map do |name, value|
        text = value.nil? ? UNKNOWN : value.to_s
        raise Error, "the build fact #{name} is not one uname can show: #{text.dump}" unless
          text == UNKNOWN || SHAPES.fetch(name).match?(text)

        "#{name} #{text}\n"
      end.join
    end
  end
end
