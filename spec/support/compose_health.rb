# frozen_string_literal: true
require 'json'
require 'open3'
require 'timeout'

# Readiness observes the image's real healthcheck without starting another exec.
module ServerComposeHealth
  FORMAT = '{"id":{{json .Id}},"name":{{json .Name}},"state":{{json .State}},"check":{{json .Config.Healthcheck.Test}}}'
  CHECK = %w[CMD skvoz-server health --state /var/lib/skvoz].freeze

  def self.wait(id, docker: '/usr/bin/docker', timeout: 30, call_timeout: 8)
    exact_id = id.match?(/\A[0-9a-f]{64}\z/)
    raise ArgumentError, 'Invalid exact owning container' unless exact_id || id.match?(/\Askvoz-spec-[0-9a-f]{12}-server-1\z/)
    deadline = clock + timeout
    previous = nil
    loop do
      raise Timeout::Error, 'Server health readiness deadline exceeded' if deadline - clock <= 0.05
      value = inspect_health(docker, id, [deadline, clock + call_timeout].min)
      raise Timeout::Error, 'Server health readiness deadline exceeded' if clock >= deadline
      if value
        full_id = value.fetch('id')
        raise IOError, 'Container identity differs' unless full_id.match?(/\A[0-9a-f]{64}\z/) &&
          (exact_id ? full_id == id : value.fetch('name') == '/' + id)
        raise IOError, 'Product healthcheck command differs' unless value.fetch('check') == CHECK
        state = value.fetch('state')
        health = state.fetch('Health')
        snapshot = { state: health.fetch('Status'), failing: health.fetch('FailingStreak'),
          last_exit: health.fetch('Log').last&.fetch('ExitCode') }
        return full_id if state.fetch('Running') && !state.fetch('Restarting') &&
          snapshot == { state: 'healthy', failing: 0, last_exit: 0 }
      else
        snapshot = { state: 'inspect_timeout' }
      end
      warn JSON.generate(event: 'compose_server_health', **snapshot) if previous != snapshot
      previous = snapshot
      sleep [0.05, [deadline - clock, 0].max].min
    end
  end

  def self.inspect_health(docker, id, deadline)
    remaining = deadline - clock
    raise Timeout::Error, 'No health inspection budget remains' unless remaining.positive?
    work_deadline = deadline - [0.5, remaining / 2].min
    buffers = [String.new(encoding: Encoding::BINARY), String.new(encoding: Encoding::BINARY)]
    timed_out = false
    status = nil
    Open3.popen3(docker, 'container', 'inspect', '--format', FORMAT, id, pgroup: true) do |input, output, error, process|
      input.close
      streams = { output => buffers[0], error => buffers[1] }
      begin
        until streams.empty? && !process.alive?
          if clock >= work_deadline
            timed_out = true
            break
          end
          ready = streams.empty? ? [] : IO.select(streams.keys, nil, nil, [0.02, work_deadline - clock].min)&.first || []
          process.join([0.01, [work_deadline - clock, 0].max].min) if streams.empty?
          ready.each do |io|
            chunk = io.read_nonblock(4096, exception: false)
            if chunk.nil?
              streams.delete(io)
            elsif chunk != :wait_readable
              streams.fetch(io) << chunk
              raise IOError, 'Health inspection output exceeds bound' if buffers.sum(&:bytesize) > 65536
            end
          end
        end
      ensure
        if timed_out || process.alive? || !streams.empty?
          Process.kill('KILL', -process.pid) rescue Errno::ESRCH
        end
        process.join([deadline - clock, 0].max)
        raise IOError, 'Health inspection child was not reaped before deadline' if process.alive?
        status = process.value
        loop do
          begin
            Process.kill(0, -process.pid)
          rescue Errno::ESRCH
            break
          end
          begin
            Process.waitpid(-process.pid, Process::WNOHANG)
          rescue Errno::ECHILD
            nil
          end
          raise IOError, 'Health inspection group not reaped before deadline; retry refused' if clock >= deadline
          sleep [0.005, [deadline - clock, 0].max].min
        end
        raise IOError, 'Health inspection cleanup exceeded absolute deadline' if clock > deadline
      end
    end
    return nil if timed_out
    raise IOError, 'Health inspection command failed' unless status.success? && buffers[1].empty?
    JSON.parse(buffers[0])
  end

  def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
