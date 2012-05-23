module Rubber
  module Tag
    # Updates the tags for the given ec2 instance
    def self.update_instance_tags(instance_alias)
      instance_item = Rubber.instances[instance_alias]
      raise "Instance does not exist: #{instance_alias}" if ! instance_item

      concatenated_roles = instance_item.roles.collect do | role_item |
        role_item.to_s
      end.join(',')
      Rubber.cloud.create_tags(instance_item.instance_id, :Name => instance_alias, :Environment => Rubber.env, :Roles => concatenated_roles, :Domain => instance_item.domain)
    end
  end
end