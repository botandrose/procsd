require_relative "acceptance_helper"

class CreateCommandTest < Minitest::Test
  include AcceptanceHelper

  def setup
    setup_container
  end

  def teardown
    teardown_container
  end

  def test_create_command_creates_services_and_target
    create_procsd_yml(<<~YML)
      app: myapp
      formation: web=1
      environment:
        PORT: 3000
        RAILS_ENV: production
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("create")
    assert result.success?, "create failed: #{result.output}"

    # Verify target file exists
    assert container.file_exists?("/etc/systemd/system/myapp.target"),
      "Target file should exist"

    # Verify service file exists
    assert container.file_exists?("/etc/systemd/system/myapp-web.1.service"),
      "Service file should exist"

    # Verify target is enabled
    assert container.service_enabled?("myapp.target"),
      "Target should be enabled"

    # Verify service content includes environment
    service_content = container.read_file("/etc/systemd/system/myapp-web.1.service")
    assert_includes service_content, 'Environment="PORT=3000"'
    assert_includes service_content, 'Environment="RAILS_ENV=production"'
    assert_includes service_content, "ExecStart=/bin/bash -lc '/bin/sleep infinity'"
  end
end
