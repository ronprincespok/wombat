require 'yaml'
require 'json'
require 'erb'
require 'benchmark'
require 'fileutils'
require 'ms_rest_azure'

module Wombat
  module Common

    def banner(msg)
      puts "==> #{msg}"
    end

    def info(msg)
      puts "    #{msg}"
    end

    def warn(msg)
      puts ">>> #{msg}"
    end

    def duration(total)
      total = 0 if total.nil?
      minutes = (total / 60).to_i
      seconds = (total - (minutes * 60))
      format("%dm%.2fs", minutes, seconds)
    end

    def wombat
      @wombat_yml ||= ENV['WOMBAT_YML'] unless ENV['WOMBAT_YML'].nil?
      @wombat_yml ||= 'wombat.yml'
      if !File.exist?(@wombat_yml)
        warn('No wombat.yml found, copying example')
        gen_dir = "#{File.expand_path("../..", File.dirname(__FILE__))}/generator_files"
        FileUtils.cp_r "#{gen_dir}/wombat.yml", Dir.pwd
      end
      YAML.load(File.read(@wombat_yml))
    end

    def lock
      if !File.exist?('wombat.lock')
        warn('No wombat.lock found')
        return 1
      else
        JSON.parse(File.read('wombat.lock'))
      end
    end

    def bootstrap_aws
      @workstation_passwd = wombat['workstations']['password']
      rendered = ERB.new(File.read("#{conf['template_dir']}/bootstrap-aws.erb"), nil, '-').result(binding)
      Dir.mkdir("#{conf['packer_dir']}/scripts", 0755) unless File.exist?("#{conf['packer_dir']}/scripts")
      File.open("#{conf['packer_dir']}/scripts/bootstrap-aws.txt", 'w') { |file| file.puts rendered }
      banner("Generated: #{conf['packer_dir']}/scripts/bootstrap-aws.txt")
    end

    def parse_log(log, cloud)
      regex = case cloud
              when 'gcp'
                'A disk image was created:'
              when 'azure'

                if !wombat['azure'].key?('use_managed_disks') || !wombat['azure']['use_managed_disks']
                  '^OSDiskUri:'
                else
                  '^ManagedDiskOSDiskUri:'
                end

              else
                "#{wombat['aws']['region']}:"
              end

      File.read(log).split("\n").grep(/#{regex}/) {|x| x.split[1]}.last
    end

    def infranodes
      unless wombat['infranodes'].nil?
        wombat['infranodes'].sort
      else
        puts 'No infranodes listed in wombat.yml'
        {}
      end
    end

    def build_nodes
      build_nodes = {}
      1.upto(wombat['build-nodes']['count'].to_i) do |i|
        build_nodes["build-node-#{i}"] = i
      end
      build_nodes
    end

    def workstations
      workstations = {}
      1.upto(wombat['workstations']['count'].to_i) do |i|
        workstations["workstation-#{i}"] = i
      end
      workstations
    end

    def create_infranodes_json
      infranodes_file_path = File.join(conf['files_dir'], 'infranodes-info.json')
      if File.exists?(infranodes_file_path) && is_valid_json?(infranodes_file_path)
        current_state = JSON(File.read(infranodes_file_path))
      else
        current_state = nil
      end
      return if current_state == infranodes # yay idempotence
      File.open(infranodes_file_path, 'w') do |f|
        f.puts JSON.pretty_generate(infranodes)
      end
    end

    def linux
      wombat['linux'].nil? ? 'ubuntu' : wombat['linux']
    end

    def conf
      conf = wombat['conf']
      conf ||= {}
      conf['files_dir'] ||= 'files'
      conf['key_dir'] ||= 'keys'
      conf['cookbook_dir'] ||= 'cookbooks'
      conf['packer_dir'] ||= 'packer'
      conf['log_dir'] ||= 'logs'
      conf['stack_dir'] ||= 'stacks'
      conf['template_dir'] ||= 'templates'
      conf['timeout'] ||= 7200
      conf['audio'] ||= false
      conf
    end

    def is_mac?
      (/darwin/ =~ RUBY_PLATFORM) != nil
    end

    def audio?
      is_mac? && conf['audio']
    end

    def logs
      path = "#{conf['log_dir']}/#{cloud}*.log"
      Dir.glob(path).reject { |l| !l.match(wombat['linux']) }
    end

    def calculate_templates
    globs = "*.json"
      Dir.chdir(conf['packer_dir']) do
        Array(globs).
          map { |glob| result = Dir.glob("#{glob}"); result.empty? ? glob : result }.
          flatten.
          sort.
          delete_if { |file| file =~ /\.variables\./ }.
          map { |template| template.sub(/\.json$/, '') }
      end
    end

    def update_lock(cloud)
      copy = {}
      copy = wombat

      # Check that the copy contains a key for the named cloud
      unless copy.key?(cloud)
        throw "The Cloud '#{cloud}' is not specified in Wombat"
      end

      # Determine the region/location/zone for the specific cloud
      case cloud
      when 'aws'
        region = copy['aws']['region']
      when 'azure'
        region = copy['azure']['location']
      when 'gce'
        region = copy['gce']['zone']
      end

      linux = copy['linux']
      copy['amis'] = { region => {} }

      if logs.length == 0
        warn('No logs found - skipping lock update')
      else
        logs.each do |log|
          case log
          when /build-node/
            copy['amis'][region]['build-node'] ||= {}
            num = log.split('-')[3]
            copy['amis'][region]['build-node'].store(num, parse_log(log, cloud))
          when /workstation/
            copy['amis'][region]['workstation'] ||= {}
            num = log.split('-')[2]
            copy['amis'][region]['workstation'].store(num, parse_log(log, cloud))
          when /infranodes/
            copy['amis'][region]['infranodes'] ||= {}
            name = log.split('-')[2]
            copy['amis'][region]['infranodes'].store(name, parse_log(log, cloud))
          else
            instance = log.match("#{cloud}-(.*)-#{linux}\.log")[1]
            copy['amis'][region].store(instance, parse_log(log, cloud))
          end
        end
        copy['last_updated'] = Time.now.gmtime.strftime('%Y%m%d%H%M%S')
        banner('Updating wombat.lock')
        File.open('wombat.lock', 'w') do |f|
          f.write(JSON.pretty_generate(copy))
        end
      end
    end

    def update_template(cloud)
      if lock == 1
        warn('No lock - skipping template creation')
      else

        @demo = lock['name']
        @version = lock['version']
        @ttl = lock['ttl']

        # Determine the region/location/zone for the specific cloud
        case cloud
        when 'aws'
          region = lock['aws']['region']
          template_files = {
            "cfn.json.erb": "#{conf['stack_dir']}/#{@demo}.json"
          }
          @chef_server_ami = lock['amis'][region]['chef-server']
          @automate_ami = lock['amis'][region]['automate']
          @compliance_ami = lock['amis'][region]['compliance']
          @availability_zone = lock['aws']['az']
          @iam_roles = lock['aws']['iam_roles']
        when 'azure'
          region = lock['azure']['location']
          @storage_account = lock['azure']['storage_account']

          template_files = {}

          # determine whether to use VHD or Managed Disks
          if !lock['azure'].key?('use_managed_disks') || !lock['azure']['use_managed_disks']
            template_files['arm.vhd.json.erb'] = format("%s/%s.json", conf['stack_dir'], @demo)
          else
            template_files['arm.md.json.erb'] = format("%s/%s.json", conf['stack_dir'], @demo)
          end

          @chef_server_uri = lock['amis'][region]['chef-server']
          @automate_uri = lock['amis'][region]['automate']
          @compliance_uri = lock['amis'][region]['compliance']
          @password = lock['workstations']['password']
          @public_key = File.read("#{conf['key_dir']}/public.pub").chomp

          # Set the Azure Tag used to identify Chef products in Azure
          @chef_tag = azure_provider_tag
        when 'gce'
          region = lock['gce']['zone']
        end

        if lock['amis'][region].key?('build-node')
          @build_nodes = lock['build-nodes']['count'].to_i
          @build_node_ami = {}
          1.upto(@build_nodes) do |i|
            @build_node_ami[i] = lock['amis'][region]['build-node'][i.to_s]
          end
        end

        @infra = {}
        infranodes.each do |name, _rl|
          @infra[name] = lock['amis'][region]['infranodes'][name]
        end

        if lock['amis'][region].key?('workstation')
          @workstations = lock['workstations']['count'].to_i
          @workstation_ami = {}
          1.upto(@workstations) do |i|
            @workstation_ami[i] = lock['amis'][region]['workstation'][i.to_s]
          end
        end

        # Iterate around each of the template files that have been defined and render it
        template_files.each do |template_file, destination|
          rendered_cfn = ERB.new(File.read("#{conf['template_dir']}/#{template_file}"), nil, '-').result(binding)
          Dir.mkdir(conf['stack_dir'], 0755) unless File.exist?(conf['stack_dir'])
          File.open("#{destination}", 'w') { |file| file.puts rendered_cfn }
          banner("Generated: #{destination}")
        end
      end
    end

    def is_valid_json?(file)
      begin
        JSON.parse(file)
        true
      rescue JSON::ParserError => e
        false
      end
    end

    # Return the Azure Provider tag that should be applied to resource
    def azure_provider_tag
      "33194f91-eb5f-4110-827a-e95f640a9e46".upcase
    end

    # Connect to Azure using environment variables
    #
    # 
    def connect_azure

        # Create the connection to Azure using the information in the environment variables
        tenant_id = ENV['AZURE_TENANT_ID']
        client_id = ENV['AZURE_CLIENT_ID']
        client_secret = ENV['AZURE_CLIENT_SECRET']

        token_provider = MsRestAzure::ApplicationTokenProvider.new(tenant_id, client_id, client_secret)
        MsRest::TokenCredentials.new(token_provider)
    end

    # Track the progress of the deployment in Azure
    #
    # ===== Attributes
    #
    # * +rg_name+ - Name of the resource group being deployed to
    # * +deployment_name+ - Name of the deployment that is currently being processed
    def follow_azure_deployment(rg_name, deployment_name)

      end_provisioning_states = 'Canceled,Failed,Deleted,Succeeded'
      end_provisioning_state_reached = false

      until end_provisioning_state_reached
        list_outstanding_deployment_operations(rg_name, deployment_name)
        sleep 10
        deployment_provisioning_state = deployment_state(rg_name, deployment_name)
        end_provisioning_state_reached = end_provisioning_states.split(',').include?(deployment_provisioning_state)
      end
      info format("Resource Template deployment reached end state of %s", deployment_provisioning_state)
    end

    # Get a list of the outstanding deployment operations
    #
    # ===== Attributes
    #
    # * +rg_name+ - Name of the resource group being deployed to
    # * +deployment_name+ - Name of the deployment that is currently being processed    
    def list_outstanding_deployment_operations(rg_name, deployment_name)
      end_operation_states = 'Failed,Succeeded'
      deployment_operations = resource_management_client.deployment_operations.list(rg_name, deployment_name)
      deployment_operations.each do |val|
        resource_provisioning_state = val.properties.provisioning_state
        unless val.properties.target_resource.nil?
          resource_name = val.properties.target_resource.resource_name
          resource_type = val.properties.target_resource.resource_type
        end
        end_operation_state_reached = end_operation_states.split(',').include?(resource_provisioning_state)
        unless end_operation_state_reached
          info format("resource %s '%s' provisioning status is %s", resource_type, resource_name, resource_provisioning_state)
        end
      end
    end

    # Get the state of the specified deployment
    #
    # ===== Attributes
    #
    # * +rg_name+ - Name of the resource group being deployed to
    # * +deployment_name+ - Name of the deployment that is currently being processed     
    def deployment_state(rg_name, deployment_name)
      deployments = resource_management_client.deployments.get(rg_name, deployment_name)
      deployments.properties.provisioning_state
    end

    def create_resource_group(resource_management_client, name, location, owner = nil, rgtags = {})

      # Check that the resource group exists
      banner(format("Checking for resource group: %s", name))
      status = resource_management_client.resource_groups.check_existence(name)
      if status
        puts "resource group already exists"
      else
        puts format("creating new resource group in '%s'", location)

        # Set the parameters for the resource group
        resource_group = Azure::ARM::Resources::Models::ResourceGroup.new
        resource_group.location = location

        # Create hash to be used as tags on the resource group
        tags = {
          owner: ENV['USER'],
          provider: azure_provider_tag
        }

        # If an owner has been specified in the wombat file override the owner value
        if !owner.nil?
          tags[:owner] = owner
        end

        # Determine if there are any tags specified in the azure wmbat section that need to be added
        if !rgtags.nil? && rgtags.length > 0

          # Check to see if there are more than 15 tags in which case output a warning
          if rgtags.length > 14
            warn ('More than 15 tags have been specified, only the first 15 will be added.  This is a restriction in Azure.')
          end

          # Iterate around the tags and add each one to the tags array, up to 15
          rgtags.each_with_index do |(key, value), index|
            tags[key] = value

            if index == 12
              break
            end
          end

        end

        # add the tags hash to the parameters
        resource_group.tags = rgtags

        # Create the resource group
        resource_management_client.resource_groups.create_or_update(name, resource_group)
      end    
    end
  end
end