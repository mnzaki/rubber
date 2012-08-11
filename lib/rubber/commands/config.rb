
module Rubber
  module Commands

    class Config < Clamp::Command

      def self.subcommand_name
        "config"
      end

      def self.subcommand_description
        "Transform templates in the config/rubber tree"
      end
      
      def self.description
        "Generate system files by transforming the files in the config/rubber tree"
      end
      
      option ["--host", "-h"], "HOST", "Override the instance's host for generation"
      option ["--roles", "-r"], "ROLES", "Override the instance's roles for generation" do |str|
        str.split(/\s*,\s*/)
      end
      option ["--file", "-p"], "FILE", "Only generate files matching the given pattern"
      option ["--no_post", "-n"], :flag, "Skip running post commands"
      option ["--force", "-f"], :flag, "Overwrite files that already exist"
      
      def execute
        cfg = Rubber::Configuration.get_configuration(Rubber.env)
        instance_alias = cfg.environment.current_host
        instance = cfg.instance[instance_alias]

        # If we could not find the current host, try to discover it.
        # This is specially useful for autoscaled instances which will not have
        # a proper hostname on startup.
        if instance.nil? and Rubber.env == "production"
          require 'open-uri'
          env = Rubber::Configuration.rubber_env
          instance_id = nil
          Timeout::timeout(5) do
            instance_id = URI.parse('http://169.254.169.254/latest/meta-data/instance-id').read
          end
          cfg.instance.discover_instances if not env.instance_storage =~ /discover/
          instance = env.rubber_instances.detect {|i| i.instance_id == instance_id}
          if instance and instance.name
            system "sudo hostname #{instance.name}.#{env.domain}"
          end
        end

        if instance
          role_names = instance.role_names
          env = cfg.environment.bind(role_names, instance_alias)
          gen = Rubber::Configuration::Generator.new("#{Rubber.root}/config/rubber", role_names, instance_alias)
        elsif ['development', 'test'].include?(Rubber.env)
          instance_alias = host || instance_alias
          role_names = roles || cfg.environment.known_roles
          role_items = role_names.collect do |r|
            Rubber::Configuration::RoleItem.new(r, r == "db" ? {'primary' => true} : {})
          end
          env = cfg.environment.bind(role_names, instance_alias)
          domain = env.domain
          instance = Rubber::Configuration::InstanceItem.new(instance_alias, domain, role_items,
                                                             'dummyid', 'm1.small', 'ami-7000f019', ['dummygroup'])
          instance.external_host = instance.full_name
          instance.external_ip = "127.0.0.1"
          instance.internal_host = instance.full_name
          instance.internal_ip = "127.0.0.1"
          cfg.instance.add(instance)
          gen = Rubber::Configuration::Generator.new("#{Rubber.root}/config/rubber", role_names, instance_alias)
          gen.fake_root ="#{Rubber.root}/tmp/rubber"
        elsif Rubber::Configuration.rubber_env.discover_instances
          # Discover ourselves.
          # FIXME this is very AWS specific
          begin
            require 'open-uri'
            Timeout::timeout(5) do
              instance_id = URI.parse('http://169.254.169.254/latest/meta-data/instance-id').read
            end
            server = cloud.describe_instances(instance_id).first
            instance_roles = server.tags['Roles'].split('|').collect do |role_value|
              RoleItem.parse(role_value)
            end
            instance_alias = server.tags['Name']
            instance = Rubber::Configuration::InstanceItem.new(
                instance_alias,
                server.tags['Domain'],
                instance_roles,
                server.attributes[:id],
                server.attributes[:flavor_id],
                server.attributes[:image_id],
                server.attributes[:groups].reject {|sg| sg.match(/^sg/)})
            instance.external_host = server.attributes[:dns_name]
            instance.external_ip = server.attributes[:public_ip_address]
            instance.internal_host = server.attributes[:private_dns_name]
            instance.internal_ip = server.attributes[:private_ip_address]
            instance.zone = server.attributes[:availability_zone]
            instance.platform = server.attributes[:platform]
            instance.root_device_type = server.attributes[:root_device_type]

            cfg.instance.add(instance)
            env = cfg.environment.bind(role_names, instance_alias)
            gen = Rubber::Configuration::Generator.new(
              "#{Rubber.root}/config/rubber", server.tags['Roles'].gsub("|", ","), instance_alias)
          rescue
            puts "Instance not found for host: #{instance_alias}"
            exit 1
          end
        end

        if file
          gen.file_pattern = file
        end
        gen.no_post = no_post?
        gen.force = force?
        gen.stop_on_error_cmd = env.stop_on_error_cmd
        gen.run

      end

    end

  end
end
