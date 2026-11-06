# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # What one measurement from erx_otp_bench:run/3 must say before it is believed, whether
  # stock OTP printed it or the guest did: the workload, sizes and emulator flavour that
  # were asked for, one scheduler, and one positive finite time per sample. The numbers in
  # a refusal are never echoed; a guest's text is untrusted and the reason is shown on a
  # terminal.
  module BenchMeasurement
    MD5_HEX = /\A[0-9a-f]{32}\z/

    module_function

    # Raises Erx::Error naming the first field that is wrong.
    def validate(value, workload:, iterations:, samples:, flavour:)
      reason = refusal(value, workload: workload, iterations: iterations, samples: samples, flavour: flavour)
      raise Error, "benchmark measurement #{reason}" if reason
    end

    # The first reason a measurement is refused, or nil when it is acceptable.
    def refusal(value, workload:, iterations:, samples:, flavour:)
      return 'is not a JSON object' unless value.is_a?(Hash)

      asked = { 'workload' => workload, 'iterations' => iterations, 'samples' => samples,
                'emu_flavor' => flavour, 'schedulers' => 1 }
      wrong = asked.find { |field, want| !value[field].eql?(want) }
      return "field #{wrong.first} is not the requested #{wrong.last}" if wrong

      times = value['ns_per_operation']
      if !positive_integer?(value['operations'])
        'field operations is not a positive integer'
      elsif !(value['beam_md5'].is_a?(String) && MD5_HEX.match?(value['beam_md5']))
        'field beam_md5 is not a lowercase MD5 digest'
      elsif !(times.is_a?(Array) && times.size == samples)
        'field ns_per_operation is not one number per sample'
      elsif !times.all? { |time| time.is_a?(Numeric) && time.finite? && time.positive? }
        'field ns_per_operation holds a time that is not positive and finite'
      end
    end

    def positive_integer?(value) = value.is_a?(Integer) && value.positive?
  end
end
