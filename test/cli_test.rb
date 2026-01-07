require "test_helper"
require "procsd/cli"
require "tmpdir"

class CLITest < Minitest::Test
  def setup
    @original_dir = Dir.pwd
  end

  def teardown
    Dir.chdir(@original_dir)
  end

  def test_preload_basic_procsd_yml
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal({
        processes: {
          "web" => {
            "commands" => { "ExecStart" => "bundle exec puma" },
            "size" => 1
          }
        },
        app: "myapp",
        environment: {},
        dev_environment: {},
        user_mode: false,
        systemd_dir: "/etc/systemd/system",
        nginx: nil
      }, config)
    end
  end

  def test_preload_with_procfile
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
      YAML
      File.write("Procfile", <<~PROCFILE)
        web: bundle exec puma
        worker: bundle exec sidekiq
      PROCFILE

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal({
        processes: {
          "web" => {
            "commands" => { "ExecStart" => "bundle exec puma" },
            "size" => 1
          },
          "worker" => {
            "commands" => { "ExecStart" => "bundle exec sidekiq" },
            "size" => 1
          }
        },
        app: "myapp",
        environment: {},
        dev_environment: {},
        user_mode: false,
        systemd_dir: "/etc/systemd/system",
        nginx: nil
      }, config)
    end
  end

  def test_preload_with_formation
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        formation: web=2,worker=3
        processes:
          web:
            ExecStart: bundle exec puma
          worker:
            ExecStart: bundle exec sidekiq
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal 2, config[:processes]["web"]["size"]
      assert_equal 3, config[:processes]["worker"]["size"]
    end
  end

  def test_preload_with_environment
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        environment:
          PORT: 3000
          RAILS_ENV: production
        dev_environment:
          RAILS_ENV: development
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal({ "PORT" => 3000, "RAILS_ENV" => "production" }, config[:environment])
      assert_equal({ "RAILS_ENV" => "development" }, config[:dev_environment])
    end
  end

  def test_preload_with_all_process_commands
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
            ExecStop: bundle exec pumactl stop
            ExecReload: bundle exec pumactl phased-restart
            RuntimeMaxSec: 86400
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal({
        "ExecStart" => "bundle exec puma",
        "ExecStop" => "bundle exec pumactl stop",
        "ExecReload" => "bundle exec pumactl phased-restart",
        "RuntimeMaxSec" => 86400
      }, config[:processes]["web"]["commands"])
    end
  end

  def test_preload_with_user_mode
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        user_mode: true
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal true, config[:user_mode]
      assert_equal File.join(ENV["HOME"], ".config/systemd/user"), config[:systemd_dir]
    end
  end

  def test_preload_with_custom_systemd_dir
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        systemd_dir: /custom/systemd/path
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal "/custom/systemd/path", config[:systemd_dir]
    end
  end

  def test_preload_with_nginx
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
        nginx:
          server_name: example.com
          ssl: true
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal({ "server_name" => "example.com", "ssl" => true }, config[:nginx])
    end
  end

  def test_preload_with_erb_in_yaml
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      ENV["TEST_APP_NAME"] = "dynamic_app"
      File.write("procsd.yml", <<~YAML)
        app: <%= ENV["TEST_APP_NAME"] %>
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)
      config = cli.instance_variable_get(:@config)

      assert_equal "dynamic_app", config[:app]
    ensure
      ENV.delete("TEST_APP_NAME")
    end
  end

  def test_preload_raises_without_procsd_yml
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)

      cli = Procsd::CLI.new
      error = assert_raises(Procsd::CLI::ConfigurationError) { cli.send(:preload!) }

      assert_equal "Config file procsd.yml doesn't exists", error.message
    end
  end

  def test_preload_raises_without_app_name
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      error = assert_raises(Procsd::CLI::ConfigurationError) { cli.send(:preload!) }

      assert_equal "Missing app name in the procsd.yml file", error.message
    end
  end

  def test_preload_raises_without_processes_or_procfile
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
      YAML

      cli = Procsd::CLI.new
      error = assert_raises(Procsd::CLI::ConfigurationError) { cli.send(:preload!) }

      assert_equal "Procfile doesn't exists. Define processes in procsd.yml or create Procfile", error.message
    end
  end

  def test_preload_raises_without_exec_start
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStop: bundle exec pumactl stop
      YAML

      cli = Procsd::CLI.new
      error = assert_raises(Procsd::CLI::ConfigurationError) { cli.send(:preload!) }

      assert_equal "Missing ExecStart command for `web` process", error.message
    end
  end

  def test_units
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        formation: web=2,worker=1
        processes:
          web:
            ExecStart: bundle exec puma
          worker:
            ExecStart: bundle exec sidekiq
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      assert_equal [
        "myapp.target",
        "myapp-web.1.service",
        "myapp-web.2.service",
        "myapp-worker.1.service"
      ], cli.send(:units)
    end
  end

  def test_has_reload_true
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
            ExecReload: bundle exec pumactl phased-restart
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      assert cli.send(:has_reload?)
    end
  end

  def test_has_reload_false
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      refute cli.send(:has_reload?)
    end
  end

  def test_target_name
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      assert_equal "myapp.target", cli.send(:target_name)
    end
  end

  def test_to_full_name
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      assert_equal "myapp-web*", cli.send(:to_full_name, "web")
    end
  end

  def test_get_certbot_command_basic
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
        nginx:
          server_name: example.com
          ssl: true
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      ENV.delete("CERTBOT_EMAIL")
      expected = %w[sudo certbot --agree-tos --no-eff-email --redirect --non-interactive --nginx -d example.com --register-unsafely-without-email]

      assert_equal expected, cli.send(:get_certbot_command)
    end
  end

  def test_get_certbot_command_with_email
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
        nginx:
          server_name: example.com
          ssl: true
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      ENV["CERTBOT_EMAIL"] = "admin@example.com"
      expected = %w[sudo certbot --agree-tos --no-eff-email --redirect --non-interactive --nginx -d example.com --email admin@example.com]

      assert_equal expected, cli.send(:get_certbot_command)
    ensure
      ENV.delete("CERTBOT_EMAIL")
    end
  end

  def test_get_certbot_command_with_multiple_domains
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir)
      File.write("procsd.yml", <<~YAML)
        app: myapp
        processes:
          web:
            ExecStart: bundle exec puma
        nginx:
          server_name: example.com www.example.com api.example.com
          ssl: true
      YAML

      cli = Procsd::CLI.new
      cli.send(:preload!)

      ENV.delete("CERTBOT_EMAIL")
      expected = %w[sudo certbot --agree-tos --no-eff-email --redirect --non-interactive --nginx -d example.com -d www.example.com -d api.example.com --register-unsafely-without-email]

      assert_equal expected, cli.send(:get_certbot_command)
    end
  end
end
