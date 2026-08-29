# frozen_string_literal: true

require "net/ftp"
require "uri"
require_relative "archive_name"
require_relative "ftps_error"
require_relative "print_file_hints"

module BambuCompanion
  class SdCardFileLocator
    PRINT_EXTENSION = /(?:\.gcode(?:\.3mf)?|\.3mf)\z/i
    HINT_KEYS = %w[file url gcode_file subtask_name].freeze
    LIST_BLOCK_SIZE = 64 * 1024
    LIST_ROOTS = ["/", "/cache", "/model"].freeze
    DEFAULT_MAX_ENTRIES = 10_000
    DEFAULT_MAX_BYTES = 4 * 1024 * 1024
    DEFAULT_MAX_LINE_BYTES = 16 * 1024

    def initialize(host:, max_entries: DEFAULT_MAX_ENTRIES,
                   max_bytes: DEFAULT_MAX_BYTES,
                   max_line_bytes: DEFAULT_MAX_LINE_BYTES)
      @host = String(host)
      @max_entries = positive_integer(max_entries, "max_entries")
      @max_bytes = positive_integer(max_bytes, "max_bytes")
      @max_line_bytes = positive_integer(max_line_bytes, "max_line_bytes")
    end

    def find(ftp, hints, cancelled: -> { false })
      paths = list_paths(ftp, cancelled: cancelled)
      records = hint_records(hints)

      explicit_paths = records.filter_map { |record| record[:path] }
      unless explicit_paths.empty?
        matches = unique_matches(paths, explicit_paths)
        return matches.first if matches.one?
        raise_ambiguous if matches.length > 1

        raise_not_found
      end

      exact_names = prefer_active_files(unique_basename_matches(
        paths, records.filter_map { |record| record[:basename] }
      ))
      return exact_names.first if exact_names.one?
      raise_ambiguous if exact_names.length > 1

      if PrintFileHints.internal_gcode_entry(hints)
        x2d_match = find_x2d_archive(paths, hints)
        return x2d_match if x2d_match
      end

      tokens = records.filter_map { |record| record[:token] }.uniq
      matches = prefer_active_files(
        paths.select { |path| tokens.include?(canonical_name(path)) }
      )
      return matches.first if matches.one?
      raise_ambiguous if matches.length > 1

      if PrintFileHints.internal_gcode_entry(hints)
        raise FtpsError.new(
          "file_not_found",
          "Active print archive is not exposed on external storage"
        ), cause: nil
      end

      raise_not_found
    end

    private

    def positive_integer(value, name)
      integer = Integer(value)
      raise ArgumentError, "#{name} must be positive" unless integer.positive?

      integer
    end

    def unique_matches(paths, candidates)
      unique_value_matches(paths, candidates) { |path| path }
    end

    def unique_basename_matches(paths, basenames)
      unique_value_matches(paths, basenames) { |path| File.basename(path) }
    end

    def unique_value_matches(paths, candidates)
      case_sensitive = paths.select { |path| candidates.include?(yield(path)) }
      return case_sensitive.uniq unless case_sensitive.empty?

      paths.select do |path|
        value = yield(path)
        candidates.any? { |candidate| value.casecmp?(candidate) }
      end.uniq
    end

    def prefer_active_files(matches)
      active = matches.reject { |path| path.start_with?("/model/") }
      active.empty? ? matches : active
    end

    def find_x2d_archive(paths, hints)
      values = hints.to_h
      subtask = values["subtask_name"] || values[:subtask_name]
      token = human_hint_record(subtask)&.fetch(:token, nil)
      return if token.nil? || token.empty?

      matches = prefer_active_files(
        paths.select { |path| canonical_name(path) == token }
      )
      [".gcode.3mf", ".3mf", ".gcode"].each do |extension|
        tier = matches.select { |path| File.basename(path).downcase.end_with?(extension) }
        selected = select_x2d_tier(tier)
        return selected if selected
      end
      nil
    end

    def select_x2d_tier(paths)
      return if paths.empty?

      best_rank = paths.map { |path| x2d_location_rank(path) }.min
      preferred = paths.select { |path| x2d_location_rank(path) == best_rank }
      return preferred.first if preferred.one?

      raise_ambiguous
    end

    def x2d_location_rank(path)
      return 0 if path.start_with?("/cache/")
      return 1 if File.dirname(path) == "/"

      2
    end

    def raise_ambiguous
      raise FtpsError.new(
        "ambiguous_file", "Multiple SD-card files match the active print"
      ), cause: nil
    end

    def raise_not_found
      raise FtpsError.new(
        "file_not_found", "Print file not found on SD card"
      ), cause: nil
    end

    def list_paths(ftp, cancelled:)
      paths = {}
      budget = { bytes: 0, entries: 0 }
      LIST_ROOTS.each do |root|
        stream_listing(ftp, root, budget: budget, cancelled: cancelled) do |entry|
          check_cancelled!(cancelled)

          budget[:entries] += 1
          raise_listing_too_large if budget[:entries] > @max_entries

          normalized = normalize_listing(root, entry)
          paths[normalized] = true if normalized && PRINT_EXTENSION.match?(normalized)
        end
      end
      paths.keys
    end

    def stream_listing(ftp, root, budget:, cancelled:)
      line = String.new(capacity: @max_line_bytes, encoding: Encoding::BINARY)
      check_cancelled!(cancelled)
      ftp.retrbinary("NLST #{root}", LIST_BLOCK_SIZE) do |chunk|
        check_cancelled!(cancelled)
        # Offsets below are byte offsets because listings can contain UTF-8 names
        # and are appended with byteslice into a binary buffer.
        chunk = String(chunk).b
        budget[:bytes] += chunk.bytesize
        raise_listing_too_large if budget[:bytes] > @max_bytes

        offset = 0
        while (newline = chunk.index("\n", offset))
          append_listing_segment(line, chunk, offset, newline - offset)
          line.delete_suffix!("\r")
          check_cancelled!(cancelled)
          yield line
          line.clear
          offset = newline + 1
        end
        append_listing_segment(line, chunk, offset, chunk.bytesize - offset)
      end
      unless line.empty?
        line.delete_suffix!("\r")
        check_cancelled!(cancelled)
        yield line
      end
    rescue Net::FTPError => error
      return if root != "/" && directory_missing_error?(error)

      raise
    end

    def append_listing_segment(line, chunk, offset, length)
      return if length.zero?
      raise_listing_too_large if line.bytesize + length > @max_line_bytes

      line << chunk.byteslice(offset, length)
    end

    def check_cancelled!(cancelled)
      return unless cancelled.call

      raise FtpsError.new("cancelled", "FTPS download cancelled"), cause: nil
    end

    def raise_listing_too_large
      raise FtpsError.new(
        "too_large", "SD-card listing exceeds safe limits"
      ), cause: nil
    end

    def directory_missing_error?(error)
      error.message.match?(
        /\A550\b.*\b(?:not found|no files(?: found)?|does not exist)\b/i
      )
    end

    def normalize_listing(root, entry)
      text = String(entry).dup
      text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
      return unless text.valid_encoding?

      text = text.tr("\\", "/")
      return if unsafe_text?(text)

      text = text.gsub(%r{/+}, "/")
      segments = text.split("/")
      return if segments.any? { |segment| segment == "." || segment == ".." }

      if root == "/"
        remainder = text.delete_prefix("/")
        return if remainder.empty? || remainder.include?("/")

        "/#{remainder}"
      else
        directory = root.delete_prefix("/")
        remainder = text.delete_prefix("/").delete_prefix("#{directory}/")
        return if remainder.empty? || remainder.include?("/")

        "/#{directory}/#{remainder}"
      end
    end

    def hint_records(hints)
      values = hints.to_h
      HINT_KEYS.filter_map do |key|
        value = values[key] || values[key.to_sym]
        next if value.nil?

        key == "subtask_name" ? human_hint_record(value) : path_hint_record(value)
      end
    end

    def human_hint_record(value)
      text = String(value).strip
      return if text.empty? || unsafe_text?(text)

      token = canonical_name(text)
      { token: token } unless token.empty?
    end

    def path_hint_record(value)
      text = String(value).strip
      return if text.empty? || unsafe_text?(text)

      uri = parse_uri(text)
      return if uri == false

      text = URI::RFC2396_PARSER.unescape(uri.path.to_s) if uri
      return if text.empty? || unsafe_text?(text)

      text = text.tr("\\", "/").gsub(%r{/+}, "/")
      segments = text.split("/")
      return if segments.any? { |segment| segment == "." || segment == ".." }

      sd_path = text.match(%r{\A/(?:mnt/)?sdcard(/.*)\z}i)&.captures&.first
      if uri && uri.scheme != "file"
        sd_path ||= text
      elsif uri || text.start_with?("/")
        return unless sd_path
      end

      basename = File.basename(sd_path || text)
      return unless PRINT_EXTENSION.match?(basename)

      token = canonical_name(basename)
      return if token.empty?

      {
        path: normalize_explicit_path(sd_path),
        basename: sd_path ? nil : basename,
        token: token
      }
    rescue URI::InvalidURIError
      nil
    end

    def parse_uri(text)
      return unless text.match?(/\A[a-z][a-z0-9+.-]*:/i)

      uri = URI.parse(text)
      return false unless %w[file ftp ftps].include?(uri.scheme)
      return false unless safe_uri_host?(uri)
      return false if uri.userinfo

      uri
    end

    def normalize_explicit_path(path)
      return unless path

      path.start_with?("/") ? path : "/#{path}"
    end

    def safe_uri_host?(uri)
      host = uri.host.to_s
      return host.empty? || host.casecmp?("localhost") if uri.scheme == "file"

      host.empty? || host.casecmp?(@host)
    end

    def unsafe_text?(text)
      text.match?(/[\x00-\x1f\x7f]/)
    end

    def canonical_name(value)
      ArchiveName.canonical(value)
    end
  end
end
