# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'strscan'

module Erx
  # Two chokepoints of the web client (docs/design-web.md, "Chokepoints"),
  # over its handwritten sources, web/src outside generated/:
  #
  # * no source writes an HTML or code sink: the DOM's HTML writers, React's
  #   escape hatch, document.write, srcdoc, the HTML parsers, eval, the
  #   Function constructor, a string handed to setTimeout or setInterval, an
  #   event handler set as an attribute, and a javascript: URL;
  # * only hrefOf (web/src/routes.ts) writes a link: the word href appears
  #   only as a .tsx attribute whose value is a call of hrefOf, nothing assigns
  #   location, and location.assign, location.replace, window.open and
  #   history's pushState and replaceState take hrefOf(...) as their URL.
  #
  # Each reads the code with its comments blanked and its strings kept, since a
  # javascript: URL or an href attribute's name can be a string. Like the other
  # text rules it catches a slip, not a sink reached through a name built from
  # pieces; where the browser enforces Trusted Types, the content security
  # policy refuses every HTML sink as well.
  module WebSinks
    SCOPE = %w[web/src/**/*.{ts,tsx,mts,cts,js,jsx,mjs,cjs}].freeze
    GENERATED = 'web/src/generated/'
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    SINKS = {
      /\bdangerouslySetInnerHTML\b/ => 'dangerouslySetInnerHTML',
      /\b(?:inner|outer)HTML\b/ => 'an innerHTML or outerHTML write',
      /\binsertAdjacentHTML\b/ => 'insertAdjacentHTML',
      /\bdocument\s*\.\s*write(?:ln)?\b|\bwriteln\b/ => 'document.write',
      /\bsrcdoc\b/i => 'srcdoc',
      /\bcreateContextualFragment\b/ => 'createContextualFragment',
      /\bDOMParser\b/ => 'DOMParser',
      /\b(?:setHTMLUnsafe|parseHTMLUnsafe)\b/ => 'setHTMLUnsafe or parseHTMLUnsafe',
      /\beval\b/ => 'eval',
      /\bFunction\s*\(/ => 'the Function constructor',
      /\bset(?:Timeout|Interval)\s*\(\s*['"`]/ => 'a string handed to setTimeout or setInterval',
      /\bsetAttribute(?:NS)?\s*\(\s*(?:[^,()]*,\s*)?['"`]on/i => 'an event handler set as an attribute',
      /javascript\s*:/i => 'a javascript: URL'
    }.freeze
    HREF = /\bhref\b/i
    HREF_OF = /\Ahref=\{\s*hrefOf\(/
    CLOSE = /\A\s*\}/
    PAREN = { '(' => 1, ')' => -1 }.freeze
    # A navigation call, whose last argument is its URL.
    NAVIGATION = /\b(?:location\s*\.\s*(?:assign|replace)|window\s*\.\s*open|history\s*\.\s*(?:push|replace)State)\s*\(/
    LOCATION_WRITE = /\blocation\s*=(?!=)/
    NESTING = { '(' => 1, '[' => 1, '{' => 1, ')' => -1, ']' => -1, '}' => -1 }.freeze

    Violation = Data.define(:path, :line, :detail) do
      def to_s = "chokepoint web-sinks: #{path}:#{line}: #{detail}"
    end

    module_function

    def covers?(path) = !path.start_with?(GENERATED) && SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # The violations among files, a map of path to source text.
    def violations(files)
      files.select { |path, _| covers?(path) }.flat_map do |path, text|
        code = code(text)
        (sinks(path, code) + hrefs(path, code) + navigations(path, code)).sort_by(&:line)
      end
    end

    def sinks(path, code)
      SINKS.flat_map do |pattern, name|
        offsets(code, pattern).map do |offset|
          Violation.new(path: path, line: line_of(code, offset), detail: "client code writes no HTML or code sink: #{name}")
        end
      end
    end

    def hrefs(path, code)
      offsets(code, HREF).filter_map do |offset|
        next if path.end_with?('.tsx') && href_of_call?(code[offset..])

        Violation.new(path: path, line: line_of(code, offset), detail: 'only hrefOf writes an href: href={hrefOf(...)}')
      end
    end

    def navigations(path, code)
      calls = offsets(code, NAVIGATION).reject { |offset| url_of_href?(code, code.index('(', offset)) }
      (calls + offsets(code, LOCATION_WRITE)).map do |offset|
        Violation.new(path: path, line: line_of(code, offset),
                      detail: 'only hrefOf writes a link: navigate to hrefOf(...) through history, never to a URL')
      end
    end

    # Whether the call whose ( is at open ends with the argument hrefOf(...):
    # the text after its last comma at the call's own level.
    def url_of_href?(code, open)
      depth = 0
      last = open + 1
      close = (open...code.size).find do |index|
        depth += NESTING.fetch(code[index], 0)
        last = index + 1 if depth == 1 && code[index] == ','
        depth.zero?
      end
      !close.nil? && href_of_call?("href={#{code[last...close].strip}}")
    end

    # Whether an attribute is href={hrefOf(...)} and nothing more: the brace
    # closes right after the parenthesis that ends the call.
    def href_of_call?(text)
      match = HREF_OF.match(text)
      return false if match.nil?

      depth = 1
      close = (match.end(0)...text.size).find do |index|
        depth += PAREN.fetch(text[index], 0)
        depth.zero?
      end
      !close.nil? && CLOSE.match?(text[close + 1..])
    end

    def offsets(code, pattern) = code.to_enum(:scan, pattern).map { Regexp.last_match.begin(0) }

    def line_of(code, offset) = code[0, offset].count("\n") + 1

    # The code with each comment blanked to spaces, its line breaks kept, and
    # everything else as written. Strings, template literals (their ${...}
    # read as code) and regular expressions are skipped whole, so a // or /*
    # inside one starts no comment. A / starts a regular expression where an
    # operand is expected: at the start, or after punctuation other than a
    # closing bracket, or after a keyword such as return.
    def code(text)
      scanner = StringScanner.new(text.b)
      out = +''
      braces = [] # one entry per open {: :template for a template's ${, :code otherwise
      until scanner.eos?
        if comment_may_start?(out) && (scanner.scan(%r{//[^\n]*}) || scanner.scan(%r{/\*.*?\*/}m))
          out << scanner.matched.gsub(/[^\n]/, ' ')
        elsif scanner.scan(/'(?:[^'\\\n]|\\.)*'?|"(?:[^"\\\n]|\\.)*"?/m)
          out << scanner.matched
        elsif scanner.check(/`/) || (scanner.check(/\}/) && braces.last == :template)
          braces.pop if scanner.peek(1) == '}'
          out << template_part(scanner, braces)
        elsif scanner.check(%r{/}) && operand_expected?(out)
          out << (scanner.scan(%r{/(?:[^/\\\[\n]|\\.|\[(?:[^\]\\\n]|\\.)*\])+/[a-z]*}) || scanner.getch)
        else
          character = scanner.getch
          braces.push(:code) if character == '{'
          braces.pop if character == '}'
          out << character
        end
      end
      out
    end

    # A template literal's text from its opening ` or a closing } up to its
    # closing ` or the next ${, whose brace is pushed as a template's.
    def template_part(scanner, braces)
      part = scanner.getch + (scanner.scan(/(?:[^`\\$]|\\.|\$(?!\{))*/m) || '')
      if scanner.scan(/\$\{/)
        braces.push(:template)
        part + '${'
      else
        part + (scanner.scan(/`/) || '')
      end
    end

    # A comment starts only at a line's start or after white space, so a // or
    # /* in JSX text (a URL, a glob) or right after a regular expression read as
    # a division is read as code, not blanked: the check errs towards a false
    # report. An unterminated /* is no comment either.
    def comment_may_start?(out) = out.empty? || out.end_with?(' ', "\t", "\n")

    def operand_expected?(out)
      before = out.rstrip
      before.empty? || before.match?(/[(\[{,;:=!&|?+\-*%<>~^\/]\z/) ||
        before.match?(/\b(?:return|typeof|case|do|else|in|of|new|delete|void|throw|yield|await)\z/)
    end
  end
end
