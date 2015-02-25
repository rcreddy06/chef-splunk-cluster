#
# Cookbook Name::splunk
# Recipe::server
#
# Copyright 2011-2012, BBY Solutions, Inc.
# Copyright 2011-2012, Opscode, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
service "splunk" do
  action [ :nothing ]
  supports  :status => true, :start => true, :stop => true, :restart => true
end

# True for both a standalone install OR dedicated search head in distributed search setup
dedicated_search_head = true
# True for a dedicated indexer in distributed search setup
dedicated_indexer = false
# True for a cluster search head in cluster setup
cluster_search_head = false
# True for a cluster master in cluster setup
cluster_master = false
# True for a cluster peer node in cluster setup
cluster_peer = false

splunk_cmd = "#{node['splunk']['server_home']}/bin/splunk"
splunk_package_version = "splunk-#{node['splunk']['server_version']}-#{node['splunk']['server_build']}"

splunk_file = splunk_package_version +
  case node['platform']
  when "centos","redhat","fedora","amazon"
    if node['kernel']['machine'] == "x86_64"
      "-linux-2.6-x86_64.rpm"
    else
      ".i386.rpm"
    end
  when "debian","ubuntu"
    if node['kernel']['machine'] == "x86_64"
      "-linux-2.6-amd64.deb"
    else
      "-linux-2.6-intel.deb"
    end
  end

remote_file "#{Chef::Config['file_cache_path']}/#{splunk_file}" do
  source "#{node['splunk']['server_root']}/#{node['splunk']['server_version']}/splunk/linux/#{splunk_file}"
  action :create_if_missing
end

package splunk_package_version do
  source "#{Chef::Config['file_cache_path']}/#{splunk_file}"
  case node['platform']
  when "centos","redhat","fedora","amazon"
    provider Chef::Provider::Package::Rpm
  when "debian","ubuntu"
    provider Chef::Provider::Package::Dpkg
  end
end

if node['splunk']['distributed_search'] == true
	if Chef::Config[:solo]
		Chef::Log.warn("This recipe uses search. Chef Solo does not support search.")
	else
	  # Add the Distributed Search Template
	  node.normal['splunk']['static_server_configs'] << "distsearch"

	  # We are a search head
	  if node.run_list.include?("role[#{node['splunk']['server_role']}]")
	    search_indexers = search(:node, "role:#{node['splunk']['indexer_role']}")
	    # Add an outputs.conf.  Search Heads should not be doing any indexing
	    node.normal['splunk']['static_server_configs'] << "outputs"
	  else
	    dedicated_search_head = false
	  end

	  # we are a dedicated indexer
	  if node.run_list.include?("role[#{node['splunk']['indexer_role']}]")
	    # Find all search heads so we can move their trusted.pem files over
	    search_heads = search(:node, "role:#{node['splunk']['server_role']}")
	    dedicated_indexer = true
	  end
	end
end

if node['splunk']['cluster_deployment'] == true
  # Disable dedicated search head which is the default
  dedicated_search_head = false

  # Deduce cluster node type from run list
  cluster_search_head = node.run_list.include?("role[#{node['splunk']['cluster_search_role']}]")
  cluster_peer = node.run_list.include?("role[#{node['splunk']['cluster_indexer_role']}]")
  cluster_master = node.run_list.include?("role[#{node['splunk']['cluster_master_role']}]")

  clustering_mode = cluster_master ? 'master' : (cluster_peer ? 'peer' : 'search-head')
  Chef::Log.info("Current node clustering mode: #{clustering_mode}")

  # Add Server Config template
  #node.normal['splunk']['static_server_configs'] << "server"

  if cluster_master
    cluster_master_node = node
  else
    # Identity cluster master node
    if Chef::Config[:solo]
      # Create in-memory node hash with locally available information
      cluster_master_node = {
        'ipaddress' => node['splunk']['cluster_master_host'],
        'splunk' => {
          'mgmt_server_port' => node['splunk']['cluster_master_port'] || 8089
        }
      }
    else
      # Retrieve node from Chef server
      cluster_master_node = search(:node, "role:#{node['splunk']['cluster_master_role']}")
      if cluster_master_node.kind_of? Array
        cluster_master_node = cluster_master_node.last
      end
    end
  end
  if cluster_master_node
    Chef::Log.info("Found clustering master: #{cluster_master_node['ipaddress']}")
  end
end

template "#{node['splunk']['server_home']}/etc/splunk-launch.conf" do
    source "server/splunk-launch.conf.erb"
    mode "0640"
    owner "root"
    group "root"
end

if node['splunk']['use_ssl'] == true && dedicated_search_head == true

  directory "#{node['splunk']['server_home']}/ssl" do
    owner "root"
    group "root"
    mode "0755"
    action :create
    recursive true
  end

  cookbook_file "#{node['splunk']['server_home']}/ssl/#{node['splunk']['ssl_crt']}" do
    source "ssl/#{node['splunk']['ssl_crt']}"
    mode "0755"
    owner "root"
    group "root"
  end

  cookbook_file "#{node['splunk']['server_home']}/ssl/#{node['splunk']['ssl_key']}" do
    source "ssl/#{node['splunk']['ssl_key']}"
    mode "0755"
    owner "root"
    group "root"
  end

end

if node['splunk']['ssl_forwarding'] == true
  # Create the SSL Cert Directory for the Forwarders
  directory "#{node['splunk']['server_home']}/etc/auth/forwarders" do
    owner "root"
    group "root"
    action :create
    recursive true
  end

  # Copy over the SSL Certs
  [node['splunk']['ssl_forwarding_cacert'],node['splunk']['ssl_forwarding_servercert']].each do |cert|
    cookbook_file "#{node['splunk']['server_home']}/etc/auth/forwarders/#{cert}" do
      source "ssl/forwarders/#{cert}"
      owner "root"
      group "root"
      mode "0755"
      notifies :restart, "service[splunk]"
    end
  end

  # SSL passwords are encrypted when splunk reads the file.  We need to save the password.
  # We need to save the password if it has changed so we don't keep restarting splunk.
  # Splunk encrypted passwords always start with $1$
  ruby_block "Saving Encrypted Password (inputs.conf/outputs.conf)" do
    block do
      inputsPass = `grep -m 1 "password = " #{node['splunk']['server_home']}/etc/system/local/inputs.conf | sed 's/password = //'`
      if inputsPass.match(/^\$1\$/) && inputsPass != node['splunk']['inputsSSLPass']
        node.normal['splunk']['inputsSSLPass'] = inputsPass
        node.save
      end

      if node['splunk']['distributed_search'] == true && dedicated_search_head == true
          outputsPass = `grep -m 1 "sslPassword = " #{node['splunk']['server_home']}/etc/system/local/outputs.conf | sed 's/sslPassword = //'`

          if outputsPass.match(/^\$1\$/) && outputsPass != node['splunk']['outputsSSLPass']
            node.normal['splunk']['outputsSSLPass'] = outputsPass
            node.save
          end
        end
    end
  end
end

# Enable splunk
execute "#{splunk_cmd} enable boot-start --accept-license --answer-yes" do
  not_if do
    File.symlink?('/etc/rc3.d/S20splunk') ||
    File.symlink?('/etc/rc3.d/S90splunk')
  end
end

# Change password
splunk_password = node['splunk']['auth'].split(':')[1]
execute "Changing Admin Password" do
  command "#{splunk_cmd} edit user admin -password #{splunk_password} -roles admin -auth admin:changeme && echo true > /opt/splunk_setup_passwd"
  not_if do
    File.exists?("/opt/splunk_setup_passwd")
  end
end

# Add enterprise license if one specified
if node['splunk']['license_path'] != ""
  execute "Adding Enterprise License #{node['splunk']['license_path']}" do
    command "#{splunk_cmd} add licenses #{node['splunk']['license_path']} -auth #{node['splunk']['auth']} && echo true > /opt/splunk_setup_license"
    ignore_failure true
    not_if do
      File.exists?("/opt/splunk_setup_license")
    end
  end
end

# Enable receiving ports only if we are a dedicated indexer or a cluster peer node, or a standalone installation
if dedicated_indexer == true || cluster_peer == true || (node['splunk']['cluster_deployment'] == false && node['splunk']['distributed_search'] == false)
  execute "Enabling Receiver Port #{node['splunk']['receiver_port']}" do
    command "#{splunk_cmd} enable listen #{node['splunk']['receiver_port']} -auth #{node['splunk']['auth']}"
    not_if "grep splunktcp:#{node['splunk']['receiver_port']} #{node['splunk']['server_home']}/etc/system/local/inputs.conf"
  end
end

if node['splunk']['scripted_auth'] == true && dedicated_search_head == true
  # Be sure to deploy the authentication template.
  node.normal['splunk']['static_server_configs'] << "authentication"

  if !node['splunk']['data_bag_key'].empty?
    scripted_auth_creds = Chef::EncryptedDataBagItem.load(node['splunk']['scripted_auth_data_bag_group'], node['splunk']['scripted_auth_data_bag_name'], node['splunk']['data_bag_key'])
  else
    scripted_auth_creds = { "user" => "", "password" => ""}
  end

  directory "#{node['splunk']['server_home']}/#{node['splunk']['scripted_auth_directory']}" do
    recursive true
    action :create
  end

  node['splunk']['scripted_auth_files'].each do |auth_file|
    cookbook_file "#{node['splunk']['server_home']}/#{node['splunk']['scripted_auth_directory']}/#{auth_file}" do
      source "scripted_auth/#{auth_file}"
      owner "root"
      group "root"
      mode "0755"
      action :create
    end
  end

  node['splunk']['scripted_auth_templates'].each do |auth_templ|
    template "#{node['splunk']['server_home']}/#{node['splunk']['scripted_auth_directory']}/#{auth_templ}" do
      source "server/scripted_auth/#{auth_templ}.erb"
      owner "root"
      group "root"
      mode "0744"
      variables(
        :user => scripted_auth_creds['user'],
        :password => scripted_auth_creds['password']
      )
    end
  end
end

node['splunk']['static_server_configs'].each do |cfg|
  template "#{node['splunk']['server_home']}/etc/system/local/#{cfg}.conf" do
   	source "server/#{cfg}.conf.erb"
   	owner "root"
   	group "root"
   	mode "0640"
    variables(
        # set of nodes
        :search_heads => search_heads,
        :search_indexers => search_indexers,
        :cluster_master_node => cluster_master_node,
        # set of booleans
        :dedicated_search_head => dedicated_search_head,
        :dedicated_indexer => dedicated_indexer,
        :cluster_search_head => cluster_search_head,
        :cluster_master => cluster_master,
        :cluster_peer => cluster_peer
      )
    notifies :restart, "service[splunk]"
  end
end

node['splunk']['dynamic_server_configs'].each do |cfg|
  template "#{node['splunk']['server_home']}/etc/system/local/#{cfg}.conf" do
   	source "server/#{node['splunk']['server_config_folder']}/#{cfg}.conf.erb"
   	owner "root"
   	group "root"
   	mode "0640"
    notifies :restart, "service[splunk]"
   end
end


template "/etc/init.d/splunk" do
    source "server/splunk.erb"
    mode "0755"
    owner "root"
    group "root"
end

directory "#{node['splunk']['server_home']}/etc/users/admin/search/local/data/ui/views" do
  owner "root"
  group "root"
  mode "0755"
  action :create
  recursive true
end

if node['splunk']['deploy_dashboards'] == true
  node['splunk']['dashboards_to_deploy'].each do |dashboard|
    cookbook_file "#{node['splunk']['server_home']}/etc/users/admin/search/local/data/ui/views/#{dashboard}.xml" do
      source "dashboards/#{dashboard}.xml"
    end
  end
end

# Link to license master (if any) in distributed environment
if node['splunk']['cluster_deployment'] == true || node['splunk']['distributed_search'] == true
  # We are license master if our private ip matches what we set
  # the license master to be or if specifically designated as such
  license_master = node['splunk']['is_license_master'] || (node['splunk']['license_master_host'] == node['ipaddress'])

  # We are not the license master.. we need to link up to the master for our license information
  if license_master == false
    license_master_ip = ''
    if node['splunk']['license_master_host'] != ''
      license_master_host = node['splunk']['license_master_host']
    elsif not Chef::Config[:solo]
      license_master_node = search(:node, "is_license_master:true")
      if license_master_node.kind_of? Array
        license_master_node = license_master_node.first
      end
      if license_master_node
        license_master_host = license_master_node['ipaddress']
      end
    end

    if license_master_host != ''
      Chef::Log.info("Link up with license master: #{license_master_host}")
      execute "Linking splunk license to license master" do
        command "#{splunk_cmd} edit licenser-localslave -master_uri 'https://#{license_master_host}:8089' -auth #{node['splunk']['auth']}"
        retries 5
        ignore_failure true
        notifies :restart, resources(:service => "splunk")
      end
    end
  end
end

if node['splunk']['distributed_search'] == true
  if dedicated_search_head == true
    # We save this information so we can reference it on indexers.
    ruby_block "Splunk Dedicated Search Head - Saving Info" do
      block do
        splunk_server_name = `grep -m 1 "serverName = " #{node['splunk']['server_home']}/etc/system/local/server.conf | sed 's/serverName = //'`
        splunk_server_name = splunk_server_name.strip

        if File.exists?("#{node['splunk']['server_home']}/etc/auth/distServerKeys/trusted.pem")
          trustedPem = IO.read("#{node['splunk']['server_home']}/etc/auth/distServerKeys/trusted.pem")
          if node['splunk']['trustedPem'] == nil || node['splunk']['trustedPem'] != trustedPem
            node.default['splunk']['trustedPem'] = trustedPem
            node.save
          end
        end

        if node['splunk']['splunkServerName'] == nil || node['splunk']['splunkServerName'] != splunk_server_name
          node.default['splunk']['splunkServerName'] = splunk_server_name
          node.save
        end
      end
    end
  end

  if dedicated_indexer == true
    search_heads.each do |server|
      if server['splunk'] != nil && server['splunk']['trustedPem'] != nil && server['splunk']['splunkServerName'] != nil
        directory "#{node['splunk']['server_home']}/etc/auth/distServerKeys/#{server['splunk']['splunkServerName']}" do
          owner "root"
          group "root"
          action :create
        end

        file "#{node['splunk']['server_home']}/etc/auth/distServerKeys/#{server['splunk']['splunkServerName']}/trusted.pem" do
          owner "root"
          group "root"
          mode "0600"
          content server['splunk']['trustedPem'].strip
          action :create
          notifies :restart, "service[splunk]"
        end
      end
    end
  end
end # End of distributed search

service "splunk" do
  action :start
end
