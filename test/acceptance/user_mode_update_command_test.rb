require_relative "user_mode_helper"

class UserModeUpdateCommandTest < Minitest::Test
  include UserModeHelper

  def setup
    setup_container
  end

  def teardown
    teardown_container
  end

  # Baseline test: verify create command works correctly in user mode
  def test_create_command_creates_services_and_target
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
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

    # Verify target file exists in user systemd dir
    assert container.file_exists?("#{user_systemd_dir}/myapp.target"),
      "Target file should exist"

    # Verify service file exists
    assert container.file_exists?("#{user_systemd_dir}/myapp-web.1.service"),
      "Service file should exist"

    # Verify target is enabled
    assert container.service_enabled?("myapp.target"),
      "Target should be enabled"

    # Verify linger was auto-enabled so services start at boot
    assert container.file_exists?("/var/lib/systemd/linger/testuser"),
      "Linger should be enabled for testuser"

    # Verify service content includes environment
    service_content = container.read_file("#{user_systemd_dir}/myapp-web.1.service")
    assert_includes service_content, 'Environment="PORT=3000"'
    assert_includes service_content, 'Environment="RAILS_ENV=production"'
    assert_includes service_content, "ExecStart=/bin/bash -lc '/bin/sleep infinity'"
  end

  def test_update_when_target_does_not_exist
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("update")
    refute result.success?, "update should fail when target doesn't exist"
    assert_includes result.output, "not exists"
  end

  def test_update_with_environment_change
    # First create the service
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
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

    # Start the service
    result = run_procsd("start")
    assert result.success?, "start failed: #{result.output}"
    assert container.service_active?("myapp-web.1.service"), "Service should be active"

    # Update with changed environment
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      environment:
        PORT: 4000
        RAILS_ENV: staging
        NEW_VAR: new_value
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("update")
    assert result.success?, "update failed: #{result.output}"

    # Verify service file was updated
    service_content = container.read_file("#{user_systemd_dir}/myapp-web.1.service")
    assert_includes service_content, 'Environment="PORT=4000"'
    assert_includes service_content, 'Environment="RAILS_ENV=staging"'
    assert_includes service_content, 'Environment="NEW_VAR=new_value"'

    # Verify service is still running
    assert container.service_active?("myapp-web.1.service"),
      "Service should still be active after update"
  end

  def test_update_with_scale_up
    # Create with web=1
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("create")
    assert result.success?, "create failed: #{result.output}"

    result = run_procsd("start")
    assert result.success?, "start failed: #{result.output}"

    # Verify only one service exists
    services = container.list_service_files("myapp-web.*.service")
    assert_equal ["myapp-web.1.service"], services

    # Update to web=2
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=2
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("update")
    assert result.success?, "update failed: #{result.output}"

    # Verify both services exist
    services = container.list_service_files("myapp-web.*.service")
    assert_includes services, "myapp-web.1.service"
    assert_includes services, "myapp-web.2.service"

    # Verify both services are active
    assert container.service_active?("myapp-web.1.service"),
      "Service 1 should be active"
    assert container.service_active?("myapp-web.2.service"),
      "Service 2 should be active"
  end

  def test_update_with_scale_down
    # Create with web=2
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=2
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("create")
    assert result.success?, "create failed: #{result.output}"

    result = run_procsd("start")
    assert result.success?, "start failed: #{result.output}"

    # Verify both services exist and are running
    assert container.service_active?("myapp-web.1.service")
    assert container.service_active?("myapp-web.2.service")

    # Update to web=1
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("update")
    assert result.success?, "update failed: #{result.output}"

    # Verify orphaned service was stopped and removed
    services = container.list_service_files("myapp-web.*.service")
    assert_equal ["myapp-web.1.service"], services,
      "Only web.1 service should remain"

    # Verify orphan file is gone
    refute container.file_exists?("#{user_systemd_dir}/myapp-web.2.service"),
      "Orphaned service file should be removed"

    # Verify remaining service is still active
    assert container.service_active?("myapp-web.1.service"),
      "Remaining service should still be active"
  end

  def test_update_with_new_process_type
    # Create with only web
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("create")
    assert result.success?, "create failed: #{result.output}"

    result = run_procsd("start")
    assert result.success?, "start failed: #{result.output}"

    # Verify only web service exists
    refute container.file_exists?("#{user_systemd_dir}/myapp-worker.1.service")

    # Add worker process
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1,worker=1
      processes:
        web:
          ExecStart: /bin/sleep infinity
        worker:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("update")
    assert result.success?, "update failed: #{result.output}"

    # Verify worker service was created
    assert container.file_exists?("#{user_systemd_dir}/myapp-worker.1.service"),
      "Worker service file should exist"

    # Verify worker service is active
    assert container.service_active?("myapp-worker.1.service"),
      "Worker service should be active"

    # Verify web service is still active
    assert container.service_active?("myapp-web.1.service"),
      "Web service should still be active"
  end

  def test_update_with_removed_process_type
    # Create with web and worker
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1,worker=1
      processes:
        web:
          ExecStart: /bin/sleep infinity
        worker:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("create")
    assert result.success?, "create failed: #{result.output}"

    result = run_procsd("start")
    assert result.success?, "start failed: #{result.output}"

    # Verify both services are running
    assert container.service_active?("myapp-web.1.service")
    assert container.service_active?("myapp-worker.1.service")

    # Remove worker process
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      processes:
        web:
          ExecStart: /bin/sleep infinity
    YML

    result = run_procsd("update")
    assert result.success?, "update failed: #{result.output}"

    # Verify worker service was stopped and removed
    refute container.file_exists?("#{user_systemd_dir}/myapp-worker.1.service"),
      "Worker service file should be removed"

    # Verify web service is still active
    assert container.service_active?("myapp-web.1.service"),
      "Web service should still be active"
  end

  def test_update_with_exec_start_change
    # Create service
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      processes:
        web:
          ExecStart: /bin/sleep 1000
    YML

    result = run_procsd("create")
    assert result.success?, "create failed: #{result.output}"

    result = run_procsd("start")
    assert result.success?, "start failed: #{result.output}"

    # Get the initial PID
    pid_result = container.exec_as_user("systemctl --user show myapp-web.1.service --property=MainPID --value")
    initial_pid = pid_result.stdout.strip

    # Change ExecStart command
    create_procsd_yml(<<~YML)
      app: myapp
      user_mode: true
      formation: web=1
      processes:
        web:
          ExecStart: /bin/sleep 2000
    YML

    result = run_procsd("update")
    assert result.success?, "update failed: #{result.output}"

    # Verify service file was updated
    service_content = container.read_file("#{user_systemd_dir}/myapp-web.1.service")
    assert_includes service_content, "/bin/sleep 2000"

    # Service should be restarted (new PID)
    # Give it a moment to restart
    sleep 1
    pid_result = container.exec_as_user("systemctl --user show myapp-web.1.service --property=MainPID --value")
    new_pid = pid_result.stdout.strip

    refute_equal initial_pid, new_pid,
      "Service should have been restarted (different PID)"

    assert container.service_active?("myapp-web.1.service"),
      "Service should still be active"
  end
end
