require 'yaml'
require 'monitor'

module Rubber
  module Configuration

    # Contains the ec2 instance configuration defined in instance.yml
    #
    class Instance
      attr_reader :instance_storage, :artifacts
      include Enumerable
      include MonitorMixin

      def initialize(instance_storage, opts={})
        super()
        
        @instance_storage = instance_storage
        @opts = opts
      
        @items = {}
        @artifacts = {'volumes' => {}, 'static_ips' => {}}

        @filters = Rubber::Util::parse_aliases(ENV['FILTER'])
        @filters, @filters_negated = @filters.partition {|f| f !~ /^-/ }
        @filters_negated = @filters_negated.collect {|f| f[1..-1] }

        @filter_roles = Rubber::Util::parse_aliases(ENV['FILTER_ROLES'])
        @filter_roles, @filter_roles_negated = @filter_roles.partition {|f| f !~ /^-/ }
        @filter_roles_negated = @filter_roles_negated.collect {|f| f[1..-1] }

        load()
      end
      
      def load(instance_storage=@instance_storage)
        case instance_storage
          when /file:(.*)/
            location = $1
            File.open(location, 'r') {|f| load_from_file(f) } if File.exist?(location)
          when /storage:(.*)/
            location = $1
            bucket = location.split("/")[0]
            key = location.split("/")[1..-1].join("/")
            data = Rubber.cloud.storage(bucket).fetch(key)
            StringIO.open(data, 'r') {|f| load_from_file(f) } if data
          when /table:(.*)/
            location = $1
            load_from_table(location)
          else
            raise "Invalid instance_storage: #{instance_storage}\n" +
                "Must be one of file:, table:, storage:"
        end
      end

      def load_from_file(io)
        item_list =  YAML.load(io.read)
        if item_list
          item_list.each do |i|
            if i.is_a? InstanceItem
              @items[i.name] = i
            elsif i.is_a? Hash
              @artifacts.merge!(i)
            end
          end
        end
        maybe_discover_instances
      end
      
      def load_from_table(table_key)
        Rubber.logger.debug{"Reading rubber instances from cloud table #{table_key}"}
        store = Rubber.cloud.table_store(table_key)
        items = store.find()
        items.each do |name, data|
          case name
            when '_artifacts_'
              @artifacts = data
            else
              ic = InstanceItem.from_hash(data.merge({'name' => name}))
              @items[ic.name] = ic 
          end
        end
        maybe_discover_instances
      end
      
      def save(instance_storage=@instance_storage, backup=@opts[:backup])
        synchronize do
          case instance_storage
            when /file:(.*)/
              location = $1
              File.open(location, 'w') {|f| save_to_file(f) }
            when /storage:(.*)/
              location = $1
              bucket = location.split("/")[0]
              key = location.split("/")[1..-1].join("/")
              data = StringIO.open {|f| save_to_file(f); f.string }
              Rubber.cloud.storage(bucket).store(key, data)
            when /table:(.*)/
              location = $1
              save_to_table(location)
            else
              raise "Invalid instance_storage: #{instance_storage}\n" +
                  "Must be one of file:, table:, storage:"
          end
        end
        
        save(backup, false) if backup
      end

      def save_to_file(io)
        data = []
        env = Rubber::Configuration.rubber_env
        data.push(*@items.values)
        data.push(@artifacts)
        io.write(YAML.dump(data))
      end
      
      def save_to_table(table_key)
        store = Rubber.cloud.table_store(table_key)
        
        # delete all before writing to handle removals
        store.find().each do |k, v|
          store.delete(k)
        end
        
        # only write out non-empty artifacts
        artifacts = @artifacts.select {|k, v| v.size > 0}
        if artifacts.size > 0
          store.put('_artifacts_', artifacts)
        end

        env = Rubber::Configuration.rubber_env
        # write out all the instance data
        @items.values.each do |item|
          store.put(item.name, item.to_hash)
        end
      end

      def maybe_discover_instances
        env = Rubber::Configuration.rubber_env
        if env.discover_instances
          servers = Rubber.cloud.compute_provider.servers

          items = servers.reject { |server| server.attributes[:state] == 'terminated' }.collect do |server|
            name = server.tags['Name']
            next if name.nil? and server.tags['aws:autoscaling:groupName'].nil?
            next if server.tags['Roles'].nil?
            roles = server.tags['Roles'].split('|').collect {|role_value|RoleItem.parse(role_value)}
            item = Rubber::Configuration::InstanceItem.new(
                name,
                server.tags['Domain'],
                roles,
                server.attributes[:id],
                server.attributes[:flavor_id],
                server.attributes[:image_id],
                server.attributes[:groups].reject {|sg| sg.match(/^sg/)})
            item.external_host = server.attributes[:dns_name]
            item.external_ip = server.attributes[:public_ip_address]
            item.internal_host = server.attributes[:private_dns_name]
            item.internal_ip = server.attributes[:private_ip_address]
            item.zone = server.attributes[:availability_zone]
            item.platform = server.attributes[:platform]
            item.root_device_type = server.attributes[:root_device_type]
            item
          end

          items = items.reject {|i| i.nil?}
          indices = {}

          items.each do |item|
            if item.name.nil?
              ag_group = server.tags['aws:autoscaling:groupName']
              if indices[ag_group].nil?
                items.each do |k, v|
                  next if k.nil?
                  match = k.match(ag_group + "-(\d)")
                  if match and match[1].to_i > indices[ag_group]
                    indices[ag_group] = match[1].to_i
                  end
                end
              end
              if indices[ag_group].nil?
                indices[ag_group] = 0
              end
              indices[ag_group] += 1
              item.name = ag_group + "-" + indices[ag_group].to_s
              Rubber.cloud.create_tags(server.attributes[:id], :Name => item.name)
            end
            @items[item.name] = item
          end

        end
      end
      
      def [](name)
        @items[name] || @items[name.gsub(/\..*/, '')]
      end

      # gets the instances for the given role.  If options is nil, all roles
      # match, otherwise the role has to have options that match exactly
      def for_role(role_name, options=nil)
        @items.values.find_all {|ic| ic.roles.any? {|r| r.name == role_name && (! options || r.options == options)}}
      end

      def filtered()
        filtered_results = []

        validate_filters()

        if @filters.size == 0 && @filter_roles.size == 0
          filtered_results.concat(@items.values)
        else
          @items.values.each do |ic|
              filtered_results << ic if @filters.include?(ic.name)
              filtered_results << ic if ic.roles.any? {|r| @filter_roles.include?(r.name)}
          end
        end

        filtered_results.delete_if {|ic| @filters_negated.include?(ic.name) }
        filtered_results.delete_if {|ic| ic.roles.any? {|r| @filter_roles_negated.include?(r.name)} }

        return filtered_results
      end

      def validate_filters()
        aliases = @items.values.collect{|ic| ic.name}
        [@filters, @filters_negated].flatten.each do |f|
          raise "Filter doesn't match any hosts: #{f}" if ! aliases.include?(f)
        end

        roles = all_roles
        [@filter_roles, @filter_roles_negated].flatten.each do |f|
          raise "Filter doesn't match any roles: #{f}" if ! roles.include?(f)
        end
      end

      def all_roles()
        @items.collect {|n, i| i.role_names}.flatten.uniq
      end

      def add(instance_item)
        @items[instance_item.name] = instance_item
      end

      def remove(name)
        @items.delete(name)
      end

      def each(&block)
        @items.values.each &block
      end
      
      def size
        @items.size
      end
    end

    # The configuration for a single instance
    class InstanceItem
      attr_reader :name, :domain, :instance_id, :image_type, :image_id, :security_groups
      attr_accessor :roles, :zone
      attr_accessor :external_host, :external_ip
      attr_accessor :internal_host, :internal_ip
      attr_accessor :static_ip, :volumes, :partitions, :root_device_type
      attr_accessor :spot_instance_request_id
      attr_accessor :platform

      def initialize(name, domain, roles, instance_id, image_type, image_id, security_group_list=[])
        @name = name
        @domain = domain
        @roles = roles
        @instance_id = instance_id
        @image_type = image_type
        @image_id = image_id
        @security_groups = security_group_list
      end

      def self.from_hash(hash)
        item = allocate
        hash.each do |k, v|
          sym = "@#{k}".to_sym
          v = v.collect {|r| RoleItem.parse(r) } if k == 'roles'
          item.instance_variable_set(sym, v)
        end
        return item
      end
      
      def to_hash
        hash = {}
        instance_variables.each do |iv|
          name = iv.to_s.gsub(/^@/, '')
          value = instance_variable_get(iv)
          value = value.collect {|r| r.to_s } if name == 'roles'
          hash[name] = value
        end
        return hash
      end
      
      def <=>(rhs)
        name <=> rhs.name
      end
      
      def full_name
        "#@name.#@domain"
      end

      def role_names()
        roles.collect {|r| r.name}
      end

      def platform
        # Deal with old instance configurations that don't have a platform value persisted.
        @platform || 'linux'
      end

      def windows?
        platform == 'windows'
      end
    end

    # The configuration for a single role contained in the list
    # of roles in InstanceItem
    class RoleItem
      attr_reader :name, :options

      def self.expand_role_dependencies(roles, dependency_map, expanded=[])
        roles = Array(roles)

        if expanded.size == 0
          common_deps = Array(dependency_map[RoleItem.new('common')])
          roles.concat(common_deps)
        end

        roles.each do |role|
          unless expanded.include?(role)
            expanded << role
            needed = dependency_map[role]
            expand_role_dependencies(needed, dependency_map, expanded)
          end
        end
        
        return expanded
      end

      def self.parse(str)
        data = str.split(':')
        role = Rubber::Configuration::RoleItem.new(data[0])
        if data[1]
          data[1].split(';').each do |pair|
            p = pair.split('=')
            val = case p[1]
                    when 'true' then true
                    when 'false' then false
                    else p[1] end
            role.options[p[0]] = val
          end
        end
        return role
      end

      def to_s
        str = @name
        @options.each_with_index do |kv, i|
          str += (i == 0 ? ':' : ';')
          str += "#{kv[0]}=#{kv[1]}"
        end
        return str
      end

      def initialize(name, options={})
        @name = name
        @options = options || {}
      end

      def eql?(rhs)
        rhs && @name == rhs.name && @options == rhs.options
      end
      alias == eql?

      def hash()
        @name.hash
      end

      def <=>(rhs)
        return @name <=> rhs.name
      end
    end

  end
end

