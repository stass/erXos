# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rexml/parsers/pullparser'
require 'digest'
require_relative 'json_input'
require_relative 'bounded_file'
require_relative 'generation_plan'

module Erx
  module Hardware
    XmlNode = Struct.new(:name, :attributes, :text, :children, keyword_init: true)
    # write is the field's modifiedWriteValues: empty for a write that stores its value, or one
    # of WRITE_ACTIONS; owned says the device NIF owns this field of a register it does not own whole.
    Field = Struct.new(:name, :offset, :width, :access, :write, :owned, :values, keyword_init: true) do
      def clear = write == 'oneToClear'
      def mask = ((1 << width) - 1) << offset
    end
    # cluster is the Movable cluster the register belongs to, or nil for a register at a fixed offset;
    # count_from is the FieldRef whose value, count_plus more, is how many elements of an array
    # the device has.
    Register = Struct.new(:name, :offset, :width, :access, :read_action, :fields, :owned_by_nif, :count, :stride,
                          :count_from, :count_plus, :cluster, keyword_init: true) do
      # Whether the register's elements are the instances of an array cluster, each at its own
      # base, rather than elements laid out at its stride from one.
      def instanced? = !cluster.nil? && cluster.instances > 1

      # The elements the register lays out from one base at its stride.
      def laid_out = instanced? ? 1 : count
    end
    # A field of a register at a fixed offset of the same peripheral, by their SVD names.
    FieldRef = Data.define(:register, :field)
    # A cluster whose base the device reports: its name, and where the base comes from, either
    # `from`, the field whose value in place is the cluster's offset in the window, or
    # `capability`, the ID of the extended capability whose entry the device NIF's walk of the
    # peripheral's list finds it at. `instances` is 1, or for an array cluster the most entries
    # with that ID it binds, each instance at its own entry.
    Movable = Data.define(:cluster, :from, :capability, :instances) do
      # What decides where the cluster lies: clusters at one field's base share it, and a
      # capability's cluster is placed alone.
      def place = from || cluster
    end
    # derived_from names the peripheral whose leading cluster this one's registers begin with;
    # leading is this one's own leading cluster, its name, offset and register count, or nil;
    # capabilities is the field that gives the head of its extended-capability list, or nil.
    # spaces are its configuration spaces (Space), empty for a peripheral of registers alone.
    Device = Struct.new(:name, :size, :registers, :derived_from, :leading, :capabilities, :spaces, keyword_init: true) do
      # Each movable cluster of the device once, in the order its registers first appear.
      def bases = registers.filter_map(&:cluster).uniq
    end
    Leading = Data.define(:name, :offset, :count)
    # A configuration space, the erXos extension for a PCIe bridge's configuration window
    # (docs/design-generation.md, "Register inputs"): `count` blocks of `size` bytes, one
    # function's configuration space each, one after another from `offset`. The device NIF
    # reaches a block with 8-, 16- and 32-bit accesses at an offset inside it, and only a block
    # that lies wholly inside the window it opened.
    Space = Data.define(:name, :offset, :size, :count) do
      def range = offset...(offset + size * count)
    end
    # The most bytes of one block: a PCIe function's configuration space, 4 KiB in ECAM.
    SPACE_BYTES_MAX = 4096
    # The most blocks of one space: every bus, device and function ECAM reaches (256 * 32 * 8).
    SPACE_BLOCKS_MAX = 65_536
    SPACES_MAX = 4
    IDENTIFIER = /\A[A-Za-z][A-Za-z0-9_]*\z/
    ARRAY_NAME = /\A(.*)\[%s\]\z/
    # dimFrom's text: REGISTER.FIELD, or REGISTER.FIELD + N.
    COUNT_FROM = /\A(?<field>[^+\s]+)(?:\s*\+\s*(?<plus>\S+))?\z/
    # The most elements of one register array or cluster: an MSI-X table's 2048 entries.
    ELEMENTS_MAX = 2048
    # An extended capability's ID is the byte its entry's first word begins with; 0 is reserved
    # (xHCI 1.2, Table 7-2, p. 517).
    CAPABILITY_IDS = (1..255)
    ENUMERATION_MAX = 256
    NAMES_MAX = 16_384
    WIDTHS = [8, 16, 32, 64].freeze
    PERIPHERALS_MAX = 16
    # The most a movable cluster's registers may reach past its base; the window bounds it at open.
    MOVABLE_SPAN_MAX = 1024 * 1024
    # The write semantics a field may declare beyond storing its value (svd-spec v1.3.9,
    # doxygen/src/svd_schema.txt, the field element's modifiedWriteValues): a one clears the bit, a
    # one sets it, or the field may hold another value after any write.
    WRITE_ACTIONS = %w[oneToClear oneToSet modify].freeze
    # The attributes the profile gives a meaning: the schema's version, a cluster's derivation
    # and an enumeration's.
    ATTRIBUTES = { 'device' => ['schemaVersion'], 'cluster' => ['derivedFrom'],
                   'enumeratedValues' => ['derivedFrom'] }.freeze
    # Headers the device table owns under include/erx/hw, so no peripheral may be named for one.
    DEVICE_HEADERS = %w[device_types device_table device_access device_owned].freeze
    # Every SVD file beneath hw/svd is an input; generation discovers them.
    SVD_GLOB = 'hw/svd/**/*.svd'
    MAX_SVD_BYTES = 4 * 1024 * 1024
    CONTAINERS = %w[device peripherals peripheral addressBlock registers cluster configurationSpace register fields field
                    enumeratedValues enumeratedValue].freeze
    module_function

    # REXML handles XML syntax. This bounded tree has no entity or DTD state
    # and never recursively follows an input-controlled element depth.
    def xml(bytes)
      raise Error, 'SVD exceeds its byte bound' unless bytes.is_a?(String) && bytes.bytesize <= 4 * 1024 * 1024
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && !text.include?("\0") &&
             !text.include?('<!DOCTYPE') && !text.include?('<!ENTITY')
        raise Error, 'SVD requires UTF-8 without document types or entities'
      end
      declarations = text.scan(/<\?xml\s+([^?]*)\?>/m).flatten
      declarations.each do |declaration|
        if declaration.match?(/\bencoding\b/) && !declaration.match?(/\bencoding\s*=\s*(['"])UTF-8\1/i)
          raise Error, 'SVD XML declaration must specify UTF-8'
        end
      end
      parser = REXML::Parsers::PullParser.new(text)
      stack = []
      root = nil
      count = 0
      while parser.has_next?
        event = parser.pull
        case event.event_type
        when :start_element
          count += 1
          raise Error, 'SVD element/depth bound exceeded' if count > 65_536 || stack.size >= 32
          node = XmlNode.new(name: event[0], attributes: event[1], text: ''.dup, children: [])
          allowed_attributes = ATTRIBUTES.fetch(node.name, [])
          unless (node.attributes.keys - allowed_attributes).empty?
            raise Error, 'SVD attributes require explicit semantic support'
          end
          if stack.empty?
            raise Error, 'SVD has multiple roots' if root
            root = node
          else
            stack.last.children << node
          end
          stack << node
        when :end_element
          raise Error, 'SVD has unmatched element' unless stack.last && stack.last.name == event[0]
          closed = stack.pop
          if CONTAINERS.include?(closed.name)
            raise Error, 'text in SVD container is unsupported' unless closed.text.strip.empty?
          elsif !closed.children.empty?
            raise Error, 'nested SVD scalar content is unsupported'
          end
        when :text
          if stack.empty?
            raise Error, 'text outside SVD root' unless event[1].to_s.strip.empty?
          else
            stack.last.text << event[1].to_s
          end
        when :xmldecl, :comment, :end_document
          next
        else
          raise Error, "unsupported SVD XML event: #{event.event_type}"
        end
      end
      raise Error, 'incomplete SVD tree' unless root && stack.empty?
      root
    rescue REXML::ParseException, ArgumentError, Encoding::CompatibilityError => error
      raise Error, "invalid SVD XML: #{error.message}"
    end

    def children(node, name)
      node.children.select { |child| child.name == name }
    end

    def child(node, name, required: true)
      values = children(node, name)
      raise Error, "duplicate SVD #{name}" if values.size > 1
      raise Error, "missing SVD #{name}" if required && values.empty?
      values.first
    end

    def text(node, name, default: nil)
      value = child(node, name, required: default.nil?)
      raise Error, 'nested SVD scalar content is unsupported' if value && !value.children.empty?
      value ? value.text.strip : default
    end

    def number(value, maximum: (1 << 64) - 1)
      unless value.is_a?(String) && /\A(?:0x[0-9A-Fa-f]+|[0-9]+)\z/.match?(value) && value.bytesize <= 32
        raise Error, 'invalid SVD unsigned integer'
      end
      result = Integer(value, value.start_with?('0x') ? 16 : 10)
      raise Error, 'SVD integer exceeds its width' if result > maximum
      result
    end

    def identifier(value)
      unless value.is_a?(String) && value.bytesize.between?(1, 63) && IDENTIFIER.match?(value)
        raise Error, 'invalid or overlong SVD identifier'
      end
      value.freeze
    end

    def known_elements(node, allowed:)
      unknown = node.children.map(&:name) - allowed
      raise Error, "unsupported SVD element: #{unknown.first}" unless unknown.empty?
      unless (node.attributes.keys - ATTRIBUTES.fetch(node.name, [])).empty?
        raise Error, 'SVD attributes require explicit semantic support'
      end
    end

    def access(value)
      raise Error, 'unsupported SVD register access' unless %w[read-only write-only read-write].include?(value)
      value.freeze
    end

    # The one peripheral of an SVD file that describes one, as most do.
    def parse_svd(bytes)
      devices = parse_peripherals(bytes)
      raise Error, 'SVD input describes more than one peripheral' unless devices.size == 1

      devices.first
    end

    # Every peripheral of one SVD file, in order. A peripheral's registers are its own, and
    # those of a cluster it derives from an earlier peripheral of the file (see derived_cluster).
    def parse_peripherals(bytes)
      root = xml(bytes)
      raise Error, 'SVD root must be device' unless root.name == 'device'
      raise Error, 'unsupported SVD schema version' unless root.attributes['schemaVersion'] == '1.3'
      known_elements(root, allowed: %w[name version description addressUnitBits width peripherals])
      raise Error, 'SVD address units must be bytes' unless number(text(root, 'addressUnitBits')) == 8
      default_width = number(text(root, 'width'))
      peripherals = child(root, 'peripherals')
      known_elements(peripherals, allowed: ['peripheral'])
      unless peripherals.children.size.between?(1, PERIPHERALS_MAX)
        raise Error, "SVD input profile requires 1..#{PERIPHERALS_MAX} peripherals"
      end
      peripherals.children.each_with_object([]) do |node, parsed|
        parsed << parse_peripheral(node, default_width: default_width, earlier: parsed)
      end.freeze
    end

    def parse_peripheral(peripheral, default_width:, earlier:)
      known_elements(peripheral, allowed: %w[name description baseAddress addressBlock capabilitiesFrom registers
                                             configurationSpace])
      raise Error, 'SVD peripheral base must be relative zero' unless number(text(peripheral, 'baseAddress')) == 0
      block = child(peripheral, 'addressBlock')
      known_elements(block, allowed: %w[offset size usage])
      raise Error, 'SVD address block must start at zero' unless number(text(block, 'offset')) == 0
      raise Error, 'SVD address block must hold registers' unless text(block, 'usage') == 'registers'
      size = number(text(block, 'size'), maximum: 1024 * 1024)
      spaces = children(peripheral, 'configurationSpace').map { |node| parse_space(node) }.freeze
      raise Error, "SVD peripheral takes at most #{SPACES_MAX} configuration spaces" if spaces.size > SPACES_MAX
      registers = child(peripheral, 'registers', required: spaces.empty?)
      return space_device(peripheral, size: size, spaces: spaces) if registers.nil?

      known_elements(registers, allowed: %w[register cluster])
      parsed = peripheral_registers(registers.children, default_width: default_width, block_size: size, earlier: earlier,
                                                        enumerations: peripheral_enumerations(registers))
      list = parsed.list
      raise Error, 'SVD requires 1..4096 registers' unless list.size.between?(1, 4096)
      names = list.map { |register| register.name.downcase }
      raise Error, 'SVD register names collide' unless names.uniq == names
      fixed = list.reject(&:cluster)
      raise Error, 'SVD peripheral requires a register at a fixed offset' if fixed.empty?

      # Registers at fixed offsets share the block; movable clusters' share the base they are
      # reported at, and where that falls is the device NIF's to check against the window at open.
      clusters = list.filter_map(&:cluster).uniq
      unless clusters.map(&:cluster).uniq.size == clusters.size && clusters.size < 256
        raise Error, 'SVD movable clusters need distinct names, fewer than 256'
      end
      list_head = text(peripheral, 'capabilitiesFrom', default: '')
      capabilities = list_head.empty? ? nil : field_reference(list_head)
      check_capabilities(clusters, capabilities)
      list.group_by { |register| register.cluster&.place }.each_value do |group|
        element_ranges(group).each_cons(2) do |left, right|
          raise Error, 'SVD register ranges overlap' if left.end > right.begin
        end
      end
      # Every fixed register, a copied one included, lies inside this peripheral's own block.
      raise Error, 'SVD register is outside its aligned block' if element_ranges(fixed).map(&:end).max > size
      check_spaces(spaces, ranges: element_ranges(fixed), names: names)
      check_references(list, fixed, capabilities)
      # Field lists and shared enumerations multiply what the file spells out; this bounds
      # the names a peripheral's headers carry, one per field and one per field's value.
      unless list.sum { |register| register.fields.sum { |field| 1 + field.values.size } } <= NAMES_MAX
        raise Error, "SVD peripheral exceeds #{NAMES_MAX} field and value names"
      end

      Device.new(name: identifier(text(peripheral, 'name')), size: size, registers: list.freeze,
                 derived_from: parsed.derived_from, leading: parsed.leading,
                 capabilities: capabilities, spaces: spaces).freeze.then do |device|
        validate_symbols(device)
        device
      end
    end

    # A configuration space: NAME, or NAME[%s] with a dim of 2 or more for an array of blocks;
    # its first block's addressOffset and one block's size, each a multiple of 4, so that every
    # 32-bit access inside a block is aligned.
    def parse_space(node)
      known_elements(node, allowed: %w[name description addressOffset size dim])
      name = text(node, 'name')
      offset = number(text(node, 'addressOffset'), maximum: 1024 * 1024)
      size = number(text(node, 'size'), maximum: SPACE_BYTES_MAX)
      unless size >= 4 && (size % 4).zero? && (offset % 4).zero?
        raise Error, "an SVD configuration space has blocks of 4 to #{SPACE_BYTES_MAX} bytes at an offset of 4"
      end
      return Space.new(name: identifier(name), offset: offset, size: size, count: 1) if child(node, 'dim', required: false).nil?

      count = number(text(node, 'dim'), maximum: SPACE_BLOCKS_MAX)
      base = name[ARRAY_NAME, 1]
      raise Error, 'an SVD configuration space array is NAME[%s] of dim 2 or more' unless base && count >= 2

      Space.new(name: identifier(base), offset: offset, size: size, count: count)
    end

    # Spaces meet neither each other nor a register at a fixed offset, and none shares a
    # register's name, since a driver names both.
    def check_spaces(spaces, ranges:, names:)
      all = names + spaces.map { |space| space.name.downcase }
      raise Error, 'SVD configuration space names collide' unless all.uniq == all

      (ranges + spaces.map(&:range)).sort_by(&:begin).each_cons(2) do |left, right|
        raise Error, 'SVD configuration spaces overlap' if left.end > right.begin
      end
    end

    # A peripheral of configuration spaces alone, as an ECAM window is: no registers, so no
    # clusters and no capability list.
    def space_device(peripheral, size:, spaces:)
      raise Error, 'an SVD peripheral without registers has no capabilitiesFrom' unless text(peripheral, 'capabilitiesFrom', default: '').empty?

      check_spaces(spaces, ranges: [], names: [])
      Device.new(name: identifier(text(peripheral, 'name')), size: size, registers: [].freeze, derived_from: nil,
                 leading: nil, capabilities: nil, spaces: spaces).freeze.then do |device|
        validate_symbols(device)
        device
      end
    end

    # What a peripheral's register list holds: its registers in order, a cluster's flattened in
    # its place under their own names; the peripheral whose cluster it copies, or nil; and its
    # own leading cluster, which a later peripheral may copy, or nil.
    Registers = Data.define(:list, :derived_from, :leading)

    # Only the first element may be a derived cluster or the leading cluster a later
    # peripheral copies; the rest are registers and plain clusters.
    def peripheral_registers(nodes, default_width:, block_size:, earlier:, enumerations:)
      raise Error, 'SVD requires 1..4096 registers' if nodes.empty?

      head, *rest = nodes
      shape = { default_width: default_width, block_size: block_size, enumerations: enumerations }
      tail = rest.flat_map do |node|
        raise Error, "an SVD derived cluster must be its peripheral's first element" if node.attributes.key?('derivedFrom')

        element_registers(node, **shape)
      end
      case head
      in { name: 'cluster', attributes: } if attributes.key?('derivedFrom')
        source, copied = derived_cluster(head, earlier: earlier)
        Registers.new(list: copied + tail, derived_from: source, leading: nil)
      in { name: 'cluster' }
        members = cluster_registers(head, **shape)
        leading = Leading.new(name: text(head, 'name'), offset: number(text(head, 'addressOffset')), count: members.size)
        Registers.new(list: members + tail, derived_from: nil, leading: leading)
      else
        Registers.new(list: element_registers(head, **shape) + tail, derived_from: nil, leading: nil)
      end
    end

    def element_registers(node, **shape)
      return cluster_registers(node, **shape) if node.name == 'cluster'

      [parse_register(node, **shape)]
    end

    # A cluster of the profile: one level, its registers at offsets from its own. A cluster
    # whose base the device reports is movable, and sits at offset 0 with its registers at
    # offsets from that base, within MOVABLE_SPAN_MAX. Its base comes from one of two erXos
    # extensions. baseFrom, as xHCI's operational, runtime and doorbell registers have it (xHCI
    # 1.2, 5.3.1, 5.3.7 and 5.3.8, pp. 381-388), names REGISTER.FIELD, a field of a register at
    # a fixed offset whose bits in place are the cluster's byte offset in the window;
    # capabilityId, as xHCI's legacy support and supported protocol capabilities have it (7,
    # p. 517), is the ID of the extended capability whose entry the cluster lies at. A
    # capability's cluster may be an array, NAME[%s] with a dim and no dimIncrement: one
    # instance for each entry with that ID, up to dim, each at its own entry. check_references
    # resolves the names (docs/design-usb.md, "Registers at offsets the controller reports").
    def cluster_registers(node, block_size:, **shape)
      known_elements(node, allowed: %w[name description addressOffset baseFrom capabilityId dim dimIncrement register])
      from = text(node, 'baseFrom', default: '')
      capability = text(node, 'capabilityId', default: '')
      base = number(text(node, 'addressOffset'), maximum: block_size)
      members = children(node, 'register')
      raise Error, 'SVD cluster requires registers' if members.empty?
      raise Error, 'an SVD cluster takes baseFrom or capabilityId, not both' unless from.empty? || capability.empty?
      raise Error, 'an SVD cluster takes no dimIncrement: an array cluster\'s instances lie at their own entries' if child(node, 'dimIncrement', required: false)
      name, instances = cluster_shape(node, capability: !capability.empty?)
      if from.empty? && capability.empty?
        return members.map { |member| parse_register(member, block_size: block_size, base: base, **shape) }
      end
      raise Error, 'an SVD movable cluster sits at offset 0' unless base.zero?

      movable = Movable.new(cluster: name, from: from.empty? ? nil : field_reference(from),
                            capability: capability.empty? ? nil : number(capability), instances: instances)
      members.map { |member| parse_register(member, block_size: MOVABLE_SPAN_MAX, movable: movable, **shape) }
    end

    # A cluster's name and its instances: one, or for NAME[%s] with a dim, which only a
    # capability's cluster may be, up to dim.
    def cluster_shape(node, capability:)
      name = text(node, 'name')
      return [identifier(name), 1] if child(node, 'dim', required: false).nil?

      base = name[ARRAY_NAME, 1]
      instances = number(text(node, 'dim'), maximum: ELEMENTS_MAX)
      raise Error, 'an SVD cluster array is a capability cluster NAME[%s] of dim 2 or more' unless capability && base && instances >= 2

      [identifier(base), instances]
    end

    # A capability's cluster needs the list its entry is on, and names an ID no other cluster does.
    def check_capabilities(clusters, capabilities)
      ids = clusters.filter_map(&:capability)
      raise Error, "an SVD capability cluster needs its peripheral's capabilitiesFrom" if capabilities.nil? && !ids.empty?
      raise Error, 'SVD capability IDs must be 1..255, one cluster each' unless ids.uniq == ids && ids.all? { |id| CAPABILITY_IDS.cover?(id) }
    end

    # REGISTER.FIELD, as baseFrom and dimFrom name a field.
    def field_reference(value)
      register, field, *rest = value.split('.', -1)
      raise Error, 'an SVD field reference is REGISTER.FIELD' unless rest.empty? && register && field

      FieldRef.new(register: identifier(register), field: identifier(field))
    end

    # Each base and count a peripheral's registers take from another register names a readable
    # field of a register at a fixed offset whose read has no side effect, which the device NIF reads once at open;
    # a count field must not report more elements than its array has.
    def check_references(list, fixed, capabilities)
      resolve = lambda do |ref, what|
        register = fixed.find { |candidate| candidate.name == ref.register && candidate.count == 1 }
        field = register&.fields&.find { |candidate| candidate.name == ref.field }
        unless field && register.access != 'write-only' && register.read_action.empty? && field.access != 'write-only'
          raise Error, "SVD #{what} names no readable field of a fixed register: #{ref.register}.#{ref.field}"
        end

        field
      end
      list.filter_map(&:cluster).uniq.select(&:from).each do |movable|
        resolve.call(movable.from, "cluster #{movable.cluster}'s base")
      end
      resolve.call(capabilities, 'capabilitiesFrom') if capabilities
      list.select(&:count_from).each do |register|
        field = resolve.call(register.count_from, "array #{register.name}'s count")
        if (1 << field.width) - 1 + register.count_plus > register.count
          raise Error, "SVD array #{register.name}'s count can name an element past its dim"
        end
      end
    end

    # The named enumerations of one peripheral's fields, each by its name, for an
    # enumeratedValues derivedFrom to copy. CMSIS-SVD's derivation "makes a copy from a
    # previously defined enumeratedValues section. No modifications are allowed" (svd-spec
    # v1.3.9, doxygen/src/svd_schema.txt, the enumeratedValues element). The profile resolves
    # a bare name within its own peripheral, so a name defines one enumeration there, and a
    # derivation names one defined before it in document order; this walk is the one place
    # that checks both, and parse_field's lookup cannot miss. Each definition is parsed here
    # once, and every field that copies it shares the one frozen table.
    def peripheral_enumerations(registers)
      registers.children.flat_map { |node| node.name == 'cluster' ? children(node, 'register') : [node] }
               .flat_map { |register| children(register, 'fields') }
               .flat_map { |fields| children(fields, 'field') }
               .flat_map { |field| children(field, 'enumeratedValues') }
               .each_with_object({}) do |node, named|
        source = node.attributes['derivedFrom']
        name = text(node, 'name', default: '')
        if source
          raise Error, 'SVD enumeratedValues derives from no earlier enumeration' unless named.key?(source)
        elsif !name.empty?
          raise Error, 'SVD enumeratedValues names collide' if named.key?(name)

          named[identifier(name)] = enumeration(node)
        end
      end.freeze
    end

    # A cluster derivedFrom "PERIPHERAL.CLUSTER" copies that cluster whole, as CMSIS-SVD's
    # derivation copies a section, and adds nothing: elements a derived section restates
    # override what it inherits, and the specification defines no merge of a register list
    # (svd-spec v1.3.9, doxygen/src/svd_schema.txt, cluster and peripheral derivedFrom). The
    # cluster it names leads an earlier peripheral of the file, derives from none and is that
    # peripheral's whole register list, and the copy is the first element of its own
    # peripheral at the same offset, so every register of the source keeps its index in the
    # copy's table, which the device NIF relies on for the registers it owns.
    def derived_cluster(node, earlier:)
      known_elements(node, allowed: %w[name description addressOffset])
      identifier(text(node, 'name'))
      path = node.attributes.fetch('derivedFrom').split('.', -1)
      source = earlier.find { |device| device.name == path.first } if path.size == 2
      raise Error, 'SVD cluster derives from no earlier peripheral' if source.nil?
      raise Error, 'SVD cluster derives from a derived peripheral' unless source.derived_from.nil?

      leading = source.leading
      unless leading&.name == path.last && leading.offset == number(text(node, 'addressOffset'))
        raise Error, 'SVD derived cluster names no leading cluster at its offset'
      end
      raise Error, "SVD derived cluster is not its source peripheral's whole table" unless leading.count == source.registers.size

      [source.name, source.registers.first(leading.count)]
    end

    # The byte range of each register, one for each element of an array, in address order.
    def element_ranges(registers)
      registers.flat_map do |register|
        Array.new(register.laid_out) do |index|
          first = register.offset + index * register.stride
          first...(first + register.width / 8)
        end
      end.sort_by(&:begin)
    end

    # The mark erXos adds to the SVD profile: whether the device NIF owns a register, writing
    # it only in sequences of its own (a ring's base address, a queue's setup, the device's
    # status and features), so that write/3 and write_field/4 refuse it. The mark may instead
    # sit on single writable fields, as true, and then the register carries none of its own
    # (docs/design-device-dma.md, "Register ownership"). A register with neither is refused,
    # so no one adds a register without deciding.
    def owned_mark(node, fields:)
      case [text(node, 'ownedByNif', default: ''), fields.any?(&:owned)]
      in ['true', false] then true
      in ['false', false] | ['', true] then false
      in [_, true] then raise Error, 'an SVD register with owned fields carries no ownedByNif mark of its own'
      else raise Error, 'SVD register lacks its ownedByNif mark'
      end
    end

    # An array is `NAME[%s]` with dim and dimIncrement, one element per index from zero. Where
    # the device reports how many elements it has, as xHCI's MaxPorts gives its PORTSC
    # registers (xHCI 1.2, 5.3.3, p. 382), dimFrom, an erXos extension, names that field as
    # REGISTER.FIELD, or REGISTER.FIELD + N where the device has N elements more than the field
    # says, as xHCI has a doorbell for each of MaxSlots slots and one for the command ring (5.6,
    # p. 429); dim is the most it can report, and check_references resolves the name.
    def register_shape(node, width:)
      name = text(node, 'name')
      if child(node, 'dim', required: false).nil?
        if child(node, 'dimIncrement', required: false) || child(node, 'dimFrom', required: false)
          raise Error, 'SVD dimIncrement or dimFrom without dim'
        end

        return [name, 1, 0]
      end

      base = name[ARRAY_NAME, 1]
      count = number(text(node, 'dim'), maximum: ELEMENTS_MAX)
      stride = number(text(node, 'dimIncrement'), maximum: 1024 * 1024)
      unless base && count >= 2 && stride >= width / 8 && stride % (width / 8) == 0
        raise Error, 'invalid SVD register array'
      end
      [base, count, stride]
    end

    # dimFrom's field and the number it adds: nil and 0 for an array of a fixed length.
    def count_reference(node)
      return [nil, 0] unless child(node, 'dimFrom', required: false)

      match = COUNT_FROM.match(text(node, 'dimFrom'))
      raise Error, 'SVD dimFrom is REGISTER.FIELD or REGISTER.FIELD + N' unless match

      [field_reference(match[:field]), match[:plus] ? number(match[:plus], maximum: ELEMENTS_MAX) : 0]
    end

    def parse_register(node, default_width:, block_size:, enumerations:, base: 0, movable: nil)
      known_elements(node, allowed: %w[name description addressOffset size access readAction fields
                                       ownedByNif dim dimIncrement dimFrom])
      width = number(text(node, 'size', default: default_width.to_s))
      raise Error, 'SVD access width must be 8, 16, 32 or 64 bits' unless WIDTHS.include?(width)
      offset = base + number(text(node, 'addressOffset'), maximum: block_size)
      name, count, stride = register_shape(node, width: width)
      # A register of an array cluster has an element in each instance, at its offset from that
      # instance's base, and is not an array of its own.
      if movable && movable.instances > 1
        raise Error, 'an SVD register of a cluster array is not an array' unless count == 1

        count = movable.instances
        stride = 0
      end
      span = (count - 1) * stride + width / 8
      unless offset % (width / 8) == 0 && offset <= block_size && span <= block_size - offset
        raise Error, 'SVD register is outside its aligned block'
      end
      mode = access(text(node, 'access'))
      action = text(node, 'readAction', default: '')
      raise Error, 'unsupported SVD read action' unless ['', 'clear', 'set', 'modify', 'modifyExternal'].include?(action)
      fields_node = child(node, 'fields')
      known_elements(fields_node, allowed: ['field'])
      fields = fields_node.children.flat_map do |field|
        parse_field(field, width: width, register_access: mode, enumerations: enumerations)
      end
      raise Error, 'SVD register requires fields' if fields.empty?
      occupied = 0
      names = []
      fields.each do |field|
        mask = ((1 << field.width) - 1) << field.offset
        raise Error, 'SVD fields overlap' unless (occupied & mask).zero?
        occupied |= mask
        names << field.name.downcase
      end
      raise Error, 'SVD field names collide' unless names.uniq == names
      # A field whose write acts rather than stores, beside a field a write must keep, is
      # written as the word read with its preserved bits kept (preserve_mask), so the read
      # must be allowed and change nothing.
      if acting_fields?(fields) && !preserve_of(fields).zero? && !action.empty?
        raise Error, 'mixed SVD write semantics need a read without side effects'
      end
      # A write to a register with owned fields is checked against the word read just before it.
      raise Error, 'an SVD register with owned fields needs a read without side effects' if fields.any?(&:owned) && !action.empty?
      count_from, count_plus = count_reference(node)
      Register.new(name: identifier(name), offset: offset, width: width, access: mode, read_action: action.freeze,
                   fields: fields.freeze, owned_by_nif: owned_mark(node, fields: fields), count: count, stride: stride,
                   count_from: count_from, count_plus: count_plus, cluster: movable).freeze
    end

    # The fields one field element describes: itself, or each element of a list. A list is
    # CMSIS-SVD's field dim (svd-spec v1.3.9, doxygen/src/svd_schema.txt, dimElementGroup and
    # the field element): one description repeated dim times, the name's %s replaced by each
    # dimIndex string and the bit offset advanced by dimIncrement bits each time. The elements
    # become ordinary fields, so the register's overlap and name checks see each of them.
    def parse_field(node, width:, register_access:, enumerations:)
      known_elements(node, allowed: %w[name description bitOffset bitWidth access modifiedWriteValues enumeratedValues
                                       ownedByNif dim dimIncrement dimIndex])
      offset = number(text(node, 'bitOffset'), maximum: width)
      bits = number(text(node, 'bitWidth'), maximum: width)
      mode = access(text(node, 'access', default: register_access))
      if register_access == 'read-only' && mode != 'read-only' || register_access == 'write-only' && mode != 'write-only'
        raise Error, 'SVD field access exceeds its register'
      end
      modified = text(node, 'modifiedWriteValues', default: '')
      raise Error, 'unsupported SVD write semantics' unless ['', *WRITE_ACTIONS].include?(modified)
      raise Error, 'read-only SVD field cannot declare write semantics' if !modified.empty? && mode == 'read-only'
      owned = case text(node, 'ownedByNif', default: '')
              when '' then false
              when 'true' then true
              else raise Error, 'an SVD field is marked ownedByNif true or not at all'
              end
      raise Error, 'a read-only SVD field cannot be owned' if owned && mode == 'read-only'
      values = enumerated_values(child(node, 'enumeratedValues', required: false), bits: bits, enumerations: enumerations)
      field_elements(node, width: width).map do |name, shift|
        first = offset + shift
        raise Error, 'SVD field exceeds register width' unless bits.positive? && first < width && bits <= width - first

        Field.new(name: name, offset: first, width: bits,
                  access: mode, write: modified.freeze, owned: owned, values: values).freeze
      end
    end

    # Each field a field element names, with its bit offset from the element's own. The
    # profile takes the list form, NAME%s, alone: an array, NAME[%s], would need array
    # accessors no driver asks for.
    def field_elements(node, width:)
      name = text(node, 'name')
      if child(node, 'dim', required: false).nil?
        raise Error, 'SVD dimIncrement or dimIndex without dim' if child(node, 'dimIncrement', required: false) ||
                                                                   child(node, 'dimIndex', required: false)

        return [[identifier(name), 0]]
      end

      raise Error, 'an SVD field list names one %s' unless name.scan('%s').size == 1 && !name.include?('[%s]')
      increment = number(text(node, 'dimIncrement'), maximum: width)
      # Elements of at least one bit each that may not overlap number no more than the
      # register's bits, and each name is checked as it is made.
      indexes = dim_indexes(text(node, 'dimIndex', default: ''), count: number(text(node, 'dim'), maximum: width))
      indexes.each_with_index.map { |index, position| [identifier(name.sub('%s', index)), position * increment] }
    end

    # The strings a list's %s takes: 0 to dim - 1 by default, or dimIndex's range FIRST-LAST
    # or comma-separated list, which must name exactly dim elements. dimIndex's letter range
    # (A-Z) has no consumer and is refused.
    def dim_indexes(value, count:)
      raise Error, 'SVD dim requires at least one element' unless count.positive?

      indexes = case value
                when '' then 0...count
                when /\A[0-9]+-[0-9]+\z/ then value.split('-').then { |first, last| number(first)..number(last) }
                when /\A[_0-9A-Za-z]+(?:,\s*[_0-9A-Za-z]+)+\z/ then value.split(/,\s*/)
                else raise Error, 'unsupported SVD dimIndex'
                end
      raise Error, 'SVD dimIndex does not name dim elements' unless indexes.size == count

      indexes.map(&:to_s)
    end

    # A field's values by lower-cased name, each fitting the field: its own enumeration, or
    # the one a derivedFrom names, which peripheral_enumerations has parsed once and every
    # copy shares. A derived section restates nothing, as the specification allows no
    # modification of the copy. (The schema, schema/CMSIS-SVD.xsd, still asks one
    # enumeratedValue of every section; the text's "no modifications" is what is followed.)
    def enumerated_values(node, bits:, enumerations:)
      return {}.freeze if node.nil?

      values = if node.attributes.key?('derivedFrom')
                 known_elements(node, allowed: [])
                 enumerations.fetch(node.attributes['derivedFrom'])
               else
                 enumeration(node)
               end
      raise Error, 'SVD enumerated value exceeds its field' unless values.each_value.all? { |value| value < (1 << bits) }

      values
    end

    # One enumeration's values by lower-cased name: 1..ENUMERATION_MAX of them, as the
    # schema asks at least one of a section that defines its values.
    def enumeration(node)
      known_elements(node, allowed: %w[name enumeratedValue])
      entries = children(node, 'enumeratedValue')
      raise Error, "SVD enumeration requires 1..#{ENUMERATION_MAX} values" unless entries.size.between?(1, ENUMERATION_MAX)

      entries.each_with_object({}) do |value, values|
        known_elements(value, allowed: %w[name description value])
        name = identifier(text(value, 'name'))
        raise Error, 'duplicate SVD enumerated name' if values.key?(name.downcase)

        values[name.downcase] = number(text(value, 'value'))
      end.freeze
    end

    def c_mask(width, register_width:)
      value = (1 << width) - 1
      c_integer(value, width: register_width)
    end

    def c_integer(value, width:)
      "UINT#{width}_C(0x#{value.to_s(16)})"
    end

    # Underscores make distinct source paths capable of naming the same C
    # member. Check the complete emitted namespace rather than each level.
    def generated_symbols(device)
      symbols = device.registers.flat_map do |register|
        name = "erx_#{device.name.downcase}_#{register.name.downcase}"
        accessors = []
        accessors << "#{name}_read" unless register.access == 'write-only'
        accessors << "#{name}_write" unless register.access == 'read-only'
        accessors << "#{name.upcase}_PRESERVE" if preserved?(register)
        fields = register.fields.flat_map do |field|
          member = "#{name}_#{field.name.downcase}"
          values = field.values.keys.map { |label| "#{member.upcase}_#{label.upcase}" }
          values << "#{member}_get" unless field.access == 'write-only'
          writer = field_writer(register, field)
          values << "#{member}_#{writer}" if writer
          values
        end
        accessors + fields
      end
      (["ERX_HW_#{device.name.upcase}_H"] + symbols).freeze
    end

    # The name device_owned_header gives a register the NIF owns, whole or in some fields,
    # which erx_device.c uses.
    def owned_symbol(device, register) = "ERX_DEVICE_OWNED_#{device.name.upcase}_#{register.name.upcase}"

    def owned_symbols(device)
      device.registers.reject { |register| owned_mask(register).zero? && !register.owned_by_nif }
            .map { |register| owned_symbol(device, register) }.freeze
    end

    def validate_symbols(device)
      symbols = generated_symbols(device)
      raise Error, 'SVD generated C symbols collide' unless symbols.uniq == symbols
      macros = erlang_symbols(device)
      raise Error, 'SVD generated Erlang macros collide' unless macros.uniq == macros
    end

    # The name every Erlang macro of one field begins with. ERX_HW_ keeps the hardware's
    # macros apart from erx_abi.hrl's, which name no peripheral but share ERX_.
    def erlang_field_name(device, register, field) = "ERX_HW_#{device.name}_#{register.name}_#{field.name}".upcase

    # Every macro name the device's Erlang header defines, read from the header itself, so
    # no list of what it defines can fall behind it. Erlang tells macros apart by arity too,
    # but no two here share a name, so none can shadow another.
    def erlang_symbols(device) = erlang_header(device).scan(/^-define\(([A-Za-z0-9_]+)/).flatten.freeze

    def erlang_integer(value) = "16##{value.to_s(16)}"

    # A device's fields for its Erlang driver: plain arithmetic on a register's word, which
    # erx_device reads and writes by name. Each field's comment states its access, which no
    # macro enforces: what a write may set is erx_device's to refuse (docs/design-runtime.md,
    # "The device NIF").
    def erlang_header(device)
      guard = "ERX_HW_#{device.name.upcase}_HRL"
      ['%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>', '%% SPDX-License-Identifier: BSD-2-Clause',
       "%% Generated by tools/gen_hw.rb from the SVD file of peripheral #{device.name}. Do not edit.",
       "-ifndef(#{guard}).", "-define(#{guard}, true).", '',
       '%% For each field F of each register (docs/design-generation.md, "Register inputs"):',
       '%% F_SHIFT is its lowest bit, F_WIDTH its width and F_MASK its bits in place in the word;',
       '%% F_GET(Word) is the field of Word, F_FITS(Value) a guard that Value is a non-negative',
       '%% integer the field holds, and F_PUT(Value) Value in place, which fails with',
       '%% {badfield, {Peripheral, Register, Field}, Value} when it does not fit. All but',
       '%% F_PUT may stand in a guard; F_PUT evaluates Value more than once, so it takes a',
       '%% variable or a literal. Each value the source names for a field is F_NAME, the',
       '%% field value, not in place. Every field has every macro, whatever its access, so',
       '%% a device model can build the words the device writes.', '',
       *device.registers.flat_map { |register| erlang_register(device, register) }, '-endif.', ''].join("\n")
    end

    def erlang_register(device, register)
      array = if register.instanced?
                ", one in each of up to #{register.count} instances"
              elsif register.count > 1
                ", #{register.count} of them #{erlang_integer(register.stride)} apart"
              else
                ''
              end
      owner = register.owned_by_nif ? ', owned by the device NIF' : ''
      place = register.cluster ? " of cluster #{register.cluster.cluster}, #{base_words(register.cluster)}" : ''
      preserve = if preserved?(register)
                   name = "ERX_HW_#{device.name}_#{register.name}_PRESERVE".upcase
                   ["%% The bits a write keeps from the word read, so it changes only what it means to:",
                    "-define(#{name}, #{erlang_integer(preserve_mask(register))}).", '']
                 end
      ["%%% #{register.name}, at #{erlang_integer(register.offset)}#{place}, #{register.width} bits, " \
       "#{register.access}#{array}#{owner}", '', *preserve,
       *register.fields.flat_map { |field| erlang_field(device, register, field) }]
    end

    # Where a movable cluster's base comes from, in words for the generated comments.
    def base_words(movable)
      return "whose base #{movable.from.register}.#{movable.from.field} reports" if movable.from

      "at the extended capability with ID #{movable.capability}"
    end

    WRITE_WORDS = { '' => '', 'oneToClear' => ', one to clear', 'oneToSet' => ', one to set',
                    'modify' => ', changed by a write' }.freeze

    def erlang_field(device, register, field)
      name = erlang_field_name(device, register, field)
      top = field.offset + field.width - 1
      field_max = erlang_integer((1 << field.width) - 1)
      location = [device, register, field].map { |part| "'#{part.name.downcase}'" }.join(', ')
      ["%% #{register.name}.#{field.name}, bits #{top}:#{field.offset}, #{field.access}" \
       "#{WRITE_WORDS.fetch(field.write)}#{field.owned ? ', owned by the device NIF' : ''}",
       "-define(#{name}_SHIFT, #{field.offset}).", "-define(#{name}_WIDTH, #{field.width}).",
       "-define(#{name}_MASK, #{erlang_integer(((1 << field.width) - 1) << field.offset)}).",
       "-define(#{name}_GET(Word), (((Word) bsr #{field.offset}) band #{field_max})).",
       "-define(#{name}_FITS(Value), (is_integer(Value) andalso (Value) >= 0 andalso (Value) =< #{field_max})).",
       # The check is an orelse, not a case on true and false: Dialyzer flags a
       # case's false clause as unreachable wherever Value is a literal that fits.
       "-define(#{name}_PUT(Value),",
       "        (begin ?#{name}_FITS(Value) orelse erlang:error({badfield, {#{location}}, Value}),",
       "               (Value) bsl #{field.offset}",
       '         end)).',
       *field.values.map { |label, value| "-define(#{name}_#{label.upcase}, #{value})." }, '']
    end

    def mmio_header
      <<~C
        /* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
         * SPDX-License-Identifier: BSD-2-Clause
         * Generated by tools/gen_hw.rb. Do not edit.
         */
        #ifndef ERX_MMIO_H
        #define ERX_MMIO_H
        #include <stddef.h>
        #include <stdint.h>
        typedef struct erx_mmio erx_mmio_t;
        struct erx_mmio {
        \tvolatile uint8_t *base;
        \tsize_t length;
        };
        #endif
      C
    end

    def device_header(device)
      prefix = "erx_#{device.name.downcase}"
      guard = "ERX_HW_#{device.name.upcase}_H"
      lines = ["/* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>",
               ' * SPDX-License-Identifier: BSD-2-Clause',
               ' * Generated by tools/gen_hw.rb. Do not edit.', ' */',
               "#ifndef #{guard}", "#define #{guard}", '#include <stdbool.h>',
               '#include <stddef.h>', '#include <stdint.h>', '#include "erx/mmio.h"', '']
      device.registers.each do |register|
        type = "uint#{register.width}_t"
        name = "#{prefix}_#{register.name.downcase}"
        bytes = register.width / 8
        array = register.count > 1 && !register.instanced?
        index = array ? ', uint32_t index' : ''
        last = register.offset + (register.laid_out - 1) * register.stride + bytes
        at = array ? "#{register.offset} + index * #{register.stride}" : register.offset.to_s
        in_range = array ? "index >= #{register.count} || " : ''
        readable = register.access != 'write-only'
        writable = register.access != 'read-only'
        if register.cluster
          view = register.instanced? ? "one instance's view" : "that cluster's view"
          lines << "/* #{register.name.downcase} is in cluster #{register.cluster.cluster}: device is #{view}, its base " \
                   "#{base_words(register.cluster).delete_prefix('whose base ')}. */"
        end
        if preserved?(register)
          lines << "#define #{name.upcase}_PRESERVE #{c_integer(preserve_mask(register), width: register.width)}"
        end
        if readable
          lines.concat(['static inline bool', "#{name}_read(erx_mmio_t device#{index}, #{type} *out)", '{',
                        "\tif (#{in_range}out == NULL || device.base == NULL || device.length < #{last} ||",
                        "\t    (uintptr_t)device.base % #{bytes} != 0)", "\t\treturn (false);",
                        "\t*out = *(volatile #{type} *)(device.base + #{at});",
                        "\treturn (true);", '}', ''])
        end
        if writable
          lines.concat(['static inline bool', "#{name}_write(erx_mmio_t device#{index}, #{type} value)", '{',
                        "\tif (#{in_range}device.base == NULL || device.length < #{last} ||",
                        "\t    (uintptr_t)device.base % #{bytes} != 0 ||",
                        "\t    (value & ~#{c_integer(writable_mask(register), width: register.width)}) != 0)",
                        "\t\treturn (false);", "\t*(volatile #{type} *)(device.base + #{at}) = value;",
                        "\treturn (true);", '}', ''])
        end
        register.fields.each do |field|
          field_name = "#{name}_#{field.name.downcase}"
          mask = c_mask(field.width, register_width: register.width)
          field.values.each do |label, value|
            lines << "#define #{field_name.upcase}_#{label.upcase} UINT#{register.width}_C(#{value})"
          end
          if field.access != 'write-only'
            lines.concat(['static inline ' + type, "#{field_name}_get(#{type} word)", '{',
                          "\treturn ((word >> #{field.offset}) & #{mask});", '}', ''])
          end
          case field_writer(register, field)
          when nil then next
          when 'clear'
            lines.concat(['static inline bool', "#{field_name}_clear(erx_mmio_t device#{index}, #{type} value)", '{',
                          "\tif ((value & ~#{mask}) != 0)", "\t\treturn (false);",
                          "\treturn (#{name}_write(device#{array ? ', index' : ''}, value << #{field.offset}));", '}', ''])
          when 'set'
            lines.concat(['static inline bool', "#{field_name}_set(#{type} word, #{type} value, #{type} *out)", '{',
                          "\tif (out == NULL || (value & ~#{mask}) != 0)", "\t\treturn (false);",
                          "\t*out = (word & ~(#{mask} << #{field.offset})) | (value << #{field.offset});",
                          "\treturn (true);", '}', ''])
          end
        end
      end
      lines.concat(['#endif', '']).join("\n")
    end

    def writable_mask(register)
      register.fields.reject { |field| field.access == 'read-only' }.sum(&:mask)
    end

    # The bits a write carries from the word read so that it changes only what it means to:
    # every field that can be read and stores what is written. A field whose write acts, by
    # clearing, setting or changing it, and one that cannot be read back, is written as zero.
    # For xHCI's PORTSC this is the writable bits FreeBSD's XHCI_PS_CLEAR does not remove
    # (xhcireg.h:146), derived from the source instead of copied (docs/design-usb.md, "Ports").
    def preserve_mask(register) = preserve_of(register.fields)

    def preserve_of(fields) = fields.select { |field| field.access == 'read-write' && field.write.empty? }.sum(&:mask)

    # Whether some writable field of the register acts on a write rather than storing it, so a
    # driver writes the register as the word read, masked to preserve_mask, with its own bits.
    def acting?(register) = acting_fields?(register.fields)

    # Whether the register's headers define its preserve mask: a register with an acting field,
    # and one written back as the word read, whose mask keeps its reserved bits clear so the
    # generated write, which refuses them, takes the word (the on-board pins' GPFSEL words).
    def preserved?(register) = acting?(register) || plain_update?(register)

    def acting_fields?(fields) = fields.any? { |field| field.access != 'read-only' && !field.write.empty? }

    # The bits the device NIF owns: every writable bit of a register it owns, or its owned fields.
    def owned_mask(register)
      register.owned_by_nif ? writable_mask(register) : register.fields.select(&:owned).sum(&:mask)
    end

    # The accessor a writable field gets: a clear for a one-to-clear field, written alone, which
    # only a register with nothing to preserve allows; a pure set on a word otherwise; none for a
    # read-only field or for a one-to-clear field beside preserved bits, whose register is
    # written whole with its preserve mask.
    def field_writer(register, field)
      return nil if field.access == 'read-only'
      return 'set' unless field.clear

      preserve_mask(register).zero? ? 'clear' : nil
    end

    # Whether a field of the register may be replaced by reading the word and writing it back:
    # the read has no side effect, and some bit is writable (a register with none takes a write
    # that means something other than replacement, as a write to PL011's RSR clears its errors).
    def plain_update?(register)
      register.access == 'read-write' && register.read_action.empty? && !writable_mask(register).zero? &&
        register.fields.none? { |field| !field.write.empty? || field.access == 'write-only' }
    end

    def generated_header(guard, body, includes: [])
      ['/* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>', ' * SPDX-License-Identifier: BSD-2-Clause',
       ' * Generated by tools/gen_hw.rb. Do not edit.', ' */', "#ifndef #{guard}", "#define #{guard}",
       *includes.map { |file| "#include #{file}" }, '', *body, '#endif', ''].join("\n")
    end

    # The shapes of the device table, and the most any peripheral needs, so a device's record
    # holds its atoms in place.
    def device_types_header(devices)
      registers_max = devices.map { |device| device.registers.size }.max
      fields_max = devices.map { |device| device.registers.sum { |register| register.fields.size } }.max
      slots_max = [1, *devices.map { |device| device.bases.sum(&:instances) }].max
      spans_max = devices.map { |device| device.registers.sum { |register| register.instanced? ? register.count : 1 } }.max
      generated_header('ERX_HW_DEVICE_TYPES_H', <<~C.lines(chomp: true), includes: %w[<stdbool.h> <stddef.h> <stdint.h>])
        #define ERX_DEVICE_REGISTERS_MAX #{registers_max}u
        #define ERX_DEVICE_FIELDS_MAX #{fields_max}u
        /* The most cluster instances one peripheral's registers are placed at, at least one. */
        #define ERX_DEVICE_SLOTS_MAX #{slots_max}u
        /* The most register spans one peripheral's layout has: a register's, in each instance of an array cluster. */
        #define ERX_DEVICE_SPANS_MAX #{spans_max}u

        typedef enum erx_device_access {
        \tERX_DEVICE_READ_ONLY,
        \tERX_DEVICE_WRITE_ONLY,
        \tERX_DEVICE_READ_WRITE
        } erx_device_access_t;

        typedef struct erx_device_field {
        \tconst char\t*name;
        \tuint64_t\tmask;
        \tuint8_t\t\tshift;
        \tuint8_t\t\taccess;
        \tbool\t\tclear;
        } erx_device_field_t;

        typedef struct erx_device_register {
        \tconst char\t*name;
        \tuint64_t\twritable;
        \tuint32_t\toffset;
        \tuint32_t\tcount;
        \tuint32_t\tstride;
        \tuint32_t\tfirst_field;
        \tuint32_t\tfield_count;
        \tuint8_t\t\twindow;
        \tuint8_t\t\twidth;
        \tuint8_t\t\taccess;
        \tbool\t\towned_by_nif;
        \tbool\t\tplain_update;
        \tuint64_t\tpreserve;	/* the bits a write keeps from the word read */
        \tuint64_t\towned;		/* the bits the NIF owns: all writable ones if owned_by_nif */
        \tuint8_t\t\tbase;		/* 1 + the index of its movable cluster in bases, or 0 for a fixed offset */
        \tbool\t\tcounted;	/* the array's live count is field count_field (an index in the peripheral's
        \t\t\t\t   fields, not from first_field) of register count_register */
        \tuint32_t\tcount_register;
        \tuint32_t\tcount_field;
        \tuint32_t\tcount_plus;	/* the elements a counted array has beyond that field's value */
        } erx_device_register_t;

        /*
         * A cluster whose base the device reports. With `capability` 0, its registers' offsets
         * are from the value of field `field` (an index in the peripheral's fields), in place, of
         * register `reg`, a register at a fixed offset; otherwise from the entry with that ID of
         * the peripheral's extended-capability list, one instance for each such entry up to
         * `instances`. Its instances' bases are a record's slots from `first`.
         */
        typedef struct erx_device_base {
        \tconst char\t*name;
        \tuint32_t\treg;
        \tuint32_t\tfield;
        \tuint8_t\t\tcapability;
        \tuint32_t\tinstances;
        \tuint32_t\tfirst;
        } erx_device_base_t;

        /*
         * A configuration space (docs/design-generation.md, "Register inputs"): `count` blocks
         * of `size` bytes, block i at `offset` + i * `size` of the window, each reached with 8-,
         * 16- and 32-bit accesses at an offset inside it, and only while it lies wholly inside
         * the window the device was opened with.
         */
        typedef struct erx_device_space {
        \tconst char\t*name;
        \tuint64_t\toffset;
        \tuint32_t\tsize;
        \tuint32_t\tcount;
        } erx_device_space_t;

        typedef struct erx_device_peripheral {
        \tconst char\t\t\t*name;
        \tconst erx_device_register_t\t*registers;
        \tconst erx_device_field_t\t*fields;
        \tuint64_t\t\t\twindow_size;
        \tuint32_t\t\t\tregister_count;
        \tuint32_t\t\t\tfield_count;
        \tconst char\t\t\t*derived_from;	/* the peripheral whose registers lead this one's, or NULL */
        \tconst erx_device_base_t\t\t*bases;		/* its movable clusters, or NULL */
        \tuint32_t\t\t\tbase_count;
        \tbool\t\t\t\tlisted;		/* it has an extended-capability list, whose head */
        \tuint32_t\t\t\tlist_reg;	/* field list_field (an index in its fields) of register */
        \tuint32_t\t\t\tlist_field;	/* list_reg gives in 32-bit words from the window's start */
        \tconst erx_device_space_t\t*spaces;	/* its configuration spaces, or NULL */
        \tuint32_t\t\t\tspace_count;
        } erx_device_peripheral_t;
      C
    end

    ACCESS_NAMES = { 'read-only' => 'ERX_DEVICE_READ_ONLY', 'write-only' => 'ERX_DEVICE_WRITE_ONLY',
                     'read-write' => 'ERX_DEVICE_READ_WRITE' }.freeze

    def table_field(field, width:)
      mask = c_integer(((1 << field.width) - 1) << field.offset, width: width)
      "\t{ .name = \"#{field.name.downcase}\", .mask = #{mask}, .shift = #{field.offset}, " \
        ".access = #{ACCESS_NAMES.fetch(field.access)}, .clear = #{field.clear} },"
    end

    def table_register(device, register, first_field:)
      count_register, count_field = register.count_from ? table_indexes(device, register.count_from) : [0, 0]
      "\t{ .name = \"#{register.name.downcase}\", .writable = #{c_integer(writable_mask(register), width: register.width)}, " \
        ".offset = #{register.offset}, .count = #{register.count}, .stride = #{register.stride}, " \
        ".first_field = #{first_field}, .field_count = #{register.fields.size}, .window = 0, .width = #{register.width}, " \
        ".access = #{ACCESS_NAMES.fetch(register.access)}, .owned_by_nif = #{register.owned_by_nif}, " \
        ".plain_update = #{plain_update?(register)}, " \
        ".preserve = #{c_integer(preserve_mask(register), width: register.width)}, " \
        ".owned = #{c_integer(owned_mask(register), width: register.width)}, " \
        ".base = #{register.cluster ? device.bases.index(register.cluster) + 1 : 0}, .counted = #{!register.count_from.nil?}, " \
        ".count_register = #{count_register}, .count_field = #{count_field}, .count_plus = #{register.count_plus} },"
    end

    # The table indexes of the register and the field a reference names: the register's in its
    # peripheral's registers, the field's in its peripheral's fields. check_references has
    # resolved every reference to a register at a fixed offset, whose name is unique.
    def table_indexes(device, ref)
      register = device.registers.index { |candidate| candidate.name == ref.register && candidate.cluster.nil? }
      first = device.registers.first(register).sum { |candidate| candidate.fields.size }
      [register, first + device.registers[register].fields.index { |field| field.name == ref.field }]
    end

    def table_device(device)
      prefix = "erx_device_#{device.name.downcase}"
      fields = device.registers.flat_map { |register| register.fields.map { |field| table_field(field, width: register.width) } }
      firsts = device.registers.reduce([0]) { |sums, register| sums + [sums.last + register.fields.size] }
      registers = device.registers.zip(firsts).map { |register, first| table_register(device, register, first_field: first) }
      firsts = device.bases.reduce([0]) { |sums, movable| sums + [sums.last + movable.instances] }
      bases = device.bases.zip(firsts).map do |movable, first|
        register, field = movable.from ? table_indexes(device, movable.from) : [0, 0]
        "\t{ .name = \"#{movable.cluster.downcase}\", .reg = #{register}, .field = #{field}, " \
          ".capability = #{movable.capability || 0}, .instances = #{movable.instances}, .first = #{first} },"
      end
      spaces = device.spaces.map do |space|
        "\t{ .name = \"#{space.name.downcase}\", .offset = #{space.offset}, .size = #{space.size}, .count = #{space.count} },"
      end
      [*table_array("erx_device_field_t #{prefix}_fields", fields),
       *table_array("erx_device_register_t #{prefix}_registers", registers),
       *table_array("erx_device_base_t #{prefix}_bases", bases),
       *table_array("erx_device_space_t #{prefix}_spaces", spaces)]
    end

    # A static array of the rows, or nothing for none, which C17 has no empty initializer for;
    # the peripheral's entry then names NULL (table_pointer).
    def table_array(declaration, rows) = rows.empty? ? [] : ["static const #{declaration}[] = {", *rows, '};', '']

    def table_pointer(name, rows) = rows.empty? ? 'NULL' : name

    def table_list(device)
      register, field = device.capabilities ? table_indexes(device, device.capabilities) : [0, 0]
      ".listed = #{!device.capabilities.nil?}, .list_reg = #{register}, .list_field = #{field}"
    end

    # Static data for the one source that includes it, erx_device_core.c.
    def device_table_header(devices)
      entries = devices.map do |device|
        prefix = "erx_device_#{device.name.downcase}"
        fields = device.registers.sum { |register| register.fields.size }
        "\t{ .name = \"#{device.name.downcase}\", .registers = #{table_pointer("#{prefix}_registers", device.registers)}, " \
          ".fields = #{table_pointer("#{prefix}_fields", Array.new(fields))}, " \
          ".window_size = #{device.size}, .register_count = #{device.registers.size}, " \
          ".field_count = #{fields}, " \
          ".derived_from = #{device.derived_from ? %("#{device.derived_from.downcase}") : 'NULL'}, " \
          ".bases = #{table_pointer("#{prefix}_bases", device.bases)}, .base_count = #{device.bases.size}, " \
          "#{table_list(device)}, .spaces = #{table_pointer("#{prefix}_spaces", device.spaces)}, " \
          ".space_count = #{device.spaces.size} },"
      end
      generated_header('ERX_HW_DEVICE_TABLE_H', [*devices.flat_map { |device| table_device(device) },
                                                 'static const erx_device_peripheral_t erx_device_peripherals[] = {',
                                                 *entries, '};', ''], includes: ['"erx/hw/device_types.h"'])
    end

    # The one volatile access of each width the table holds, for erx_device.c alone: the funnel
    # that the chokepoint device-register-access keeps.
    def device_access_header
      body = WIDTHS.flat_map do |width|
        type = "uint#{width}_t"
        ["static inline #{type}", "erx_device_access_load#{width}(volatile uint8_t *window, uint64_t offset)", '{',
         "\treturn (*(volatile #{type} *)(void *)(window + offset));", '}', '',
         'static inline void', "erx_device_access_store#{width}(volatile uint8_t *window, uint64_t offset, #{type} value)", '{',
         "\t*(volatile #{type} *)(void *)(window + offset) = value;", '}', '']
      end
      generated_header('ERX_HW_DEVICE_ACCESS_H', body, includes: ['<stdint.h>'])
    end

    # The index of each register the NIF owns, whole or in some fields, in its peripheral's
    # table, for erx_device.c alone, which the chokepoint device-owned-registers keeps. What
    # stops a driver's write to what the NIF owns is the refusal in write/3 and write_field/4 and
    # that only erx_device.c holds the raw accessors; these names keep the NIF's own sequences
    # readable and in one file.
    def device_owned_header(devices)
      body = devices.flat_map do |device|
        names = owned_symbols(device)
        owned = device.registers.each_with_index.select { |register, _| names.include?(owned_symbol(device, register)) }
        next [] if owned.empty?

        ["/* #{device.name.downcase} */",
         *owned.map { |register, index| "#define #{owned_symbol(device, register)}\t#{index}u" }, '']
      end
      generated_header('ERX_HW_DEVICE_OWNED_H',
                       ['/*', " * The registers the device NIF owns, whole or in some fields, each by its index in",
                        " * its peripheral's table: write/3 and write_field/4 refuse what it owns, and only",
                        ' * erx_device.c names them.', ' */', '', *body])
    end

    # All parsing and rendering completes before the first output is written.
    # The directory is owned by this frontend, making orphan checks explicit.
    def output_plan(root:) = render_outputs(parse_devices(svd_inputs(root: root)))

    # The plan in the shape Erx::Generated publishes into the build tree: the
    # SVD files are discovered by SVD_GLOB, so its expansion is recorded too.
    def generation(root:)
      inputs = svd_inputs(root: root)
      GenerationPlan.new(files: render_outputs(parse_devices(inputs)),
                         reads: inputs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
                         globs: { SVD_GLOB => inputs.keys })
    end

    def render_outputs(devices)
      names = devices.map { |device| device.name.downcase }
      raise Error, 'SVD device names collide' unless names.uniq == names
      raise Error, 'SVD device is named for a device table header' unless (names & DEVICE_HEADERS).empty?
      symbols = %w[ERX_MMIO_H erx_mmio erx_mmio_t] +
                devices.flat_map { |device| generated_symbols(device) + owned_symbols(device) }
      raise Error, 'SVD combined C symbols collide' unless symbols.uniq == symbols
      macros = devices.flat_map { |device| erlang_symbols(device) }
      raise Error, 'SVD combined Erlang macros collide' unless macros.uniq == macros
      tables = { 'include/erx/mmio.h' => mmio_header.freeze,
                 'include/erx/hw/device_types.h' => device_types_header(devices).freeze,
                 'include/erx/hw/device_table.h' => device_table_header(devices).freeze,
                 'include/erx/hw/device_access.h' => device_access_header.freeze,
                 'include/erx/hw/device_owned.h' => device_owned_header(devices).freeze }
      files = devices.each_with_object(tables) do |device, outputs|
        outputs[device_header_path(device)] = device_header(device).freeze
        outputs[erlang_header_path(device)] = erlang_header(device).freeze
      end
      raise Error, 'generated hardware output is not ASCII' unless files.values.all?(&:ascii_only?)

      files.freeze
    end
    private_class_method :render_outputs

    # Every device the SVD inventory describes, parsed, in path order.
    def devices(root:) = parse_devices(svd_inputs(root: root))

    # The bytes of every SVD file, keyed by its path relative to the root.
    def svd_inputs(root:)
      root = File.expand_path(root)
      inputs = Dir.glob(SVD_GLOB, base: root).sort.to_h do |relative|
        [relative, BoundedFile.read(File.join(root, relative), maximum: MAX_SVD_BYTES)]
      end
      raise Error, 'hardware input inventory is empty' if inputs.empty?

      inputs
    rescue SystemCallError => error
      raise Error, "cannot read hardware input: #{error.message}"
    end
    private_class_method :svd_inputs

    def parse_devices(inputs) = inputs.values.flat_map { |bytes| parse_peripherals(bytes) }
    private_class_method :parse_devices

    # The generated header of one device's accessors, relative to the root.
    def device_header_path(device) = "include/erx/hw/#{device.name.downcase}.h"

    # The device's Erlang header, in the generated include directory of the erx application,
    # which every application's build reaches as -include("generated/erx_hw_NAME.hrl").
    def erlang_header_path(device) = "erlang/apps/erx/include/generated/erx_hw_#{device.name.downcase}.hrl"
  end
end
