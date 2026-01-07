require 'dotenv/load'
require 'thor'
require 'erb'
require 'procsd/version'

module Procsd
  DEFAULT_SYSTEMD_DIR = "/etc/systemd/system".freeze
  USER_SYSTEMD_DIR = File.join(ENV["HOME"], ".config/systemd/user").freeze
  SUDOERS_DIR = "/etc/sudoers.d".freeze
  NGINX_DIR = "/etc/nginx".freeze
end
