require_relative "acceptance_helper"

module UserModeHelper
  include AcceptanceHelper

  USERMODE_DOCKERFILE_PATH = File.expand_path("Dockerfile.user_mode", __dir__)
  USERMODE_IMAGE_NAME = "procsd-test-usermode"
  USER_SYSTEMD_DIR = "/home/testuser/.config/systemd/user"

  class UserModeContainer < AcceptanceHelper::Container
    def initialize
      super
      @name = "procsd-usermode-test-#{SecureRandom.hex(4)}"
    end

    def start
      rebuild_gem

      unless image_exists?
        build_image
      end

      cmd = [
        "podman", "run", "-d",
        "--name", @name,
        "--hostname", "procsd-test",
        "--privileged",
        "--cgroupns=host",
        "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw",
        "-v", "#{AcceptanceHelper::GEM_BUILD_DIR}:/gem:ro",
        USERMODE_IMAGE_NAME
      ]

      output, status = Open3.capture2(*cmd)
      raise "Failed to start container: #{output}" unless status.success?

      @id = output.strip

      wait_for_systemd

      # Start user@1001 service to enable user systemd for testuser
      exec_as_root("systemctl start user@1001.service")
      wait_for_user_systemd

      exec_as_root("gem install /gem/procsd-test.gem --local --ignore-dependencies --no-document")

      self
    end

    def service_active?(service_name)
      exec_as_user("systemctl --user is-active --quiet #{service_name}", raise_on_error: false).success?
    end

    def service_enabled?(service_name)
      exec_as_user("systemctl --user is-enabled --quiet #{service_name}", raise_on_error: false).success?
    end

    def list_service_files(pattern)
      result = exec_as_user("ls -1 #{USER_SYSTEMD_DIR}/#{pattern} 2>/dev/null", raise_on_error: false)
      return [] unless result.success?
      result.stdout.strip.split("\n").map { |f| File.basename(f) }.reject(&:empty?)
    end

    def file_exists?(path)
      exec_as_user("test -f #{path}", raise_on_error: false).success?
    end

    def read_file(path)
      result = exec_as_user("cat #{path}", raise_on_error: false)
      result.success? ? result.stdout : nil
    end

    def exec_as_user(command, raise_on_error: true)
      result = exec_with_user_env(command)
      if raise_on_error && !result.success?
        raise "Command failed: #{command}\n#{result.output}"
      end
      result
    end

    # Override exec to use user environment for running procsd commands
    def exec(command, user: "testuser", dir: "/home/testuser/myapp")
      if user == "testuser"
        exec_with_user_env(command, dir: dir)
      else
        super
      end
    end

    private

    def exec_with_user_env(command, dir: "/home/testuser/myapp")
      # Set XDG_RUNTIME_DIR for user systemd access
      full_cmd = [
        "podman", "exec",
        "-u", "testuser",
        "-w", dir,
        "-e", "XDG_RUNTIME_DIR=/run/user/1001",
        "-e", "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
        @name,
        "bash", "-lc", command
      ]
      stdout, stderr, status = Open3.capture3(*full_cmd)
      AcceptanceHelper::Result.new(stdout, stderr, status.exitstatus)
    end

    def image_exists?
      system("podman", "image", "exists", USERMODE_IMAGE_NAME, out: File::NULL, err: File::NULL)
    end

    def build_image
      cmd = ["podman", "build", "-t", USERMODE_IMAGE_NAME, "-f", USERMODE_DOCKERFILE_PATH, File.dirname(USERMODE_DOCKERFILE_PATH)]
      output, status = Open3.capture2e(*cmd)
      raise "Failed to build user-mode image: #{output}" unless status.success?
    end

    def wait_for_user_systemd(timeout: 30)
      start_time = Time.now
      loop do
        result = exec_with_user_env("systemctl --user is-system-running 2>/dev/null", dir: "/")
        state = result.stdout.strip
        return if %w[running degraded].include?(state)

        if Time.now - start_time > timeout
          raise "Timeout waiting for user systemd to be ready (state: #{state})"
        end

        sleep 0.5
      end
    end
  end

  def setup_container
    @container = UserModeContainer.new
    @container.start
  end

  def user_systemd_dir
    USER_SYSTEMD_DIR
  end
end
