require 'pathname'
require 'fileutils'

module Procsd
  class Generator
    attr_reader :app_name, :target_name

    def initialize(config, options)
      @config = config
      @options = options
      @app_name = @config[:app]
      @target_name = "#{app_name}.target"
    end

    def generate_units(save: false, user_mode: false)
      services = {}
      @config[:processes].each do |name, values|
        commands = values["commands"]
        size = values["size"]
        content = generate_template("service", @options.merge(
          "target_name" => target_name,
          "commands" => commands,
          "environment" => @config[:environment],
          "user_mode" => user_mode
        ))

        services[name] = { content: content, size: size }
      end

      if save
        systemd_dir = @config[:systemd_dir]
        puts "Creating app units files in the systemd directory (#{systemd_dir})..."

        # Ensure user systemd directory exists
        FileUtils.mkdir_p(systemd_dir) if user_mode

        wants = []
        services.each do |service_name, values|
          values[:size].times do |i|
            unit_name = "#{app_name}-#{service_name}.#{i + 1}.service"
            wants << unit_name
            write_file!(File.join(systemd_dir, unit_name), values[:content], user_mode: user_mode)
          end
        end

        target_content = generate_template("target", {
          "app" => app_name,
          "wants" => wants.join(" "),
          "user_mode" => user_mode
        })
        write_file!(File.join(systemd_dir, target_name), target_content, user_mode: user_mode)
      else
        services
      end
    end

    def generate_sudoers(user, has_reload:, save: false)
      systemctl_path = `which systemctl`.strip
      commands = []
      %w(start stop restart).each { |cmd| commands << "#{systemctl_path} #{cmd} #{target_name}" }
      commands << "#{systemctl_path} reload-or-restart #{app_name}-\\* --all" if has_reload
      content = "#{user} ALL=NOPASSWD: #{commands.join(', ')}"

      if save
        puts "Creating sudoers rule file in the sudoers.d directory (#{SUDOERS_DIR})..."
        temp_path = "/tmp/#{app_name}"
        dest_path = "#{SUDOERS_DIR}/#{app_name}"

        File.open(temp_path, "w") { |f| f.puts content }
        system "sudo", "chown", "root:root", temp_path
        system "sudo", "chmod", "0440", temp_path
        system "sudo", "mv", temp_path, dest_path
      else
        content
      end
    end

    def generate_nginx_conf(save: false)
      public_folder_path = @config[:nginx]["public_folder_path"] || "public"
      root_path = File.join(@options["dir"], public_folder_path)

      content = generate_template("nginx", {
        app_name: @config[:app],
        port: @config[:environment]["PORT"],
        server_name: @config[:nginx]["server_name"],
        root: root_path,
        error_500: File.exist?(File.join root_path, "500.html"),
        error_404: File.exist?(File.join root_path, "404.html"),
        error_422: File.exist?(File.join root_path, "422.html")
      })

      if save
        config_path = File.join(NGINX_DIR, "sites-available", app_name)
        puts "Creating Nginx config (#{config_path})..."
        write_file!(config_path, content)
        puts "Link Nginx config file to the sites-enabled folder..."
        system "sudo", "ln", "-nfs", config_path, File.join(NGINX_DIR, "sites-enabled")
      else
        content
      end
    end

    private

    def generate_template(template_name, conf)
      b = binding
      b.local_variable_set(:config, conf)
      template_path = File.join(File.dirname(__FILE__), "templates/#{template_name}.erb")
      content = File.read(template_path)
      ERB.new(content, trim_mode: "-").result(b)
    end

    def write_file!(dest_path, content, user_mode: false)
      if user_mode
        File.write(dest_path, content)
        puts "Create: #{dest_path}"
      else
        temp_path = File.join("/tmp", Pathname.new(dest_path).basename.to_s)
        begin
          File.write(temp_path, content)
          if system "sudo", "mv", temp_path, dest_path
            puts "Create: #{dest_path}"
          end
        ensure
          File.delete(temp_path) if File.exist?(temp_path)
        end
      end
    end
  end
end
