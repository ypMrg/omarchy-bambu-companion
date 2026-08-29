# frozen_string_literal: true

require_relative "test_helper"
require "openssl"
require "tmpdir"
require "bambu_companion/config"
require "bambu_companion/ftps_client"

class FtpsClientTest < Minitest::Test
  class FakeFtp
    attr_reader :retrieved
    attr_accessor :on_chunk
    attr_reader :closed

    def initialize(files)
      @files = files
      @retrieved = []
      @closed = false
    end

    def nlst(root)
      prefix = root == "/" ? "/" : "#{root}/"
      @files.keys.select do |path|
        remainder = path.delete_prefix(prefix)
        path.start_with?(prefix) && !remainder.include?("/")
      end
    end

    def retrlines(command)
      root = command.delete_prefix("NLST ")
      nlst(root).each { |entry| yield entry }
    end

    def retrbinary(command, block_size)
      if command.start_with?("NLST ")
        root = command.delete_prefix("NLST ")
        nlst(root).each do |entry|
          "#{entry}\r\n".scan(/.{1,#{block_size}}/m) { |chunk| yield chunk }
        end
        return
      end

      path = command.delete_prefix("RETR ")
      @retrieved << path
      @files.fetch(path).scan(/.{1,4}/m) do |chunk|
        @on_chunk&.call(chunk)
        yield chunk
      end
    end

    def size(path) = @files.fetch(path).bytesize

    def close
      @closed = true
    end
  end

  class FakeSocket
    attr_reader :close_calls

    def initialize
      @close_calls = 0
    end

    def close
      @close_calls += 1
    end

    def closed? = @close_calls.positive?
  end

  def client(files, max_bytes: 1024)
    ftp = FakeFtp.new(files)
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      max_bytes: max_bytes, ftp_factory: ->(*) { ftp }, sleeper: ->(_seconds) {}
    )
    [object, ftp]
  end

  def test_maps_sdcard_url_and_downloads_exact_cache_file
    object, ftp = client({ "/cache/Benchy.gcode.3mf" => "archive-data" })
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      remote = object.download(
        hints: { "url" => "file:///sdcard/cache/Benchy.gcode.3mf" },
        destination: destination
      )
      assert_equal "/cache/Benchy.gcode.3mf", remote
      assert_equal "archive-data", File.binread(destination)
      assert_equal [remote], ftp.retrieved
    end
  end

  def test_download_reports_streamed_bytes_against_the_remote_size
    object, = client({ "/cache/Benchy.gcode.3mf" => "archive-data" })
    updates = []

    Dir.mktmpdir do |dir|
      object.download(
        hints: { "file" => "Benchy.gcode.3mf" },
        destination: File.join(dir, "download"),
        progress: ->(loaded, total) { updates << [loaded, total] }
      )
    end

    assert_equal [0, 12], updates.first
    assert_equal [12, 12], updates.last
    assert_equal [4, 8, 12], updates.drop(1).map(&:first)
  end

  def test_download_progress_remains_usable_when_size_is_unsupported
    object, ftp = client({ "/part.gcode" => "ready" })
    ftp.define_singleton_method(:size) do |_path|
      raise Net::FTPPermError, "500 SIZE unsupported"
    end
    updates = []

    Dir.mktmpdir do |dir|
      object.download(
        hints: { "file" => "part.gcode" }, destination: File.join(dir, "download"),
        progress: ->(loaded, total) { updates << [loaded, total] }
      )
    end

    assert_equal [0, nil], updates.first
    assert_equal [5, nil], updates.last
  end

  def test_rejects_non_positive_download_bounds
    config = config_fixture

    assert_raises(ArgumentError) do
      BambuCompanion::FtpsClient.new(config: config, secret: "x", max_bytes: 0)
    end
    assert_raises(ArgumentError) do
      BambuCompanion::FtpsClient.new(config: config, secret: "x", attempts: 0)
    end
    assert_raises(ArgumentError) do
      BambuCompanion::FtpsClient.new(config: config, secret: "x", max_list_entries: 0)
    end
    assert_raises(ArgumentError) do
      BambuCompanion::FtpsClient.new(config: config, secret: "x", max_list_bytes: 0)
    end
    assert_raises(ArgumentError) do
      BambuCompanion::FtpsClient.new(config: config, secret: "x", max_list_line_bytes: 0)
    end
  end

  def test_matches_unique_human_subtask_name
    object, = client({ "/Pretty_Benchy.gcode.3mf" => "x" })
    Dir.mktmpdir do |dir|
      assert_equal "/Pretty_Benchy.gcode.3mf", object.download(
        hints: { "subtask_name" => "Pretty Benchy" },
        destination: File.join(dir, "download")
      )
    end
  end

  def test_decodes_percent_escaped_sdcard_url
    object, = client({ "/cache/Pretty Benchy.gcode.3mf" => "x" })
    Dir.mktmpdir do |dir|
      remote = object.download(
        hints: { "url" => "file:///sdcard/cache/Pretty%20Benchy.gcode.3mf" },
        destination: File.join(dir, "download")
      )

      assert_equal "/cache/Pretty Benchy.gcode.3mf", remote
    end
  end

  def test_rejects_local_absolute_path_as_a_hint
    object, ftp = client({ "/private.gcode" => "must-not-download" })

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "file" => "/home/user/private.gcode" },
        destination: "/tmp/not-written"
      )
    end

    assert_equal "file_not_found", error.code
    assert_empty ftp.retrieved
  end

  def test_rejects_percent_encoded_sdcard_traversal
    object, ftp = client({ "/private.gcode" => "must-not-download" })

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "url" => "file:///sdcard/cache/%2e%2e/private.gcode" },
        destination: "/tmp/not-written"
      )
    end

    assert_equal "file_not_found", error.code
    assert_empty ftp.retrieved
  end

  def test_rejects_unexpected_url_scheme_before_approximate_matching
    object, ftp = client({ "/private.gcode" => "must-not-download" })

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "url" => "https://example.test/private.gcode" },
        destination: "/tmp/not-written"
      )
    end

    assert_equal "file_not_found", error.code
    assert_empty ftp.retrieved
  end

  def test_rejects_ambiguous_exact_basename_across_root_and_cache
    attempts = 0
    ftp_factory = lambda do |*_args|
      attempts += 1
      FakeFtp.new("/same.gcode" => "root", "/cache/same.gcode" => "cache")
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ftp_factory
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "same.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "ambiguous_file", error.code
    assert_equal 1, attempts
  end

  def test_rejects_ambiguous_case_insensitive_exact_match
    object, = client({ "/Same.gcode" => "a", "/SAME.gcode" => "b" })

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "same.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "ambiguous_file", error.code
  end

  def test_explicit_sdcard_path_disambiguates_root_and_cache
    object, = client({ "/same.gcode" => "root", "/cache/same.gcode" => "cache" })
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      remote = object.download(
        hints: { "file" => "/sdcard/cache/same.gcode" },
        destination: destination
      )

      assert_equal "/cache/same.gcode", remote
      assert_equal "cache", File.binread(destination)
    end
  end

  def test_missing_explicit_sdcard_path_never_falls_back_by_name_or_type
    object, ftp = client({
      "/model.gcode.3mf" => "wrong-location",
      "/cache/model.gcode" => "wrong-type"
    })

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "url" => "file:///sdcard/cache/model.gcode.3mf" },
        destination: "/tmp/not-written"
      )
    end

    assert_equal "file_not_found", error.code
    assert_empty ftp.retrieved
  end

  def test_rejects_ambiguous_approximate_match
    object, = client({
      "/Part One.gcode" => "a", "/cache/Part-One.gcode.3mf" => "b"
    })
    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "subtask_name" => "Part One" },
        destination: "/tmp/not-written"
      )
    end
    assert_equal "ambiguous_file", error.code
  end

  def test_x2d_internal_entry_prefers_sliced_archive_over_project_archive
    object, = client({
      "/Untitled.3mf" => "project", "/Untitled.gcode.3mf" => "sliced"
    })
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      remote = object.download(
        hints: {
          "file" => "/data/Metadata/plate_1.gcode",
          "gcode_file" => "/data/Metadata/plate_1.gcode",
          "subtask_name" => "Untitled", "plate_idx" => 1
        },
        destination: destination
      )

      assert_equal "/Untitled.gcode.3mf", remote
      assert_equal "sliced", File.binread(destination)
    end
  end

  def test_x2d_internal_entry_falls_back_to_project_archive
    object, = client({ "/Untitled.3mf" => "project" })
    Dir.mktmpdir do |dir|
      remote = object.download(
        hints: {
          "gcode_file" => "/data/Metadata/plate_1.gcode",
          "subtask_name" => "Untitled"
        },
        destination: File.join(dir, "download")
      )

      assert_equal "/Untitled.3mf", remote
    end
  end

  def test_x2d_internal_entry_matches_unicode_print_name
    object, = client({ "/cache/模型.gcode.3mf" => "sliced" })
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      remote = object.download(
        hints: {
          "gcode_file" => "/data/Metadata/plate_1.gcode",
          "subtask_name" => "模型"
        },
        destination: destination
      )

      assert_equal "/cache/模型.gcode.3mf", remote
      assert_equal "sliced", File.binread(destination)
    end
  end

  def test_x2d_missing_external_archive_has_actionable_error
    object, = client({})

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: {
          "gcode_file" => "/data/Metadata/plate_1.gcode",
          "subtask_name" => "Untitled"
        },
        destination: "/tmp/not-written"
      )
    end

    assert_equal "file_not_found", error.code
    assert_equal "Active print archive is not exposed on external storage", error.message
  end

  def test_x2d_internal_entry_prefers_active_cache_copy_over_root_duplicate
    object, = client({
      "/Untitled.gcode.3mf" => "root",
      "/cache/Untitled.gcode.3mf" => "cache"
    })

    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      remote = object.download(
        hints: {
          "gcode_file" => "/data/Metadata/plate_1.gcode",
          "subtask_name" => "Untitled"
        },
        destination: destination
      )

      assert_equal "/cache/Untitled.gcode.3mf", remote
      assert_equal "cache", File.binread(destination)
    end
  end

  def test_x2d_internal_entry_keeps_duplicates_in_cache_ambiguous
    object, = client({
      "/cache/Untitled.gcode.3mf" => "first",
      "/cache/untitled.gcode.3mf" => "second"
    })

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: {
          "gcode_file" => "/data/Metadata/plate_1.gcode",
          "subtask_name" => "Untitled"
        },
        destination: "/tmp/not-written"
      )
    end

    assert_equal "ambiguous_file", error.code
  end

  def test_x2d_internal_entry_does_not_select_extracted_plate_gcode_first
    object, = client({
      "/plate_1.gcode" => "extracted", "/Untitled.gcode.3mf" => "sliced"
    })
    Dir.mktmpdir do |dir|
      remote = object.download(
        hints: {
          "file" => "/data/Metadata/plate_1.gcode",
          "subtask_name" => "Untitled"
        },
        destination: File.join(dir, "download")
      )

      assert_equal "/Untitled.gcode.3mf", remote
    end
  end

  def test_stops_before_exceeding_download_limit
    object, = client({ "/large.gcode" => "x" * 20 }, max_bytes: 10)
    Dir.mktmpdir do |dir|
      error = assert_raises(BambuCompanion::FtpsError) do
        object.download(
          hints: { "file" => "large.gcode" },
          destination: File.join(dir, "download")
        )
      end
      assert_equal "too_large", error.code
      refute_path_exists File.join(dir, "download")
      assert_empty Dir.children(dir)
    end
  end

  def test_accepts_a_file_exactly_at_the_download_limit
    object, = client({ "/exact.gcode" => "x" * 8 }, max_bytes: 8)
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")

      object.download(hints: { "file" => "exact.gcode" }, destination: destination)

      assert_equal "x" * 8, File.binread(destination)
    end
  end

  def test_cancellation_before_connecting_does_not_open_ftps
    connections = 0
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { connections += 1 }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "file" => "ignored.gcode" }, destination: "/tmp/not-written",
        cancelled: -> { true }
      )
    end

    assert_equal "cancelled", error.code
    assert_equal 0, connections
  end

  def test_cancellation_during_transfer_removes_partial_file_and_closes_ftps
    object, ftp = client({ "/cancel.gcode" => "abcdefgh" })
    cancelled = false
    ftp.on_chunk = ->(_chunk) { cancelled = true }

    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      error = assert_raises(BambuCompanion::FtpsError) do
        object.download(
          hints: { "file" => "cancel.gcode" }, destination: destination,
          cancelled: -> { cancelled }
        )
      end

      assert_equal "cancelled", error.code
      refute_path_exists destination
      assert_empty Dir.children(dir)
      assert ftp.closed
    end
  end

  def test_failed_download_preserves_existing_destination_and_cleans_tempfile
    object, = client({ "/large.gcode" => "x" * 20 }, max_bytes: 10)
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      File.binwrite(destination, "previous")

      assert_raises(BambuCompanion::FtpsError) do
        object.download(hints: { "file" => "large.gcode" }, destination: destination)
      end

      assert_equal "previous", File.binread(destination)
      assert_equal ["download"], Dir.children(dir)
    end
  end

  def test_success_atomically_replaces_destination_with_private_file
    object, = client({ "/replacement.gcode" => "new-data" })
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      File.binwrite(destination, "old-data")
      File.chmod(0o644, destination)

      object.download(hints: { "file" => "replacement.gcode" }, destination: destination)

      assert_equal "new-data", File.binread(destination)
      assert_equal 0o600, File.stat(destination).mode & 0o777
      assert_equal ["download"], Dir.children(dir)
    end
  end

  def test_transport_error_never_exposes_secret_and_retries_three_times
    attempts = 0
    secret = "secret-sentinel"
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: secret,
      ftp_factory: lambda do |*_args|
        attempts += 1
        raise IOError, "authentication rejected #{secret}"
      end,
      sleeper: ->(_seconds) {}
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "part.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "transport", error.code
    refute_includes error.message, secret
    assert_nil error.cause
    refute_includes error.full_message, secret
    assert_equal 3, attempts
  end

  def test_close_failure_does_not_mask_success
    ftp_class = Class.new(FakeFtp) do
      def close = raise(IOError, "close failed")
    end
    ftp = ftp_class.new("/part.gcode" => "ready")
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }
    )

    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      assert_equal "/part.gcode", object.download(
        hints: { "file" => "part.gcode" }, destination: destination
      )
      assert_equal "ready", File.binread(destination)
    end
  end

  def test_retries_a_temporarily_missing_file_three_times
    attempts = 0
    ftp_factory = lambda do |*_args|
      attempts += 1
      FakeFtp.new(attempts < 3 ? {} : { "/late.gcode" => "ready" })
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ftp_factory, sleeper: ->(_seconds) {}
    )
    Dir.mktmpdir do |dir|
      remote = object.download(
        hints: { "file" => "late.gcode" },
        destination: File.join(dir, "download")
      )
      assert_equal "/late.gcode", remote
      assert_equal 3, attempts
    end
  end

  def test_retry_delays_are_bounded_and_linear
    delays = []
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { FakeFtp.new({}) }, sleeper: ->(seconds) { delays << seconds }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "missing.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "file_not_found", error.code
    assert_equal [0.75, 1.5], delays
  end

  def test_cancellation_after_retry_delay_prevents_another_connection
    connections = 0
    cancelled = false
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: lambda do |*_args|
        connections += 1
        FakeFtp.new({})
      end,
      sleeper: ->(_seconds) { cancelled = true }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "file" => "missing.gcode" }, destination: "/tmp/not-written",
        cancelled: -> { cancelled }
      )
    end

    assert_equal "cancelled", error.code
    assert_equal 1, connections
  end

  def test_factory_receives_config_and_same_in_memory_secret
    received = nil
    config = config_fixture
    secret = "session-secret"
    ftp = FakeFtp.new("/part.gcode" => "ready")
    object = BambuCompanion::FtpsClient.new(
      config: config, secret: secret,
      ftp_factory: lambda do |received_config, received_secret|
        received = [received_config, received_secret]
        ftp
      end
    )

    Dir.mktmpdir do |dir|
      object.download(
        hints: { "file" => "part.gcode" }, destination: File.join(dir, "download")
      )
    end

    assert_same config, received.first
    assert_same secret, received.last
  end

  def test_default_factory_uses_implicit_private_ftps_and_explicit_timeouts
    config = config_fixture
    secret = "session-secret"
    calls = []
    connection = Object.new
    connection.define_singleton_method(:connect) { |host, port| calls << [:connect, host, port] }
    connection.define_singleton_method(:login) { |user, password| calls << [:login, user, password] }
    connection.define_singleton_method(:sendcmd) { |command| calls << [:sendcmd, command]; "200 \n" }
    options = nil
    constructor = lambda do |host = nil, passed_options = nil, **keywords|
      options = keywords.empty? ? passed_options : keywords
      calls << [:new, host]
      connection
    end
    object = BambuCompanion::FtpsClient.new(config: config, secret: secret)

    opened = with_ftp_constructor(constructor) do
      object.send(:open_ftp, config, secret)
    end

    assert_same connection, opened
    assert_equal [
      [:new, nil], [:connect, "192.168.1.50", 990],
      [:login, "bblp", secret], [:sendcmd, "PBSZ 0"], [:sendcmd, "PROT P"]
    ], calls
    assert_equal({}, options[:ssl])
    assert_equal true, options[:implicit_ftps]
    assert_equal false, options[:private_data_connection]
    assert_equal true, opened.instance_variable_get(:@private_data_connection)
    assert_equal true, options[:passive]
    assert_equal 8, options[:open_timeout]
    assert_equal 8, options[:ssl_handshake_timeout]
    assert_equal 30, options[:read_timeout]
  end

  def test_default_ftp_context_requires_the_pinned_leaf_on_all_tls_sessions
    config = config_fixture
    object = BambuCompanion::FtpsClient.new(
      config: config, secret: "session-secret"
    )

    ftp = object.send(:build_ftp, config)
    context = ftp.instance_variable_get(:@ssl_context)

    assert_equal OpenSSL::SSL::VERIFY_PEER, context.verify_mode
    assert context.verify_callback
    assert_includes ftp.singleton_class.ancestors,
                    BambuCompanion::PinnedFtpsTransport
  end

  def test_default_factory_closes_connection_when_protection_setup_fails
    config = config_fixture
    closed = false
    connection = Object.new
    connection.define_singleton_method(:connect) { |_host, _port| true }
    connection.define_singleton_method(:login) { |_user, _password| true }
    connection.define_singleton_method(:sendcmd) do |_command|
      raise Net::FTPReplyError, "332 "
    end
    connection.define_singleton_method(:close) { closed = true }
    constructor = ->(*_args, **_keywords) { connection }
    object = BambuCompanion::FtpsClient.new(config: config, secret: "session-secret")

    assert_raises(Net::FTPReplyError) do
      with_ftp_constructor(constructor) do
        object.send(:open_ftp, config, "session-secret")
      end
    end

    assert closed
  end

  def test_default_factory_closes_connection_when_login_fails
    config = config_fixture
    connection = Object.new
    closed = false
    connection.define_singleton_method(:connect) { |_host, _port| true }
    connection.define_singleton_method(:login) do |_user, _password|
      raise IOError, "login rejected"
    end
    connection.define_singleton_method(:close) { closed = true }
    constructor = ->(*_args, **_keywords) { connection }
    object = BambuCompanion::FtpsClient.new(config: config, secret: "session-secret")

    assert_raises(IOError) do
      with_ftp_constructor(constructor) do
        object.send(:open_ftp, config, "session-secret")
      end
    end

    assert closed
  end

  def test_handshake_failure_closes_each_ftp_and_raw_socket_across_retries
    config = config_fixture
    secret = "handshake-secret"
    raw_sockets = []
    ftp_close_calls = []
    real_constructor = Net::FTP.method(:new)
    constructor = lambda do |host = nil, passed_options = nil, **keywords|
      options = keywords.empty? ? passed_options : keywords
      ftp = real_constructor.call(host, options)
      raw_socket = FakeSocket.new
      raw_sockets << raw_socket
      ftp.define_singleton_method(:connect) do |_configured_host, _port|
        instance_variable_set(:@bare_sock, raw_socket)
        raise OpenSSL::SSL::SSLError, "handshake rejected #{secret}"
      end
      ftp.define_singleton_method(:close) do
        ftp_close_calls << self
        super()
      end
      ftp
    end
    object = BambuCompanion::FtpsClient.new(
      config: config, secret: secret, sleeper: ->(_seconds) {}
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      with_ftp_constructor(constructor) do
        object.download(
          hints: { "file" => "part.gcode" }, destination: "/tmp/not-written"
        )
      end
    end

    assert_equal "transport", error.code
    assert_nil error.cause
    refute_includes error.full_message, secret
    assert_equal 3, ftp_close_calls.length
    assert_equal 3, raw_sockets.length
    assert raw_sockets.all?(&:closed?)
  end

  def test_normalizes_relative_root_and_cache_listings
    ftp_class = Class.new(FakeFtp) do
      def nlst(root)
        root == "/" ? ["root.gcode", "notes.txt"] : ["cache/archive.3mf"]
      end
    end
    ftp = ftp_class.new("/root.gcode" => "root", "/cache/archive.3mf" => "archive")
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }
    )

    Dir.mktmpdir do |dir|
      remote = object.download(
        hints: { "file" => "archive.3mf" }, destination: File.join(dir, "download")
      )

      assert_equal "/cache/archive.3mf", remote
    end
  end

  def test_searches_the_printer_model_directory_for_builtin_jobs
    ftp_class = Class.new(FakeFtp) do
      def nlst(root)
        return ["A1 Mini Version.3mf"] if root == "/model"

        []
      end
    end
    ftp = ftp_class.new("/model/A1 Mini Version.3mf" => "archive")
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }, sleeper: ->(_seconds) {}
    )

    Dir.mktmpdir do |dir|
      remote = object.download(
        hints: { "subtask_name" => "A1 Mini Version" },
        destination: File.join(dir, "download")
      )

      assert_equal "/model/A1 Mini Version.3mf", remote
    end
  end

  def test_builtin_model_directory_is_only_a_fallback_for_duplicate_names
    ftp = FakeFtp.new(
      "/cache/current.3mf" => "active archive",
      "/model/current.3mf" => "built-in archive"
    )
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }, sleeper: ->(_seconds) {}
    )

    Dir.mktmpdir do |dir|
      destination = File.join(dir, "download")
      remote = object.download(
        hints: { "subtask_name" => "current" }, destination: destination
      )

      assert_equal "/cache/current.3mf", remote
      assert_equal "active archive", File.binread(destination)
    end
  end

  def test_root_listing_failure_retries_transport_without_using_cache_match
    attempts = 0
    cache_listings = 0
    ftp_class = Class.new(FakeFtp) do
      define_method(:nlst) do |root|
        if root == "/"
          raise Net::FTPTempError, "421 control connection lost"
        end

        cache_listings += 1
        ["/cache/part.gcode"]
      end
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: lambda do |*_args|
        attempts += 1
        ftp_class.new("/cache/part.gcode" => "wrong")
      end,
      sleeper: ->(_seconds) {}
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "part.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "transport", error.code
    assert_nil error.cause
    assert_equal 3, attempts
    assert_equal 0, cache_listings
  end

  def test_missing_cache_listing_is_optional_only_for_recognized_550
    ftp_class = Class.new(FakeFtp) do
      def nlst(root)
        return ["/part.gcode"] if root == "/"

        raise Net::FTPPermError, "550 /cache: No files found"
      end
    end
    ftp = ftp_class.new("/part.gcode" => "ready")
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }
    )

    Dir.mktmpdir do |dir|
      remote = object.download(
        hints: { "file" => "part.gcode" }, destination: File.join(dir, "download")
      )

      assert_equal "/part.gcode", remote
    end
  end

  def test_cache_permission_error_is_transport_not_an_empty_listing
    attempts = 0
    ftp_class = Class.new(FakeFtp) do
      def nlst(root)
        return [] if root == "/"

        raise Net::FTPPermError, "550 Permission denied"
      end
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: lambda do |*_args|
        attempts += 1
        ftp_class.new({})
      end,
      sleeper: ->(_seconds) {}
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "part.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "transport", error.code
    assert_equal 3, attempts
  end

  def test_ignores_hostile_listing_entries
    ftp_class = Class.new(FakeFtp) do
      def nlst(root)
        root == "/" ? ["../private.gcode", "safe.txt"] : ["cache/../private.gcode"]
      end
    end
    ftp = ftp_class.new("/private.gcode" => "must-not-download")
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }, sleeper: ->(_seconds) {}
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "private.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "file_not_found", error.code
    assert_empty ftp.retrieved
  end

  def test_streaming_listing_entry_limit_uses_public_too_large_code
    ftp = FakeFtp.new({})
    yielded = 0
    block_sizes = []
    ftp.define_singleton_method(:retrlines) { |_command| raise "retrlines must not be used" }
    ftp.define_singleton_method(:retrbinary) do |_command, block_size, &block|
      block_sizes << block_size
      100.times do |index|
        yielded += 1
        block.call("/part-#{index}.gcode\n")
      end
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      max_list_entries: 3, ftp_factory: ->(*) { ftp }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "part.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "too_large", error.code
    assert_nil error.cause
    assert_equal 4, yielded
    assert_equal [64 * 1024], block_sizes
    assert_empty ftp.retrieved
    assert ftp.closed
  end

  def test_streaming_listing_cancels_after_first_chunk
    ftp = FakeFtp.new({})
    yielded = 0
    cancelled = false
    ftp.define_singleton_method(:retrlines) { |_command| raise "retrlines must not be used" }
    ftp.define_singleton_method(:retrbinary) do |_command, _block_size, &block|
      yielded += 1
      block.call("/first.gcode\n")
      cancelled = true
      yielded += 1
      block.call("/second.gcode\n")
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "file" => "part.gcode" }, destination: "/tmp/not-written",
        cancelled: -> { cancelled }
      )
    end

    assert_equal "cancelled", error.code
    assert_nil error.cause
    assert_equal 2, yielded
    assert_empty ftp.retrieved
    assert ftp.closed
  end

  def test_streaming_listing_rejects_oversized_unterminated_line
    ftp = FakeFtp.new({})
    yielded = 0
    ftp.define_singleton_method(:retrlines) { |_command| raise "retrlines must not be used" }
    ftp.define_singleton_method(:retrbinary) do |_command, _block_size, &block|
      yielded += 1
      block.call("x" * 17)
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      max_list_line_bytes: 16, ftp_factory: ->(*) { ftp }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "part.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "too_large", error.code
    assert_nil error.cause
    assert_equal 1, yielded
    assert ftp.closed
  end

  def test_streaming_listing_rejects_total_byte_overflow
    ftp = FakeFtp.new({})
    yielded = 0
    ftp.define_singleton_method(:retrlines) { |_command| raise "retrlines must not be used" }
    ftp.define_singleton_method(:retrbinary) do |_command, _block_size, &block|
      yielded += 1
      block.call("abcd")
      yielded += 1
      block.call("efghi")
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      max_list_bytes: 8, max_list_line_bytes: 32, ftp_factory: ->(*) { ftp }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(hints: { "file" => "part.gcode" }, destination: "/tmp/not-written")
    end

    assert_equal "too_large", error.code
    assert_nil error.cause
    assert_equal 2, yielded
    assert ftp.closed
  end

  def test_cancellation_after_empty_root_prevents_cache_listing
    ftp = FakeFtp.new({})
    cancelled = false
    root_listings = 0
    cache_listings = 0
    ftp.define_singleton_method(:retrlines) { |_command| raise "retrlines must not be used" }
    ftp.define_singleton_method(:retrbinary) do |command, _block_size|
      if command == "NLST /"
        root_listings += 1
        cancelled = true
      else
        cache_listings += 1
      end
    end
    object = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret",
      ftp_factory: ->(*) { ftp }
    )

    error = assert_raises(BambuCompanion::FtpsError) do
      object.download(
        hints: { "file" => "part.gcode" }, destination: "/tmp/not-written",
        cancelled: -> { cancelled }
      )
    end

    assert_equal "cancelled", error.code
    assert_equal 1, root_listings
    assert_equal 0, cache_listings
    assert ftp.closed
  end

  private

  def with_ftp_constructor(constructor)
    singleton = Net::FTP.singleton_class
    original = Net::FTP.method(:new)
    singleton.send(:define_method, :new, constructor)
    yield
  ensure
    singleton.send(:define_method, :new, original)
  end
end
