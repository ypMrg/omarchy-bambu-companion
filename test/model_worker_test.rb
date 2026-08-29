# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "timeout"
require "tmpdir"
require "fileutils"
require "zip"
require "zlib"
require "bambu_companion/ftps_client"
require "bambu_companion/gcode_parser"
require "bambu_companion/gcode_source"
require "bambu_companion/print_preview_loader"
require "bambu_companion/three_mf_preview"
require "bambu_companion/model_worker"

class ModelWorkerTest < Minitest::Test
  TIMEOUT = 2

  def setup
    @geometry_directory = Dir.mktmpdir("bambu-model-worker")
  end

  def teardown
    FileUtils.rm_rf(@geometry_directory)
  end

  class Emitter
    def initialize
      @events = []
      @mutex = Mutex.new
      @notifications = Queue.new
    end

    def emit(event, payload = {})
      record = [event, payload]
      @mutex.synchronize { @events << record }
      @notifications << record
      true
    end

    def events = @mutex.synchronize { @events.dup }

    def wait_for(name, generation: nil)
      Timeout.timeout(TIMEOUT) do
        loop do
          event, payload = @notifications.pop
          return [event, payload] if event == name &&
                                     (generation.nil? || payload[:generation] == generation)
        end
      end
    end
  end

  class StatusCollector
    def initialize
      @snapshots = []
      @mutex = Mutex.new
      @notifications = Queue.new
    end

    def call(snapshot)
      @mutex.synchronize { @snapshots << snapshot }
      @notifications << snapshot
    end

    def snapshots = @mutex.synchronize { @snapshots.dup }

    def wait_for(status, generation: nil)
      Timeout.timeout(TIMEOUT) do
        loop do
          snapshot = @notifications.pop
          return snapshot if snapshot[:status] == status &&
                             (generation.nil? || snapshot[:generation] == generation)
        end
      end
    end
  end

  class InstrumentedMutex
    attr_reader :attempts, :paused, :release

    def initialize(pause_at: nil)
      @mutex = Mutex.new
      @counter_mutex = Mutex.new
      @attempt_count = 0
      @pause_at = pause_at
      @attempts = Queue.new
      @paused = Queue.new
      @release = Queue.new
    end

    def synchronize
      attempt = @counter_mutex.synchronize { @attempt_count += 1 }
      @attempts << [attempt, Thread.current]
      if attempt == @pause_at
        @paused << attempt
        @release.pop
      end
      @mutex.synchronize { yield }
    end
  end

  class BlockingEmitter < Emitter
    attr_reader :entered, :release

    def initialize(event:, generation:)
      super()
      @blocked_event = event
      @blocked_generation = generation
      @entered = Queue.new
      @release = Queue.new
      @blocked = false
    end

    def emit(event, payload = {})
      if !@blocked && event == @blocked_event && payload[:generation] == @blocked_generation
        @blocked = true
        @entered << true
        @release.pop
      end
      super
    end
  end

  class BlockingStatus < StatusCollector
    attr_reader :entered, :release

    def initialize(status:, generation:)
      super()
      @blocked_status = status
      @blocked_generation = generation
      @entered = Queue.new
      @release = Queue.new
      @blocked = false
    end

    def call(snapshot)
      if !@blocked && snapshot[:status] == @blocked_status &&
         snapshot[:generation] == @blocked_generation
        @blocked = true
        @entered << true
        @release.pop
      end
      super
    end
  end

  class BlockingFirstEnqueueQueue
    attr_reader :entered, :release

    def initialize
      @queue = SizedQueue.new(1)
      @mutex = Mutex.new
      @blocked = false
      @entered = Queue.new
      @release = Queue.new
    end

    def push(job, non_block = false)
      should_block = @mutex.synchronize do
        next false if @blocked

        @blocked = true
      end
      if should_block
        @entered << job
        @release.pop
      end
      @queue.push(job, non_block)
      self
    end

    def pop(non_block = false) = @queue.pop(non_block)
    def size = @queue.size
  end

  class MemorySource
    attr_reader :entered, :release

    def initialize(contents, blocked_path: nil, error_path: nil)
      @contents = contents
      @blocked_path = blocked_path
      @error_path = error_path
      @calls = []
      @mutex = Mutex.new
      @entered = Queue.new
      @release = Queue.new
    end

    def open(path, hints)
      @mutex.synchronize { @calls << [path, hints] }
      if path == @blocked_path
        @entered << path
        @release.pop
      end
      raise TestError.new("source_failed", "source failed") if path == @error_path

      yield StringIO.new(@contents.fetch(path))
    end

    def calls = @mutex.synchronize { @calls.dup }
  end

  class RecordingFileSource
    attr_reader :calls

    def initialize = @calls = []

    def open(path, hints)
      @calls << [path, hints]
      File.open(path, "rb") { |io| yield io }
    end
  end

  class RecordingLoader
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def load(path, hints:, cancelled:)
      @calls << [path, hints, cancelled]
      @result
    end
  end

  class TestError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  class RecordingFtps
    attr_reader :calls

    def initialize(content:, remote: "/cache/remote.gcode")
      @content = content
      @remote = remote
      @calls = []
    end

    def download(hints:, destination:, cancelled:, progress: ->(*) {})
      @calls << { hints: hints, destination: destination, cancelled: cancelled }
      raise TestError.new("cancelled", "cancelled") if cancelled.call

      progress.call(0, @content.bytesize)
      File.binwrite(destination, @content)
      progress.call(@content.bytesize, @content.bytesize)
      @remote
    end
  end

  class ArchiveFtp
    attr_reader :retrieved

    def initialize(files)
      @files = files
      @retrieved = []
    end

    def retrbinary(command, block_size)
      if command.start_with?("NLST ")
        root = command.delete_prefix("NLST ")
        prefix = root == "/" ? "/" : "#{root}/"
        listing = @files.each_key.filter_map do |path|
          remainder = path.delete_prefix(prefix)
          path if path.start_with?(prefix) && !remainder.include?("/")
        end.join("\r\n")
        listing << "\r\n" unless listing.empty?
        listing.scan(/.{1,#{block_size}}/m) { |chunk| yield chunk }
        return
      end

      path = command.delete_prefix("RETR ")
      @retrieved << path
      @files.fetch(path).scan(/.{1,#{block_size}}/m) { |chunk| yield chunk }
    end

    def size(path) = @files.fetch(path).bytesize
    def close = nil
  end

  class BlockingFtps
    attr_reader :entered, :release, :cancelled

    def initialize
      @entered = Queue.new
      @release = Queue.new
      @cancelled = Queue.new
    end

    def download(hints:, destination:, cancelled:, progress: ->(*) {})
      @entered << [hints, destination]
      progress.call(0, nil)
      @release.pop
      was_cancelled = cancelled.call
      @cancelled << was_cancelled
      raise TestError.new("cancelled", "cancelled") if was_cancelled

      File.binwrite(destination, gcode(1))
      "/cache/old.gcode"
    end

    private

    def gcode(x)
      "G90\nM83\n;TYPE:WALL-OUTER\nG1 X0 Y0 Z0.2\nG1 X#{x} Y0 E1\n"
    end
  end

  class UncooperativeFtps
    attr_reader :destination, :finished

    def initialize
      @destination = Queue.new
      @block_forever = Queue.new
      @finished = Queue.new
    end

    def download(destination:, **)
      File.binwrite(destination, "partial")
      @destination << destination
      @block_forever.pop
    ensure
      @finished << true
    end
  end

  def test_publishes_current_generation_as_a_packed_binary_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "demo.gcode")
      lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0.2"]
      1_205.times { |index| lines << "G1 X#{index + 1} Y0 E1" }
      File.write(path, lines.join("\n"))
      emitter = Emitter.new
      worker = build_worker(
        source: file_source,
        parser: BambuCompanion::GcodeParser.new(max_segments: 2_000),
        emitter: emitter
      )

      job = worker.submit(hints: {}, local_path: path)

      assert worker.process(job)
      names = emitter.events.map(&:first)
      assert_equal "geometry_begin", names.first
      assert_equal "geometry_end", names.last
      manifest = emitter.events.first.fetch(1)
      assert_equal 1_205, manifest.fetch(:segmentCount)
      assert_equal 1_205, manifest.fetch(:gcode).fetch(:segmentCount)
      assert_nil manifest.fetch(:preview)
      packed = manifest.fetch(:gcode).fetch(:path)
      assert File.file?(packed)
      assert_equal 1_205 * 6 * 4, File.size(packed)
      assert_equal 1_205 * 6, File.binread(packed).unpack("e*").length
      ending = emitter.events.last.fetch(1)
      assert_equal ["gcode"], ending.fetch(:sources)
      assert_equal({ "gcode" => 0 }, ending.fetch(:chunks))
      emitter.events.each { |event, payload| JSON.generate(payload.merge(event: event)) }
    end
  end

  def test_remote_load_reports_download_progress_then_local_processing
    content = gcode(1)
    statuses = StatusCollector.new
    worker = build_worker(
      ftps_client: RecordingFtps.new(content: content), source: file_source,
      on_status: statuses
    )
    job = worker.submit(hints: { "file" => "remote.gcode" })

    assert worker.process(job)
    loading = statuses.snapshots.select { |snapshot| snapshot[:status] == "loading" }
    assert_equal "locating", loading.first.fetch(:load_phase)
    completed_download = loading.find do |snapshot|
      snapshot[:load_phase] == "downloading" && snapshot[:load_progress] == 100
    end
    refute_nil completed_download
    assert_equal content.bytesize, completed_download.fetch(:loaded_bytes)
    assert_equal content.bytesize, completed_download.fetch(:total_bytes)
    assert_equal "processing", loading.last.fetch(:load_phase)
    assert_nil loading.last.fetch(:load_progress)
    assert_equal "ready", statuses.snapshots.last.fetch(:status)
  end

  def test_x2d_payload_selects_external_archive_and_internal_plate_end_to_end
    plate_one_png = test_png(width: 1, red: 0x11)
    plate_two_png = test_png(width: 2, red: 0x22)
    archive = test_archive(
      "Metadata/plate_1.gcode" => gcode(11),
      "Metadata/plate_2.gcode" => gcode(22),
      "Metadata/plate_1.png" => plate_one_png,
      "Metadata/plate_2.png" => plate_two_png
    )
    ftp = ArchiveFtp.new(
      "/Untitled.gcode.3mf" => test_archive("Metadata/plate_2.gcode" => gcode(99)),
      "/cache/Untitled.gcode.3mf" => archive
    )
    client = BambuCompanion::FtpsClient.new(
      config: config_fixture, secret: "session-secret", attempts: 1,
      ftp_factory: ->(*) { ftp }
    )
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = BambuCompanion::ModelWorker.new(
      ftps_client: client,
      loader: BambuCompanion::PrintPreviewLoader.new(
        source: BambuCompanion::GcodeSource.new,
        gcode_parser: BambuCompanion::GcodeParser.new(max_segments: 20),
        preview_source: BambuCompanion::ThreeMfPreview.new
      ),
      emitter: emitter, on_status: statuses,
      geometry_directory: @geometry_directory
    )
    fixture = JSON.parse(File.read(File.join(__dir__, "fixtures", "x2d-status.json")))
    hints = fixture.fetch("print")

    result = worker.process(worker.submit(hints: hints))
    assert result, statuses.snapshots.inspect

    assert_equal ["/cache/Untitled.gcode.3mf"], ftp.retrieved
    manifest = emitter.events.find { |event,| event == "geometry_begin" }.fetch(1)
    packed = File.binread(manifest.fetch(:gcode).fetch(:path)).unpack("e*")
    assert_equal 11.0, packed.fetch(3)
    preview = emitter.events.filter_map do |event, payload|
      payload.fetch(:data) if event == "geometry_preview_chunk"
    end.join
    assert_equal [plate_one_png].pack("m0"), preview
    assert_equal 1, manifest.fetch(:preview).fetch(:width)
  end

  def test_publishes_preview_and_gcode_as_one_ordered_transaction
    preview = BambuCompanion::PreviewImage.new(
      data: "PNG".b.freeze, width: 320, height: 240, media_type: "image/png"
    ).freeze
    gcode_geometry = geometry(
      segments: [[10, 0, 0.2, 11, 0, 0.2]],
      bounds: { min_z: 0.2, max_z: 0.2 }, layer_z: [0.2]
    )
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = BambuCompanion::ModelWorker.new(
      ftps_client: nil,
      loader: RecordingLoader.new(bundle(preview: preview, gcode: gcode_geometry)),
      emitter: emitter,
      on_status: statuses,
      geometry_directory: @geometry_directory
    )
    job = worker.submit(hints: {}, local_path: "/tmp/dual")

    assert worker.process(job)
    begin_event = emitter.events.first
    assert_equal "geometry_begin", begin_event.first
    assert_equal 1, begin_event.last.fetch(:segmentCount)
    assert_equal 1, begin_event.last.fetch(:gcode).fetch(:segmentCount)
    assert_equal({ minX: nil, maxX: nil, minY: nil, maxY: nil,
                   minZ: 0.2, maxZ: 0.2 },
                 begin_event.last.fetch(:gcode).fetch(:bounds))
    assert_equal({
      byteCount: 3, encodedLength: 4, width: 320, height: 240,
      mimeType: "image/png"
    }, begin_event.last.fetch(:preview))
    packed = begin_event.last.fetch(:gcode).fetch(:path)
    assert File.file?(packed)
    assert_equal 24, File.size(packed)
    preview_chunks = emitter.events.select do |event,|
      event == "geometry_preview_chunk"
    end
    assert_equal ["UE5H"], (preview_chunks.map { |_, payload| payload.fetch(:data) })
    assert_equal [0], (preview_chunks.map { |_, payload| payload.fetch(:index) })
    assert_equal({ "gcode" => 0, "preview" => 1 }, emitter.events.last.last.fetch(:chunks))
    assert_equal %w[gcode preview], emitter.events.last.last.fetch(:sources)
    assert_equal 1, statuses.snapshots.last.fetch(:segment_count)
    assert_equal 0.2, worker.snapshot(layer_num: 1).fetch(:z_current)
    retained = worker.instance_variable_get(:@geometry)
    refute_respond_to retained, :segments
    assert_equal [0.2], retained.layer_z
  end

  def test_large_preview_is_split_below_the_ipc_text_limit
    preview = BambuCompanion::PreviewImage.new(
      data: ("x" * 60_000).b.freeze, width: 320, height: 240,
      media_type: "image/png"
    ).freeze
    emitter = Emitter.new
    worker = BambuCompanion::ModelWorker.new(
      ftps_client: nil, loader: RecordingLoader.new(bundle(preview: preview)),
      emitter: emitter, on_status: StatusCollector.new,
      geometry_directory: @geometry_directory
    )

    assert worker.process(worker.submit(hints: {}, local_path: "/tmp/preview"))

    chunks = emitter.events.select { |event,| event == "geometry_preview_chunk" }
    assert_equal 2, chunks.length
    assert(chunks.all? { |_, payload| payload.fetch(:data).bytesize <= 49_152 })
    encoded = chunks.map { |_, payload| payload.fetch(:data) }.join
    assert_equal [preview.data].pack("m0"), encoded
    assert_equal({ "preview" => 2 }, emitter.events.last.last.fetch(:chunks))
  end

  def test_delegates_local_path_hints_and_cancellation_to_geometry_loader
    loader = RecordingLoader.new(bundle(gcode: geometry))
    emitter = Emitter.new
    worker = BambuCompanion::ModelWorker.new(
      ftps_client: nil,
      loader: loader,
      emitter: emitter,
      on_status: StatusCollector.new,
      geometry_directory: @geometry_directory
    )
    hints = { "file" => "local.gcode.3mf", "plate_idx" => 0 }
    job = worker.submit(hints: hints, local_path: "/tmp/local-job")

    assert worker.process(job)
    path, forwarded_hints, cancelled = loader.calls.fetch(0)
    assert_equal "/tmp/local-job", path
    assert_equal hints, forwarded_hints
    refute cancelled.call
  end

  def test_background_worker_processes_only_the_latest_pending_generation
    source = MemorySource.new(
      {
        "/old" => gcode(1),
        "/middle" => gcode(2),
        "/newest" => gcode(3)
      },
      blocked_path: "/old"
    )
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = build_worker(source: source, emitter: emitter, on_status: statuses).start

    old = worker.submit(hints: { file: "old" }, local_path: "/old")
    Timeout.timeout(TIMEOUT) { source.entered.pop }
    middle = worker.submit(hints: { file: "middle" }, local_path: "/middle")
    newest = worker.submit(hints: { file: "newest" }, local_path: "/newest")
    source.release << true
    emitter.wait_for("geometry_end", generation: newest.generation)

    assert_equal ["/old", "/newest"], source.calls.map(&:first)
    refute worker.current?(old)
    refute worker.current?(middle)
    assert worker.current?(newest)
    assert_equal [newest.generation], emitter.events.map { |_, payload| payload[:generation] }.uniq
    refute(statuses.snapshots.any? do |snapshot|
      [old.generation, middle.generation].include?(snapshot[:generation]) &&
        %w[ready error].include?(snapshot[:status])
    end)
  ensure
    worker&.stop
  end

  def test_pending_mailbox_never_exceeds_one_job_and_keeps_only_the_latest_submission
    paths = (1..200).to_h { |index| ["/job-#{index}", gcode(index)] }
    source = MemorySource.new(paths, blocked_path: "/job-1")
    emitter = Emitter.new
    worker = build_worker(source: source, emitter: emitter).start
    worker.submit(hints: {}, local_path: "/job-1")
    Timeout.timeout(TIMEOUT) { source.entered.pop }

    newest = nil
    2.upto(200) do |index|
      newest = worker.submit(hints: {}, local_path: "/job-#{index}")
    end

    assert_equal 1, worker.instance_variable_get(:@queue).size
    source.release << true
    emitter.wait_for("geometry_end", generation: newest.generation)
    assert_equal ["/job-1", "/job-200"], source.calls.map(&:first)
  ensure
    source&.release&.push(true)
    worker&.stop
  end

  def test_stop_replaces_a_pending_job_without_growing_or_blocking_the_mailbox
    source = MemorySource.new(
      { "/running" => gcode(1), "/pending" => gcode(2) },
      blocked_path: "/running"
    )
    worker = build_worker(source: source).start
    worker.submit(hints: {}, local_path: "/running")
    Timeout.timeout(TIMEOUT) { source.entered.pop }
    worker.submit(hints: {}, local_path: "/pending")

    Timeout.timeout(TIMEOUT) { worker.stop }

    assert_operator worker.instance_variable_get(:@queue).size, :<=, 1
  ensure
    source&.release&.push(true)
    worker&.stop
  end

  def test_generation_state_and_enqueue_are_one_atomic_submission
    worker = build_worker
    queue = BlockingFirstEnqueueQueue.new
    worker.instance_variable_set(:@queue, queue)
    results = Queue.new
    first_submitter = Thread.new do
      results << worker.submit(hints: {}, local_path: "/first")
    end
    Timeout.timeout(TIMEOUT) { queue.entered.pop }
    second_submitter = Thread.new do
      results << worker.submit(hints: {}, local_path: "/second")
    end

    assert worker.instance_variable_get(:@mutex).locked?,
           "generation/state mutex must stay locked through queue insertion"
    queue.release << true
    [first_submitter, second_submitter].each { |thread| thread.join(TIMEOUT) }
    jobs = 2.times.map { Timeout.timeout(TIMEOUT) { results.pop } }

    assert_equal [1, 2], jobs.map(&:generation).sort
    assert_equal 2, worker.send(:newest_queued_job).generation
  ensure
    queue&.release&.push(true)
    first_submitter&.join(TIMEOUT)
    second_submitter&.join(TIMEOUT)
  end

  def test_pending_mailbox_replaces_an_older_job_before_the_worker_starts
    worker = build_worker
    old = worker.submit(hints: {}, local_path: "/old")
    current = worker.submit(hints: {}, local_path: "/current")
    queue = worker.instance_variable_get(:@queue)

    selected = worker.send(:newest_queued_job)

    assert_equal 0, queue.size
    assert_equal current.generation, selected.generation
    refute_equal old.generation, selected.generation
  end

  def test_submit_waits_for_a_blocked_geometry_emission_to_finish
    emitter = BlockingEmitter.new(event: "geometry_begin", generation: 1)
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    statuses = StatusCollector.new
    publication_mutex = InstrumentedMutex.new
    worker = build_worker(source: source, emitter: emitter, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { emitter.entered.pop }
    drain_queue(publication_mutex.attempts)
    submitted = Queue.new
    submitter = Thread.new { submitted << worker.submit(hints: {}, local_path: "/new") }
    _, attempting_thread = Timeout.timeout(TIMEOUT) { publication_mutex.attempts.pop }

    assert_same submitter, attempting_thread
    assert_raises(ThreadError) { submitted.pop(true) }
    assert_equal old.generation, worker.snapshot({})[:generation]
    emitter.release << true
    current = Timeout.timeout(TIMEOUT) { submitted.pop }
    statuses.wait_for("ready", generation: current.generation)

    assert_equal 2, current.generation
  ensure
    emitter&.release&.push(true)
    submitter&.join(TIMEOUT)
    worker&.stop
  end

  def test_submit_waits_for_a_blocked_status_callback_to_finish
    statuses = BlockingStatus.new(status: "ready", generation: 1)
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    publication_mutex = InstrumentedMutex.new
    worker = build_worker(source: source, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { statuses.entered.pop }
    drain_queue(publication_mutex.attempts)
    submitted = Queue.new
    submitter = Thread.new { submitted << worker.submit(hints: {}, local_path: "/new") }
    _, attempting_thread = Timeout.timeout(TIMEOUT) { publication_mutex.attempts.pop }

    assert_same submitter, attempting_thread
    assert_raises(ThreadError) { submitted.pop(true) }
    assert_equal old.generation, worker.snapshot({})[:generation]
    statuses.release << true
    current = Timeout.timeout(TIMEOUT) { submitted.pop }
    statuses.wait_for("ready", generation: current.generation)

    assert(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "ready"
    end)
  ensure
    statuses&.release&.push(true)
    submitter&.join(TIMEOUT)
    worker&.stop
  end

  def test_submit_winning_publication_race_suppresses_stale_geometry_end
    emitter = Emitter.new
    statuses = StatusCollector.new
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    publication_mutex = InstrumentedMutex.new(pause_at: 4)
    worker = build_worker(source: source, emitter: emitter, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { publication_mutex.paused.pop }

    current = worker.submit(hints: {}, local_path: "/new")
    publication_mutex.release << true
    statuses.wait_for("ready", generation: current.generation)

    refute(emitter.events.any? do |event, payload|
      event == "geometry_end" && payload[:generation] == old.generation
    end)
  ensure
    publication_mutex&.release&.push(true)
    worker&.stop
  end

  def test_submit_winning_publication_race_suppresses_stale_ready_status
    statuses = StatusCollector.new
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    publication_mutex = InstrumentedMutex.new(pause_at: 5)
    worker = build_worker(source: source, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { publication_mutex.paused.pop }

    current = worker.submit(hints: {}, local_path: "/new")
    publication_mutex.release << true
    statuses.wait_for("ready", generation: current.generation)

    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "ready"
    end)
  ensure
    publication_mutex&.release&.push(true)
    worker&.stop
  end

  def test_status_callback_can_submit_reentrantly_without_continuing_stale_job
    emitter = Emitter.new
    statuses = StatusCollector.new
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    reentrant_result = Queue.new
    submitted = false
    worker = nil
    callback = lambda do |snapshot|
      statuses.call(snapshot)
      next unless !submitted && snapshot[:generation] == 1 && snapshot[:status] == "loading"

      submitted = true
      begin
        reentrant_result << worker.submit(hints: {}, local_path: "/new")
      rescue StandardError => error
        reentrant_result << error
      end
    end
    worker = build_worker(source: source, emitter: emitter, on_status: callback).start
    old = worker.submit(hints: {}, local_path: "/old")

    current = Timeout.timeout(TIMEOUT) { reentrant_result.pop }
    assert_instance_of BambuCompanion::ModelWorker::Job, current
    statuses.wait_for("ready", generation: current.generation)

    assert_equal old.generation + 1, current.generation
    assert_equal [current.generation], emitter.events.map { |_, payload| payload[:generation] }.uniq
    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "ready"
    end)
  ensure
    worker&.stop
  end

  def test_stale_source_error_is_not_published
    source = MemorySource.new(
      { "/new" => gcode(2) }, blocked_path: "/old", error_path: "/old"
    )
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = build_worker(source: source, emitter: emitter, on_status: statuses).start

    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { source.entered.pop }
    current = worker.submit(hints: {}, local_path: "/new")
    source.release << true
    statuses.wait_for("ready", generation: current.generation)

    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "error"
    end)
    assert_equal current.generation, worker.snapshot({})[:generation]
    assert_equal "ready", worker.snapshot({})[:status]
  ensure
    worker&.stop
  end

  def test_new_submission_cancels_remote_download_and_suppresses_its_error
    ftps = BlockingFtps.new
    source = MemorySource.new({ "/new" => gcode(2) })
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = build_worker(
      ftps_client: ftps, source: source, emitter: emitter, on_status: statuses
    ).start

    old = worker.submit(hints: { file: "old.gcode" })
    Timeout.timeout(TIMEOUT) { ftps.entered.pop }
    current = worker.submit(hints: {}, local_path: "/new")
    ftps.release << true
    statuses.wait_for("ready", generation: current.generation)

    assert Timeout.timeout(TIMEOUT) { ftps.cancelled.pop }
    refute(emitter.events.any? { |_, payload| payload[:generation] == old.generation })
    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "error"
    end)
  ensure
    worker&.stop
  end

  def test_remote_download_uses_source_name_and_cleans_temporary_file
    ftps = RecordingFtps.new(content: gcode(4), remote: "/cache/part.gcode")
    source = RecordingFileSource.new
    worker = build_worker(ftps_client: ftps, source: source)
    hints = { "file" => "part.gcode" }
    job = worker.submit(hints: hints)

    assert worker.process(job)
    path, source_hints = source.calls.fetch(0)
    assert_equal "/cache/part.gcode", source_hints.fetch("source_name")
    assert_equal hints, ftps.calls.fetch(0).fetch(:hints)
    refute_path_exists path
  end

  def test_local_path_uses_source_directly_without_ftps_or_caching
    source = MemorySource.new({ "/demo" => gcode(5) })
    ftps = Object.new
    ftps.define_singleton_method(:download) { |**| flunk("FTPS must not be called") }
    worker = build_worker(ftps_client: ftps, source: source)
    hints = { "plate_idx" => 0 }

    first = worker.submit(hints: hints, local_path: "/demo")
    hints["plate_idx"] = 9
    assert worker.process(first)
    second = worker.submit(hints: {}, local_path: "/demo")
    assert worker.process(second)

    assert_equal 2, source.calls.length
    assert_equal({ "plate_idx" => 0 }, source.calls.first.fetch(1))
  end

  def test_initial_submit_returns_before_its_worker_status_callback_begins
    callback_entered = Queue.new
    callback_release = Queue.new
    blocked_once = false
    callback = lambda do |_snapshot|
      next if blocked_once

      blocked_once = true
      callback_entered << true
      callback_release.pop
    end
    worker = build_worker(
      source: MemorySource.new({ "/demo" => gcode(1) }), on_status: callback
    ).start
    submitted = Queue.new
    submitter = Thread.new { submitted << worker.submit(hints: {}, local_path: "/demo") }

    job = Timeout.timeout(TIMEOUT) { submitted.pop }
    assert_instance_of BambuCompanion::ModelWorker::Job, job
    Timeout.timeout(TIMEOUT) { callback_entered.pop }
  ensure
    callback_release&.push(true)
    submitter&.join(TIMEOUT)
    worker&.stop
  end

  def test_stop_interrupts_an_uncooperative_download_and_cleans_tempfile
    ftps = UncooperativeFtps.new
    worker = build_worker(ftps_client: ftps).start
    worker.submit(hints: { file: "stuck.gcode" })
    path = Timeout.timeout(TIMEOUT) { ftps.destination.pop }
    assert_path_exists path

    Timeout.timeout(TIMEOUT) { worker.stop }
    Timeout.timeout(TIMEOUT) { ftps.finished.pop }

    refute_path_exists path
  ensure
    worker&.stop
  end

  def test_stop_called_from_worker_callback_does_not_join_itself
    result = Queue.new
    worker = nil
    callback = lambda do |snapshot|
      next unless snapshot[:status] == "ready"

      begin
        worker.stop
        result << :stopped
      rescue StandardError => error
        result << error
      end
    end
    worker = build_worker(
      source: MemorySource.new({ "/demo" => gcode(1) }), on_status: callback
    ).start
    worker.submit(hints: {}, local_path: "/demo")

    assert_equal :stopped, Timeout.timeout(TIMEOUT) { result.pop }
  ensure
    worker&.stop
  end

  def test_start_is_idempotent
    worker = build_worker

    assert_same worker, worker.start
    thread = worker.instance_variable_get(:@thread)
    assert_same worker, worker.start

    assert_same thread, worker.instance_variable_get(:@thread)
  ensure
    worker&.stop
  end

  def test_stop_is_idempotent
    worker = build_worker

    assert_same worker, worker.stop
    generation = worker.instance_variable_get(:@generation)
    queue_size = worker.instance_variable_get(:@queue).size
    assert_same worker, worker.stop

    assert_equal generation, worker.instance_variable_get(:@generation)
    assert_equal queue_size, worker.instance_variable_get(:@queue).size
  end

  def test_submit_after_stop_raises_without_mutating_state_or_queue
    worker = build_worker
    worker.stop
    state = worker.snapshot({})
    generation = worker.instance_variable_get(:@generation)
    queue_size = worker.instance_variable_get(:@queue).size

    error = assert_raises(BambuCompanion::ModelWorker::StoppedError) do
      worker.submit(hints: {}, local_path: "/late")
    end

    refute_respond_to error, :code
    assert_equal "Model worker has been stopped", error.message
    assert_equal state, worker.snapshot({})
    assert_equal generation, worker.instance_variable_get(:@generation)
    assert_equal queue_size, worker.instance_variable_get(:@queue).size
  end

  def test_stopped_error_from_reentrant_callback_is_not_swallowed
    worker = nil
    callback = lambda do |snapshot|
      next unless snapshot[:generation] == 1 && snapshot[:status] == "loading"

      worker.stop
      worker.submit(hints: {}, local_path: "/late")
    end
    worker = build_worker(
      source: MemorySource.new({ "/old" => gcode(1) }), on_status: callback
    )
    job = worker.submit(hints: {}, local_path: "/old")

    error = assert_raises(BambuCompanion::ModelWorker::StoppedError) do
      worker.process(job)
    end

    refute_respond_to error, :code
  ensure
    worker&.stop
  end

  def test_current_error_uses_stable_code_and_is_reflected_in_snapshot
    source = MemorySource.new({}, error_path: "/bad")
    statuses = StatusCollector.new
    worker = build_worker(source: source, on_status: statuses)
    job = worker.submit(hints: {}, local_path: "/bad")

    refute worker.process(job)
    snapshot = worker.snapshot({})
    assert_equal "error", snapshot[:status]
    assert_equal({ code: "source_failed", message: "source failed" }, snapshot[:error])
    assert_equal snapshot, statuses.snapshots.last
  end

  def test_error_snapshot_is_deeply_immutable
    source = Object.new
    source.define_singleton_method(:open) do |*, **|
      raise TestError.new(String.new("dynamic_code"), String.new("dynamic message"))
    end
    worker = build_worker(source: source)
    job = worker.submit(hints: {}, local_path: "/bad")

    refute worker.process(job)
    error = worker.snapshot({}).fetch(:error)

    assert_predicate error, :frozen?
    assert_predicate error.fetch(:code), :frozen?
    assert_predicate error.fetch(:message), :frozen?
  ensure
    worker&.stop
  end

  def test_z_progress_prefers_layer_and_clamps_layer_index
    geometry = geometry(layer_z: [0.2, 0.4, 0.6])

    assert_equal [0.4, "layer"], BambuCompanion::ZProgress.calculate(
      geometry, layer: 2, percent: 90
    )
    assert_equal [0.2, "layer"], BambuCompanion::ZProgress.calculate(
      geometry, "layer_num" => 0, "percent" => 90
    )
    assert_equal [0.6, "layer"], BambuCompanion::ZProgress.calculate(
      geometry, layer_num: 99, percent: 1
    )
  end

  def test_z_progress_uses_percent_when_layer_metadata_was_decimated
    model = geometry(
      bounds: { min_z: 0.0, max_z: 25_000.0 },
      layer_z: (0..12_500).map { |index| index * 2.0 },
      layer_z_exact: false
    )

    assert_equal [12_500.0, "estimated"], BambuCompanion::ZProgress.calculate(
      model, layer: 6_250, percent: 50
    )
  end

  def test_z_progress_interpolates_and_clamps_percent_to_bounds
    model = geometry(bounds: { min_z: 0.2, max_z: 10.2 })

    assert_equal [5.2, "estimated"], BambuCompanion::ZProgress.calculate(model, percent: 50)
    assert_equal [0.2, "estimated"], BambuCompanion::ZProgress.calculate(model, percent: -5)
    assert_equal [10.2, "estimated"], BambuCompanion::ZProgress.calculate(
      model, "percent" => "105"
    )
  end

  def test_z_progress_interpolation_avoids_overflow_and_remains_json_safe
    model = geometry(bounds: { min_z: -Float::MAX, max_z: Float::MAX })

    z, mode = BambuCompanion::ZProgress.calculate(model, percent: 50)

    assert_equal 0.0, z
    assert_equal "estimated", mode
    assert z.finite?
    assert_equal %({"zCurrent":0.0}), JSON.generate(zCurrent: z)
  end

  def test_nonfinite_layer_and_percent_values_fall_back_without_unsafe_snapshot_json
    model = geometry(layer_z: [0.2, 0.4])
    assert_equal [5.2, "estimated"], BambuCompanion::ZProgress.calculate(
      model, layer: Float::INFINITY, percent: 50
    )
    assert_equal [0.4, "layer"], BambuCompanion::ZProgress.calculate(
      model, layer: 2, percent: Float::NAN
    )
    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(
      model, layer: Float::NAN, percent: Float::INFINITY
    )

    worker = build_worker(source: MemorySource.new({ "/demo" => gcode(1) }))
    job = worker.submit(hints: {}, local_path: "/demo")
    assert worker.process(job)
    snapshot = worker.snapshot(layer: Float::NAN, percent: Float::INFINITY)

    assert_nil snapshot[:z_current]
    assert_equal "unknown", snapshot[:z_mode]
    assert_equal "unknown", JSON.parse(JSON.generate(snapshot)).fetch("z_mode")
  end

  def test_z_progress_is_unknown_without_usable_layer_or_finite_bounds
    no_bounds = geometry(bounds: { min_z: nil, max_z: Float::INFINITY })

    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(nil, layer: 1)
    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(no_bounds, percent: 50)
    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(geometry, {})
  end

  private

  def build_worker(ftps_client: nil, source: MemorySource.new({}),
                   parser: BambuCompanion::GcodeParser.new(max_segments: 2_000),
                   emitter: Emitter.new, on_status: StatusCollector.new)
    BambuCompanion::ModelWorker.new(
      ftps_client: ftps_client,
      loader: BambuCompanion::PrintPreviewLoader.new(
        source: source,
        gcode_parser: parser,
        preview_source: Object.new.tap do |preview|
          preview.define_singleton_method(:extract) { |*| nil }
        end
      ),
      emitter: emitter,
      on_status: on_status,
      geometry_directory: @geometry_directory
    )
  end

  def file_source
    Object.new.tap do |source|
      source.define_singleton_method(:open) do |path, _hints, &block|
        File.open(path, "rb") { |io| block.call(io) }
      end
    end
  end

  def gcode(x)
    "G90\nM83\n;TYPE:WALL-OUTER\nG1 X0 Y0 Z0.2\nG1 X#{x} Y0 E1\n"
  end

  def geometry(segments: [], bounds: { min_z: 0.2, max_z: 10.2 },
               layer_z: [], layer_z_exact: true)
    BambuCompanion::Geometry.new(
      segments: segments.map(&:freeze).freeze, bounds: bounds.freeze, layer_z: layer_z.freeze,
      layer_z_exact: layer_z_exact
    ).freeze
  end

  def bundle(preview: nil, gcode: nil)
    BambuCompanion::PrintPreviewBundle.new(preview: preview, gcode: gcode)
  end

  def test_archive(entries)
    buffer = Zip::OutputStream.write_buffer do |zip|
      entries.each do |name, content|
        zip.put_next_entry(name)
        zip.write(content)
      end
    end
    buffer.string
  end

  def test_png(width:, red:)
    signature = "\x89PNG\r\n\x1A\n".b
    header = [width, 1, 8, 2, 0, 0, 0].pack("NNC5")
    pixels = "\x00".b + ([red, 0, 0].pack("C3") * width)
    signature + png_chunk("IHDR", header) +
      png_chunk("IDAT", Zlib::Deflate.deflate(pixels)) + png_chunk("IEND", "".b)
  end

  def png_chunk(type, body)
    type = String(type).b
    body = String(body).b
    [body.bytesize].pack("N") + type + body + [Zlib.crc32(type + body)].pack("N")
  end

  def drain_queue(queue)
    loop { queue.pop(true) }
  rescue ThreadError
    nil
  end
end
