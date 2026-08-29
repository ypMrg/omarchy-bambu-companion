# frozen_string_literal: true

require_relative "camera_session"
require_relative "camera_store"
require_relative "model_worker"
require_relative "mqtt_session"
require_relative "printer_state"
require_relative "tls_certificate"

module BambuCompanion
  class PrinterConnection
    MODEL_HINT_KEYS = %i[file url gcode_file subtask_name plate_idx].freeze
    MODEL_RETRY_DELAYS = [5.0, 10.0, 20.0, 30.0].freeze
    MODEL_MAX_RETRIES = 6
    THREAD_JOIN_SECONDS = 0.5

    def initialize(config:, secret:, emitter:, mqtt_factory: nil, worker_factory: nil,
                   camera_factory: nil,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   next_sequence:)
      @config = config
      @secret = String(secret)
      @emitter = emitter
      @mqtt_factory = mqtt_factory || ->(**arguments) { MqttSession.new(**arguments) }
      @worker_factory = worker_factory || ->(**arguments) { ModelWorker.for_printer(**arguments) }
      @monotonic_clock = monotonic_clock
      @next_sequence = next_sequence
      @mutex = Mutex.new
      @state_mutex = Mutex.new
      @publication_mutex = Mutex.new
      @printer = PrinterState.new
      @last_hints = {}.freeze
      @model_retry_attempt = 0
      @model_retry_at = nil
      @session = nil
      @session_thread = nil
      @worker = nil
      @stopped = false
      @ffmpeg_available = RtspsSnapshot.ffmpeg_available?
      @camera = (camera_factory || method(:build_camera_session)).call(
        config: config, secret: @secret, emitter: emitter
      )
    end

    def start
      return self unless active?

      worker = @worker_factory.call(
        config: @config, secret: @secret, emitter: @emitter,
        on_status: ->(*) { emit_state(worker) }
      )
      return cleanup_unattached(worker: worker) unless attach_worker(worker)

      worker.start
      return cleanup_unattached(worker: worker) unless active?

      session = @mqtt_factory.call(
        config: @config,
        secret: @secret,
        on_report: ->(report) { handle_report(report, worker) },
        on_connection: ->(connected, error) { handle_connection(connected, error, worker) },
        on_error: ->(error) { emit_network_error(error) }
      )
      start_session_thread(session)
      self
    rescue StandardError => error
      cleanup_failed_start(worker: worker, session: session)
      emit_error(
        scope: "internal", code: "runtime_start", message: error.message,
        retryable: true
      )
      self
    end

    def start_camera
      camera = @state_mutex.synchronize { @printer.snapshot[:camera] }
      return false unless camera && camera[:present] && active?

      @camera.start(camera)
      true
    end

    def stop_camera
      @camera.stop
      true
    end

    def snapshot_camera
      @camera.snapshot
      true
    end

    def refresh_preview
      worker, hints = @mutex.synchronize { [@worker, @last_hints] if active_unlocked? }
      return false unless worker && !hints.empty?

      worker.submit(hints: hints)
      arm_model_retry(worker)
      true
    rescue ModelWorker::StoppedError
      false
    rescue StandardError => error
      emit_error(
        scope: "gcode", code: "refresh_failed", message: error.message,
        retryable: true
      )
      false
    end

    def stop
      session = thread = worker = nil
      @publication_mutex.synchronize do
        @mutex.synchronize do
          return self if @stopped

          @stopped = true
          session = @session
          thread = @session_thread
          worker = @worker
          @session = @session_thread = @worker = nil
          reset_model_retry_unlocked
        end
      end
      safely_stop(@camera)
      safely_stop(session)
      stop_thread(thread)
      safely_stop(worker)
      self
    end

    private

    def attach_worker(worker)
      @mutex.synchronize do
        next false unless active_unlocked?

        @worker = worker
        true
      end
    end

    def start_session_thread(session)
      gate = Queue.new
      thread = Thread.new do
        gate.pop
        begin
          session.run
        rescue MQTT::Exception, StandardError => error
          emit_network_error(error)
        ensure
          @mutex.synchronize do
            @session_thread = nil if @session_thread.equal?(Thread.current)
          end
        end
      end
      thread.report_on_exception = false
      attached = @mutex.synchronize do
        next false unless active_unlocked?

        @session = session
        @session_thread = thread
        true
      end
      unless attached
        thread.kill
        thread.join
        safely_stop(session)
        return false
      end

      gate << true
      true
    end

    def handle_report(report, worker, load_model: true)
      return unless active?

      update = @state_mutex.synchronize { @printer.update(report) }
      hints = update.snapshot.slice(*MODEL_HINT_KEYS).freeze
      @mutex.synchronize { @last_hints = hints if active_unlocked? }
      if load_model && update.load_model && active?
        worker.submit(hints: hints)
        arm_model_retry(worker)
      elsif load_model
        retry_model_if_due(worker, hints, update.snapshot)
      end
      emit_state(worker)
    rescue ModelWorker::StoppedError
      nil
    rescue StandardError => error
      emit_error(
        scope: "internal", code: "report_processing", message: error.message,
        retryable: true
      )
    end

    def handle_connection(connected, _error, worker)
      return unless active?

      @state_mutex.synchronize do
        connected ? @printer.connected! : @printer.disconnected!
      end
      emit_state(worker)
    end

    def emit_network_error(error)
      if error.is_a?(TlsCertificateError)
        emit_error(
          scope: "tls", code: error.code, message: error.message,
          retryable: false
        )
        return
      end

      authentication = MqttSession.authentication_error?(error)
      emit_error(
        scope: "mqtt", code: authentication ? "authentication" : "connection",
        message: error.message, retryable: !authentication
      )
    end

    def emit_state(worker)
      @publication_mutex.synchronize do
        next false unless active?

        printer = @state_mutex.synchronize { @printer.snapshot }
        model = worker.snapshot(printer)
        @emitter.emit(
          "state",
          sequence: @next_sequence.call,
          printer: printer_payload(printer),
          model: ModelWorker.ipc_payload(model)
        )
        true
      end
    rescue ModelWorker::StoppedError
      false
    rescue IpcOutputError
      raise
    rescue StandardError => error
      emit_error(
        scope: "internal", code: "state_snapshot", message: error.message,
        retryable: true
      )
    end

    def emit_error(scope:, code:, message:, retryable:)
      @publication_mutex.synchronize do
        next false unless active?

        @emitter.error(
          scope: scope, code: code, message: String(message), retryable: retryable
        )
        true
      end
    end

    def printer_payload(state)
      {
        connected: state[:connected], stale: state[:stale],
        lastUpdate: state[:last_update], gcodeState: state[:gcode_state],
        subtaskName: state[:subtask_name], percent: state[:percent],
        nozzleTemp: state[:nozzle_temp], nozzleTargetTemp: state[:nozzle_target_temp],
        nozzles: nozzle_payload(state[:nozzles]), activeNozzle: state[:active_nozzle],
        bedTemp: state[:bed_temp], bedTargetTemp: state[:bed_target_temp],
        layer: state[:layer], totalLayers: state[:total_layers],
        remainingMinutes: state[:remaining_minutes], speedLevel: state[:speed_level],
        speedMagnitude: state[:speed_magnitude], wifiSignal: state[:wifi_signal],
        coolingFanSpeed: state[:cooling_fan_speed],
        heatbreakFanSpeed: state[:heatbreak_fan_speed],
        productName: state[:product_name], firmwareVersion: state[:firmware_version],
        alerts: alert_payload(state[:alerts]),
        camera: camera_payload(state[:camera])
      }
    end

    def camera_payload(camera)
      camera = camera.is_a?(Hash) ? camera : {}
      {
        present: camera[:present] == true,
        transport: camera[:transport] || "none",
        liveviewEnabled: camera[:liveview_enabled] == true,
        ffmpegAvailable: @ffmpeg_available == true
      }
    end

    def nozzle_payload(nozzles)
      Array(nozzles).map do |nozzle|
        {
          id: nozzle[:id], temp: nozzle[:temp], targetTemp: nozzle[:target_temp],
          diameter: nozzle[:diameter], type: nozzle[:type], active: nozzle[:active] == true
        }.compact
      end
    end

    def alert_payload(alerts)
      Array(alerts).map do |alert|
        {
          id: alert[:id], source: alert[:source], kind: alert[:kind],
          severity: alert[:severity], severityLevel: alert[:severity_level],
          module: alert[:module], title: alert[:title],
          description: alert[:description], code: alert[:code],
          rawAttr: alert[:raw_attr], rawCode: alert[:raw_code]
        }
      end
    end

    def build_camera_session(config:, secret:, emitter:)
      CameraSession.new(
        config: config,
        secret: secret,
        store: CameraStore.new,
        emitter: emitter
      )
    end

    def retry_model_if_due(worker, hints, printer)
      unless printer[:gcode_state].to_s.upcase == "RUNNING" && !hints.empty?
        clear_model_retry(worker)
        return false
      end

      model = worker.snapshot(printer)
      status = model[:status].to_s
      if status == "ready"
        clear_model_retry(worker)
        return false
      end
      return false unless status == "error"
      return clear_model_retry(worker) if model.dig(:error, :code) == "certificate_changed"
      return false unless take_model_retry_slot(worker)

      worker.submit(hints: hints)
      true
    end

    def arm_model_retry(worker)
      now = @monotonic_clock.call
      @mutex.synchronize do
        next false unless active_unlocked? && @worker.equal?(worker)

        @model_retry_attempt = 0
        @model_retry_at = now + MODEL_RETRY_DELAYS.first
        true
      end
    end

    def clear_model_retry(worker)
      @mutex.synchronize do
        next false unless @worker.equal?(worker)

        reset_model_retry_unlocked
        true
      end
    end

    def take_model_retry_slot(worker)
      now = @monotonic_clock.call
      @mutex.synchronize do
        next false unless active_unlocked? && @worker.equal?(worker)
        next false unless @model_retry_at && now >= @model_retry_at
        next false if @model_retry_attempt >= MODEL_MAX_RETRIES

        @model_retry_attempt += 1
        if @model_retry_attempt >= MODEL_MAX_RETRIES
          @model_retry_at = nil
        else
          index = [@model_retry_attempt, MODEL_RETRY_DELAYS.length - 1].min
          @model_retry_at = now + MODEL_RETRY_DELAYS[index]
        end
        true
      end
    end

    def reset_model_retry_unlocked
      @model_retry_attempt = 0
      @model_retry_at = nil
    end

    def cleanup_failed_start(worker:, session:)
      attached_worker = attached_session = attached_thread = nil
      @mutex.synchronize do
        attached_worker = @worker
        attached_session = @session
        attached_thread = @session_thread
        @worker = @session = @session_thread = nil
      end
      safely_stop(session || attached_session)
      stop_thread(attached_thread)
      safely_stop(worker || attached_worker)
    end

    def cleanup_unattached(worker: nil, session: nil)
      safely_stop(session)
      safely_stop(worker)
      self
    end

    def safely_stop(runtime)
      runtime&.stop
    rescue MQTT::Exception, StandardError
      nil
    end

    def stop_thread(thread)
      return unless thread
      return if thread.equal?(Thread.current)

      unless thread.join(THREAD_JOIN_SECONDS)
        thread.kill
        thread.join(THREAD_JOIN_SECONDS)
      end
    rescue MQTT::Exception, StandardError
      thread.kill if thread&.alive?
    end

    def active?
      @mutex.synchronize { active_unlocked? }
    end

    def active_unlocked?
      !@stopped
    end
  end
end
