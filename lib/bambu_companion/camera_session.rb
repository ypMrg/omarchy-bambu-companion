# frozen_string_literal: true

require_relative "jpeg_tcp_client"
require_relative "rtsps_snapshot"

module BambuCompanion
  class CameraSession
    THREAD_JOIN_SECONDS = 0.5

    def initialize(config:, secret:, store:, emitter:,
                   jpeg_factory: nil, rtsps_factory: nil,
                   ffmpeg_available: nil,
                   interval: 1.0, clock: nil)
      @config = config
      @secret = String(secret)
      @store = store
      @emitter = emitter
      @jpeg_factory = jpeg_factory || ->(**arguments) { JpegTcpClient.new(**arguments) }
      @rtsps_factory = rtsps_factory || ->(**arguments) { RtspsSnapshot.new(**arguments) }
      @ffmpeg_available = ffmpeg_available || -> { RtspsSnapshot.ffmpeg_available? }
      @interval = Float(interval)
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @mutex = Mutex.new
      @thread = nil
      @jpeg = nil
      @rtsps = nil
      @cancelled = true
      @force_snapshot = false
      @last_publish = -Float::INFINITY
      @generation = 0
    end

    def start(camera)
      camera = stringify(camera)
      @mutex.synchronize do
        return self if running_unlocked?

        @cancelled = false
        @force_snapshot = false
        @last_publish = -Float::INFINITY
        @thread = Thread.new { run(camera) }
        @thread.report_on_exception = false
      end
      self
    end

    def stop
      thread = jpeg = rtsps = nil
      @mutex.synchronize do
        @cancelled = true
        @force_snapshot = false
        thread = @thread
        jpeg = @jpeg
        rtsps = @rtsps
        @thread = nil
        @jpeg = nil
        @rtsps = nil
      end
      jpeg&.close
      rtsps&.close
      join_thread(thread)
      @store.clear
      emit_status("idle")
      self
    end

    def snapshot
      @mutex.synchronize { @force_snapshot = true }
      self
    end

    def running?
      @mutex.synchronize { running_unlocked? }
    end

    private

    def running_unlocked?
      !@cancelled && @thread&.alive?
    end

    def run(camera)
      emit_status("connecting")
      case camera["transport"].to_s
      when "rtsps" then run_rtsps(camera)
      when "jpeg_tcp" then run_jpeg
      else
        emit_status("error", code: "unavailable",
                    message: "Chamber camera is unavailable")
      end
    rescue TlsCertificateError, JpegTcpError, RtspsError => error
      emit_status("error", code: error.code, message: error.message)
    rescue StandardError => error
      emit_status("error", code: "camera_failed", message: error.message)
    end

    def run_jpeg
      client = @jpeg_factory.call(
        host: @config.host, port: JpegTcpClient::PORT,
        username: @config.username, password: @secret,
        fingerprint: fingerprint,
        cancelled: method(:cancelled?)
      )
      @mutex.synchronize { @jpeg = client }
      return if cancelled?

      client.each_frame { |jpeg| handle_frame(jpeg) }
    ensure
      client&.close
    end

    def run_rtsps(camera)
      if camera["liveview_enabled"] == false
        emit_status("error", code: "liveview_disabled",
                    message: "Enable LAN Mode Liveview on the printer")
        return
      end
      unless @ffmpeg_available.call
        emit_status("error", code: "ffmpeg_missing",
                    message: "Install ffmpeg to view the camera")
        return
      end

      client = @rtsps_factory.call(
        host: @config.host, port: RtspsSnapshot::PORT,
        username: @config.username, password: @secret,
        fingerprint: fingerprint
      )
      @mutex.synchronize { @rtsps = client }
      return if cancelled?

      client.each_frame(cancelled: method(:cancelled?)) do |jpeg|
        handle_frame(jpeg)
      end
    ensure
      client&.close
      @mutex.synchronize { @rtsps = nil if @rtsps.equal?(client) }
    end

    def handle_frame(jpeg, force: false)
      return if cancelled? || jpeg.nil?

      now = @clock.call
      publish = false
      @mutex.synchronize do
        due = force || @force_snapshot || (now - @last_publish) >= @interval
        next unless due

        @force_snapshot = false
        @last_publish = now
        publish = true
      end
      return unless publish

      path = @store.write(jpeg)
      return unless path

      generation = @mutex.synchronize { @generation += 1 }
      @emitter.emit("camera_frame", path: path, generation: generation)
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    def emit_status(state, code: nil, message: nil)
      payload = { state: state }
      payload[:code] = code if code
      payload[:message] = message if message
      @emitter.emit("camera_status", payload)
    end

    def fingerprint
      [@config.mqtt_tls_fingerprint, @config.ftps_tls_fingerprint].compact.uniq.freeze
    end

    def stringify(value)
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    def join_thread(thread)
      return unless thread
      return if thread.equal?(Thread.current)

      unless thread.join(THREAD_JOIN_SECONDS)
        thread.kill
        thread.join(THREAD_JOIN_SECONDS)
      end
    rescue StandardError
      thread.kill if thread&.alive?
    end
  end
end
