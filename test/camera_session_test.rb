# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "bambu_companion/camera_session"
require "bambu_companion/camera_store"

class CameraSessionTest < Minitest::Test
  JPEG_A = BambuCompanion::TestFixtures.minimal_jpeg(payload: "aaa").freeze
  JPEG_B = BambuCompanion::TestFixtures.minimal_jpeg(payload: "bbb").freeze

  class FakeEmitter
    attr_reader :events

    def initialize
      @events = []
      @mutex = Mutex.new
    end

    def emit(event, payload = {})
      @mutex.synchronize { @events << [event, payload] }
    end

    def error(**payload)
      emit("error", payload)
    end

    def of(event)
      @mutex.synchronize do
        @events.select { |name, _| name == event }.map(&:last)
      end
    end
  end

  class FakeJpeg
    attr_reader :closed, :arguments

    def initialize(frames)
      @frames = frames
      @closed = false
      @arguments = nil
      @started = Queue.new
      @release = Queue.new
    end

    def bind(**arguments)
      @arguments = arguments
      self
    end

    def each_frame
      @started << true
      @frames.each do |jpeg|
        @release.pop
        break if @closed

        yield jpeg
      end
    end

    def close
      @closed = true
      @release << true
    end

    def allow_frame
      @started.pop
      @release << true
    end

    def allow_next
      @release << true
    end
  end

  class FakeRtsps
    attr_reader :captures, :streams, :stopped

    def initialize(frames)
      @frames = frames.dup
      @captures = 0
      @streams = 0
      @stopped = false
      @gate = Queue.new
    end

    def capture
      @gate.pop
      raise "stopped" if @stopped

      @captures += 1
      @frames.shift || JPEG_A
    end

    def each_frame(cancelled:)
      @streams += 1
      loop do
        @gate.pop
        break if @stopped || cancelled.call

        @captures += 1
        yield(@frames.shift || JPEG_A)
      end
    end

    def allow
      @gate << true
    end

    def close
      @stopped = true
      @gate << true
    end

    alias stop close
  end

  def test_jpeg_session_publishes_at_most_one_frame_per_interval
    Dir.mktmpdir do |directory|
      jpeg = FakeJpeg.new([JPEG_A, JPEG_B])
      emitter = FakeEmitter.new
      session = session_for(
        directory, emitter, jpeg_factory: ->(**arguments) { jpeg.bind(**arguments) }
      )

      session.start(present: true, transport: "jpeg_tcp", liveview_enabled: true)
      jpeg.allow_frame
      wait_until { emitter.of("camera_frame").length == 1 }
      session.snapshot
      jpeg.allow_next
      wait_until { emitter.of("camera_frame").length == 2 }

      frames = emitter.of("camera_frame")
      assert_equal 2, frames.length
      assert_equal([1, 2], frames.map { |frame| frame.fetch(:generation) })
      assert_equal JPEG_B, File.binread(frames.last.fetch(:path))
      session.stop
      assert jpeg.closed
      refute session.running?
      refute_path_exists File.join(directory, "snapshot.jpg")
    end
  end

  def test_jpeg_session_drops_extra_frames_within_the_interval
    Dir.mktmpdir do |directory|
      jpeg = FakeJpeg.new([JPEG_A, JPEG_B])
      emitter = FakeEmitter.new
      session = session_for(
        directory, emitter, jpeg_factory: ->(**arguments) { jpeg.bind(**arguments) }
      )

      session.start(present: true, transport: "jpeg_tcp", liveview_enabled: true)
      jpeg.allow_frame
      wait_until { emitter.of("camera_frame").length == 1 }
      jpeg.allow_next
      sleep 0.05
      session.stop

      assert_equal 1, emitter.of("camera_frame").length
    end
  end

  def test_stop_prevents_further_rtsps_captures
    Dir.mktmpdir do |directory|
      rtsps = FakeRtsps.new([JPEG_A, JPEG_B])
      emitter = FakeEmitter.new
      arguments = nil
      session = session_for(
        directory, emitter,
        rtsps_factory: ->(**values) { arguments = values; rtsps },
        ffmpeg_available: -> { true }
      )

      session.start(present: true, transport: "rtsps", liveview_enabled: true)
      rtsps.allow
      wait_until { emitter.of("camera_frame").length == 1 }
      session.stop
      rtsps.stop

      assert_equal 1, rtsps.captures
      assert_equal 1, rtsps.streams
      assert rtsps.stopped
      assert_equal ["11" * 32, "22" * 32], arguments.fetch(:fingerprint)
      refute session.running?
    end
  end

  def test_rtsps_without_ffmpeg_emits_error_and_does_not_run
    Dir.mktmpdir do |directory|
      captures = 0
      emitter = FakeEmitter.new
      session = session_for(
        directory, emitter,
        rtsps_factory: ->(**) { captures += 1; raise "should not build" },
        ffmpeg_available: -> { false }
      )

      session.start(present: true, transport: "rtsps", liveview_enabled: true)
      wait_until do
        emitter.of("camera_status").any? { |payload| payload[:code] == "ffmpeg_missing" }
      end
      session.stop

      assert_equal 0, captures
      status = emitter.of("camera_status").find { |payload| payload[:state] == "error" }
      assert_equal "ffmpeg_missing", status.fetch(:code)
    end
  end

  private

  def session_for(directory, emitter, jpeg_factory: nil, rtsps_factory: nil,
                  ffmpeg_available: -> { true }, clock: -> { 0.0 })
    BambuCompanion::CameraSession.new(
      config: config_fixture,
      secret: "lan-code",
      store: BambuCompanion::CameraStore.new(directory: directory),
      emitter: emitter,
      jpeg_factory: jpeg_factory || ->(**) { raise "jpeg unused" },
      rtsps_factory: rtsps_factory || ->(**) { raise "rtsps unused" },
      ffmpeg_available: ffmpeg_available,
      interval: 1.0,
      clock: clock
    )
  end

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      raise "condition not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
