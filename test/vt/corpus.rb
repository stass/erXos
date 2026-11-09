# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The corpus of erx_vt's differential test against libvterm
# (docs/design-display.md, "The oracle"): a case for every row of the
# design's tables, each parameter omitted, 0, 1, at the grid's edge and past
# it, and a case for each detail the tables leave open. Every case runs on a
# fresh 10 by 4 terminal whose rows are first filled with letters, so an
# edit shows, and the cursor put at row 2, column 5; after the case's bytes
# `x` is printed, so where the cursor went shows in the cells too.
module VtCorpus
  Case = Data.define(:name, :bytes)
  COLS = 10
  ROWS = 4
  FILL = "\e[H#{%w[abcdefghij klmnopqrst uvwxyz0123 456789ABCD].join("\r\n")}\e[2;5H".b

  # The final bytes of the CSI rows, by the parameters each is tried with.
  CURSOR = %w[@ A B C D E F G ` I Z L M P S T X a e d].freeze
  ONE = [nil, '0', '1', '4', '10', '99'].freeze

  module_function

  def cases
    [*cursor_cases, *position_cases, *erase_cases, *sgr_cases, *mode_cases, *escape_cases,
     *control_cases, *report_cases, *region_cases, *string_cases, *text_cases, *choice_cases]
      .map { |kase| Case.new(name: kase.name, bytes: (FILL + kase.bytes + 'x').b) }
  end

  # The corpus as the script test/vt/vterm_dump.c and erx_vt_oracle read.
  def script(cases)
    cases.map { |kase| "new #{COLS} #{ROWS}\nfeed #{kase.bytes.bytesize}\n".b + kase.bytes + "dump\n".b }.join.b
  end

  def csi(name, final, params) = Case.new(name: name, bytes: "\e[#{params}#{final}")

  def cursor_cases
    CURSOR.flat_map { |final| ONE.map { |p| csi("csi-#{final}-#{p || 'none'}", final, p) } }
  end

  def position_cases
    %w[H f].flat_map do |final|
      [nil, '0;0', '1;1', '3', ';7', '4;10', '99;99'].map { |p| csi("csi-#{final}-#{p || 'none'}", final, p) }
    end
  end

  def erase_cases
    %w[J K].flat_map { |final| [nil, '0', '1', '2', '3'].map { |p| csi("csi-#{final}-#{p || 'none'}", final, p) } } +
      [nil, '0', '3'].map { |p| Case.new(name: "csi-g-#{p || 'none'}", bytes: "\e[#{p}g\r\tT\tT") }
  end

  def sgr_cases
    codes = %w[0 1 2 3 4 5 7 8 9 21 22 23 24 25 27 28 29 30 37 39 40 47 49 90 97 100 107
               38;5;196 48;5;21 38;2;1;2;3 48;2;255;0;128 38;5 38;2;1 1;31;42 4:3 38:5:1 58;5;1]
    codes.map { |code| Case.new(name: "sgr-#{code}", bytes: "\e[#{code}mAB\e[m") }
  end

  def mode_cases
    [Case.new(name: 'sm-4', bytes: "\e[4hAB\e[4l"), Case.new(name: 'sm-20', bytes: "\e[20h\nA\e[20l"),
     *%w[1 5 6 7 25 1049 2004].map { |mode| Case.new(name: "decset-#{mode}", bytes: "\e[?#{mode}hAB") },
     *%w[1 5 6 7 25 1049 2004].map { |mode| Case.new(name: "decrst-#{mode}", bytes: "\e[?#{mode}h\e[?#{mode}lAB") },
     Case.new(name: 'decrst-7-print', bytes: "\e[?7l\e[2;8HABCDE"),
     Case.new(name: 'decset-1049-back', bytes: "\e[?1049hAB\e[?1049lC")]
  end

  def escape_cases
    [Case.new(name: 'esc-7-8', bytes: "\e[1m\e7\e[4;9H\e[m\e8A"), Case.new(name: 'esc-D', bytes: "\e[4;3H\eDA"),
     Case.new(name: 'esc-E', bytes: "\eEA"), Case.new(name: 'esc-M', bytes: "\e[1;3H\eMA"),
     Case.new(name: 'esc-H', bytes: "\e[1;3H\eH\r\tA"), Case.new(name: 'esc-c', bytes: "\e[1m\e[?25l\ecA"),
     Case.new(name: 'esc-=', bytes: "\e=\e>A"), Case.new(name: 'esc-(0', bytes: "\e(0`aqx_\e(BA"),
     Case.new(name: 'esc-)0', bytes: "\e)0\x0eq\x0fq"), Case.new(name: 'esc-(A', bytes: "\e(A#\e(B#"),
     Case.new(name: 'esc-#8', bytes: "\e#8"), Case.new(name: 'esc-%G', bytes: "\e%GA"),
     Case.new(name: 'csi-s-u', bytes: "\e[s\e[4;9H\e[uA"), Case.new(name: 'decstr', bytes: "\e[1m\e[?6h\e[!pA")]
  end

  def control_cases
    [Case.new(name: 'c0-bel', bytes: "\aA"), Case.new(name: 'c0-bs', bytes: "\b\bA\e[H\bB"),
     Case.new(name: 'c0-ht', bytes: "\tA\t\t\tB"), Case.new(name: 'c0-lf', bytes: "\nA\n\n\nB"),
     Case.new(name: 'c0-vt-ff', bytes: "\vA\fB"), Case.new(name: 'c0-cr', bytes: "\rA"),
     Case.new(name: 'c1-ind', bytes: "\u0084A"), Case.new(name: 'c1-csi', bytes: "\u009b3GA")]
  end

  def report_cases
    [Case.new(name: 'dsr-5', bytes: "\e[5n"), Case.new(name: 'dsr-6', bytes: "\e[6n"),
     Case.new(name: 'dsr-6-origin', bytes: "\e[2;3r\e[?6h\e[2;2H\e[6n"),
     Case.new(name: 'da', bytes: "\e[c"), Case.new(name: 'da-0', bytes: "\e[0c"),
     Case.new(name: 'da2', bytes: "\e[>c")]
  end

  def region_cases
    [nil, '2;3', '1;4', '3;2', '0;0', '2;99'].map do |p|
      Case.new(name: "csi-r-#{p || 'none'}", bytes: "\e[#{p}r\e[3;1H\n\n\nA")
    end + [Case.new(name: 'csi-r-origin', bytes: "\e[2;3r\e[?6h\e[9;9HA")]
  end

  def string_cases
    [Case.new(name: 'osc-0', bytes: "\e]0;title\aA"), Case.new(name: 'osc-2', bytes: "\e]2;title\e\\A"),
     Case.new(name: 'osc-8', bytes: "\e]8;;erx:pid/%3C0.1.0%3E\e\\AB\e]8;;\e\\C"),
     Case.new(name: 'osc-unknown', bytes: "\e]52;c;aGk=\aA"),
     Case.new(name: 'dcs', bytes: "\eP1$qm\e\\A"), Case.new(name: 'osc-long', bytes: "\e]2;#{'t' * 5000}\aA")]
  end

  def text_cases
    [Case.new(name: 'wrap', bytes: 'ABCDEFGHIJKL'), Case.new(name: 'wrap-last-row', bytes: "\e[4;9HABCD"),
     Case.new(name: 'wide', bytes: "\u4e2d\u6587A"), Case.new(name: 'wide-last-column', bytes: "\e[2;10H\u4e2d"),
     Case.new(name: 'wide-overwrite-half', bytes: "\u4e2d\e[DA"), Case.new(name: 'combining', bytes: "e\u0301A"),
     Case.new(name: 'combining-after-move', bytes: "e\e[C\u0301"), Case.new(name: 'ill-formed-utf8', bytes: "\xC3A\xE4\xB8".b),
     Case.new(name: 'insert-wide', bytes: "\u4e2d\e[D\e[D\e[@")]
  end

  # The details the tables leave open (TODO.md, erx_vt).
  def choice_cases
    [Case.new(name: 'choice-can-in-osc', bytes: "\e]2;ti\x18A"), Case.new(name: 'choice-sub-in-csi', bytes: "\e[3\x1aA"),
     Case.new(name: 'choice-del-in-osc', bytes: "\e]8;;\x7f\e\\A"), Case.new(name: 'choice-del-in-csi', bytes: "\e[1\x7fCA"),
     Case.new(name: 'choice-nbsp-in-csi', bytes: "\e[1\u00a0CA"),
     Case.new(name: 'choice-decom-homes', bytes: "\e[2;3r\e[4;4H\e[?6h"),
     Case.new(name: 'choice-decom-reset-homes', bytes: "\e[?6h\e[3;3H\e[?6l"),
     Case.new(name: 'choice-decawm-reset-pending', bytes: "\e[2;10HA\e[?7lB"),
     Case.new(name: 'choice-il-column', bytes: "\e[L"), Case.new(name: 'choice-dl-column', bytes: "\e[M"),
     Case.new(name: 'choice-vpa-origin', bytes: "\e[2;3r\e[?6h\e[2d"),
     Case.new(name: 'choice-1049h-on-alt', bytes: "\e[?1049hAB\e[?1049hC"),
     Case.new(name: 'choice-1049l-on-main', bytes: "\e[?1049lA"),
     Case.new(name: 'choice-decstr-cursor', bytes: "\e[3;7H\e[!p"),
     Case.new(name: 'choice-erase-end-unwraps', bytes: "\e[3;1HABCDEFGHIJKL\e[3;5H\e[K"),
     Case.new(name: 'choice-dec-graphics-underscore', bytes: "\e(0_\e(B")]
  end
end
