# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Builders of the external term format for liberx/erx_etf.c's tests: each
# returns the bytes of one term, without the version byte.
module EtfWire
  module_function

  def small(value) = [97, value].pack('CC')
  def int(value) = [98, value].pack('Cl>')
  def small_big(sign, magnitude) = [110, magnitude.size, sign, *magnitude].pack('C*')
  def large_big(sign, magnitude) = [111, magnitude.size, sign].pack('CNC') + magnitude.pack('C*')
  def float(value) = [70, value].pack('CG')
  def atom(name) = [119, name.bytesize].pack('CC') + name.b
  def long_atom(name) = [118, name.bytesize].pack('Cn') + name.b
  def binary(bytes) = [109, bytes.bytesize].pack('CN') + bytes.b
  def bits(bytes, trailing) = [77, bytes.bytesize, trailing].pack('CNC') + bytes.b
  def tuple(*elements) = [104, elements.size].pack('CC') + elements.join
  def large_tuple(*elements) = [105, elements.size].pack('CN') + elements.join
  def nil_ = "\x6a".b
  def string(bytes) = [107, bytes.bytesize].pack('Cn') + bytes.b
  def list(elements, tail = nil_) = [108, elements.size].pack('CN') + elements.join + tail
  def map(*pairs) = [116, pairs.size].pack('CN') + pairs.flatten.join
  def pid(node, id = 1, serial = 0, creation = 7) = "\x58".b + atom(node) + [id, serial, creation].pack('NNN')
  def ref(node, creation = 7, words = [1, 2, 3, 4]) = [90, words.size].pack('Cn') + atom(node) + [creation, *words].pack('N*')

  def fun(module_name: atom('m'), old_index: small(0), old_uniq: small(0), creator: pid('web@erxos'),
          free: [], uniq: "\x01" * 16, index: 0, arity: 0)
    [112, 0, arity].pack('CNC') + uniq.b + [index, free.size].pack('NN') +
      module_name + old_index + old_uniq + creator + free.join
  end

  def export(module_name = atom('m'), function = atom('f'), arity = small(1)) = "\x71".b + module_name + function + arity

  def record(names, values, module_name: atom('m'), name: atom('r'), flags: 1)
    [67, names.size, flags].pack('CNC') + module_name + name + names.join + values.join
  end
end

# test/fixtures/etf_driver.c, built once with the given flags, run over a
# list of requests in its format; returns one answer per request.
class EtfDriver
  SOURCES = %w[liberx/erx_etf.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c
               test/fixtures/etf_driver.c].freeze

  def initialize(root:, runner:, directory:, flags: [])
    @root = root
    @runner = runner
    @directory = directory
    @flags = flags
  end

  def check(requests)
    requests_file = File.join(@directory, 'requests')
    answers_file = File.join(@directory, 'answers')
    File.write(requests_file, requests.map { |line| "#{line}\n" }.join)
    @runner.run([program, requests_file, answers_file], name: 'etf-driver', deadline: 300)
    File.read(answers_file).lines(chomp: true).tap do |lines|
      raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size
    end
  end

  private

  def program
    @program ||= File.join(@directory, 'etf_driver').tap do |output|
      @runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                   *@flags, '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                   *SOURCES.map { |source| File.join(@root, source) }, '-o', output],
                  name: 'compile-etf-driver', deadline: 120)
    end
  end
end
