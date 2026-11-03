# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'digest'

# Synthetic records exercise source shape without claiming to be Arm data.
module SysregFixture
  module_function

  def record
    { '_type' => 'Register', 'state' => 'AArch64', 'name' => 'COUNTER_EL0',
      '_meta' => { 'license' => { 'copyright' => 'Synthetic test fixture', 'info' => 'BSD 3-clause fixture' },
                   'version' => { 'schema' => '2.9.6' } },
      'fieldsets' => [{ 'condition' => { '_type' => 'AST.Bool', 'value' => true }, 'width' => 64,
                        'values' => [{ '_type' => 'Fields.Field', 'name' => 'Count', 'access' => nil,
                                       'rangeset' => [{ '_type' => 'Range', 'start' => 0, 'width' => 64 }],
                                       'values' => { '_type' => 'Valuesets.Values', 'values' => [] } }] }],
      'accessors' => [{ 'name' => 'A64.MRS', 'encoding' => [{ '_type' => 'Encoding', 'asmvalue' => 'COUNTER_EL0',
                         'encodings' => { 'op0' => { 'value' => "'11'" }, 'op1' => { 'value' => "'011'" },
                                          'CRn' => { 'value' => "'1110'" }, 'CRm' => { 'value' => "'0000'" },
                                          'op2' => { 'value' => "'010'" } } }] }] }
  end

  def policy(bytes)
    { 'version' => 1, 'architecture' => 'aarch64', 'source_sha256' => Digest::SHA256.hexdigest(bytes),
      'registers' => [{ 'name' => 'COUNTER_EL0', 'read' => true, 'write' => false,
                       'read_side_effect' => 'none', 'read_barrier' => 'isb' }] }
  end
end
