require 'uri'

# Find the BGP neighbors, which is everyone except ourselves.
bgp_neighbors = search(:node, "role:compute").select { |n| n[:ipaddress] != node[:ipaddress] }

template "/etc/apt/sources.list.d/calico.list" do
    mode "0644"
    source "calico.list.erb"
    owner "root"
    group "root"
    variables({
        package_source: node[:calico][:package_source],
    })
    notifies :run, "execute[apt-key-calico]", :immediately
end
execute "apt-key-calico" do
    user "root"
    command "curl -L #{node[:calico][:package_key]} | sudo apt-key add -"
    action :nothing
    notifies :run, "execute[apt-get update]", :immediately
end
template "/etc/apt/preferences" do
    mode "0644"
    source "preferences.erb"
    owner "root"
    group "root"
    variables({
        package_host: URI.parse(node[:calico][:package_source].split[0]).host
    })
end

# Install NTP.
package "ntp" do
    action [:install]
end

# Configure sysctl so that forwarding is enabled, and router solicitations
# are accepted.  Allows SLAAC to provide an IPv6 address to the 
# control node without disabling forwarding. 
# ipv4.all.forwarding=1: enable IPv4 forwarding.
# ipv6.all.forwarding=1: enable IPv6 forwarding.
# ipv6.all.accept_ra=2: allow router solicitations/advertisements.
# ipv6.eth0.forwarding=0: additional config in case kernel doesn't support
#                    accept_ra=2.  Forwarding will still be enabled
#                    due to the ipv6.all config.
bash "config-sysctl" do
    user "root"
    code <<-EOH
    sysctl net.ipv4.conf.all.forwarding=1
    sysctl net.ipv6.conf.all.forwarding=1
    sysctl net.ipv6.conf.all.accept_ra=2
    sysctl net.ipv6.conf.eth0.forwarding=0
    EOH
end

# Installing MySQL is a pain. We can't use the OpenStack cookbook because it
# lacks features we need, so we need to do it by hand. First, prevent Ubuntu
# from asking us questions when we install the package. Then, install the
# package. With that done, setup config files and run setup scripts.
bash "debconf" do
    user "root"
    code <<-EOH
      debconf-set-selections <<< 'mysql-server mysql-server/root_password password #{node[:calico][:admin_password]}'
      debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password #{node[:calico][:admin_password]}'
      EOH
    not_if do
        File.exists?("/etc/mysql/my.cnf")
    end
end
package "python-mysqldb" do
    action [:install]
end
package "mysql-server" do
    action [:install]
    notifies :run, "bash[configure-mysql]", :immediately
end

template "/etc/mysql/my.cnf" do
    mode "0644"
    source "control/my.cnf.erb"
    owner "root"
    group "root"
    notifies :restart, "service[mysql]", :immediately
end
service "mysql" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
bash "configure-mysql" do
    action [:nothing]
    user "root"
    code <<-EOH
mysql_install_db
mysql_secure_installation <<EOF
#{node[:calico][:admin_password]}
n
Y
Y
Y
Y
EOF
EOH
end

# Install the RabbitMQ server.
package "rabbitmq-server" do
    action [:install]
    notifies :run, "execute[configure-rabbit]", :immediately
end
execute "configure-rabbit" do
    action [:nothing]
    command "rabbitmqctl change_password guest #{node[:calico][:admin_password]}"
end


# KEYSTONE

# Keystone requires that we do some manual database setup.
package "keystone" do
    action [:install]
    notifies :create, "template[/etc/keystone/keystone.conf]", :immediately
    notifies :run, "execute[remove-old-keystone-db]", :immediately
end
execute "remove-old-keystone-db" do
    action [:nothing]
    command "rm /var/lib/keystone/keystone.db"
    notifies :run, "bash[keystone-db-setup]", :immediately
end
bash "keystone-db-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
      mysql -u root -p#{node[:calico][:admin_password]} <<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '#{node[:calico][:admin_password]}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '#{node[:calico][:admin_password]}';
exit
      EOF
      EOH
    notifies :run, "execute[keystone-manage db_sync]", :immediately
end
execute "keystone-manage db_sync" do
    action [:nothing]
    user "keystone"
    notifies :run, "bash[initial-keystone]", :immediately
end

template "/etc/keystone/keystone.conf" do
    action [:nothing]
    mode "0640"
    source "control/keystone.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password],
        admin_token: node[:calico][:admin_token]
    })
    owner "keystone"
    group "keystone"
    notifies :restart, "service[keystone]", :immediately
end
service "keystone" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

# Create the initial keystone data.
bash "initial-keystone" do
    action [:nothing]
    user "root"
    environment ({
        "OS_SERVICE_TOKEN" => node[:calico][:admin_token],
        "OS_SERVICE_ENDPOINT" => "http://#{node[:fqdn]}:35357/v2.0",
        "OS_AUTH_URL" => "http://#{node[:fqdn]}:35357/v2.0"
    })
    code <<-EOH
    keystone user-create --name=admin --pass=#{node[:calico][:admin_password]} --email=nj@metaswitch.com
    keystone role-create --name=admin
    keystone tenant-create --name=admin --description="Admin Tenant"
    keystone user-role-add --user=admin --tenant=admin --role=admin
    keystone user-role-add --user=admin --role=_member_ --tenant=admin
    keystone user-create --name=demo --pass=#{node[:calico][:admin_password]} --email=nj@metaswitch.com
    keystone tenant-create --name=demo --description="Demo Tenant"
    keystone user-role-add --user=demo --role=_member_ --tenant=demo
    keystone tenant-create --name=service --description="Service Tenant"
    keystone service-create --name=keystone --type=identity --description="OpenStack Identity"
    keystone endpoint-create \
      --service-id=$(keystone service-list | awk '/ identity / {print $2}') \
      --publicurl=http://#{node[:fqdn]}:5000/v2.0 \
      --internalurl=http://#{node[:fqdn]}:5000/v2.0 \
      --adminurl=http://#{node[:fqdn]}:35357/v2.0
    EOH
end


# CLIENTS

package "python-cinderclient" do
    action [:install]
end
package "python-novaclient" do
    action [:install]
end
package "python-troveclient" do
    action [:install]
end
package "python-keystoneclient" do
    action [:install]
end
package "python-glanceclient" do
    action [:install]
end
package "python-neutronclient" do
    action [:install]
end
package "python-swiftclient" do
    action [:install]
end
package "python-heatclient" do
    action [:install]
end
package "python-ceilometerclient" do
    action [:install]
end

# Define the runtime environment for the clients.
ruby_block "environments" do
    block do
        # At this point we need the service tenant ID. To get it we need to shell out, so set
        # up the environment appropriately.
        ENV["OS_SERVICE_TOKEN"] = node[:calico][:admin_token]
        ENV["OS_SERVICE_ENDPOINT"] = "http://#{node[:fqdn]}:35357/v2.0"
        ENV["OS_AUTH_URL"] = "http://#{node[:fqdn]}:35357/v2.0"
        ENV["OS_USERNAME"] = "admin"
        ENV["OS_TENANT_NAME"] = "admin"
        ENV["OS_PASSWORD"] = node[:calico][:admin_password]
        node.set["run_env"] = {
            "OS_SERVICE_TOKEN" => node[:calico][:admin_token],
            "OS_SERVICE_ENDPOINT" => "http://#{node[:fqdn]}:35357/v2.0",
            "OS_AUTH_URL" => "http://#{node[:fqdn]}:35357/v2.0",
            "OS_USERNAME" => "admin",
            "OS_TENANT_NAME" => "admin",
            "OS_PASSWORD" => node[:calico][:admin_password]
        }
    end
    action :create
end

# GLANCE

package "glance" do
    action [:install]
    notifies :install, "package[python-glanceclient]", :immediately
    notifies :create, "template[/etc/glance/glance-api.conf]", :immediately
    notifies :create, "template[/etc/glance/glance-registry.conf]", :immediately
    notifies :run, "execute[remove-old-glance-db]", :immediately
end
execute "remove-old-glance-db" do
    action [:nothing]
    command "rm /var/lib/glance/glance.sqlite"
    returns [0, 1]
    notifies :run, "bash[glance-db-setup]", :immediately
end
bash "glance-db-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
      mysql -u root -p#{node[:calico][:admin_password]} <<EOF
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '#{node[:calico][:admin_password]}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '#{node[:calico][:admin_password]}';
exit
      EOF
      EOH
    notifies :run, "execute[glance-manage db_sync]", :immediately
end
execute "glance-manage db_sync" do
    action [:nothing]
    user "glance"
    notifies :run, "bash[initial-glance]", :immediately
end
bash "initial-glance" do
    action [:nothing]
    user "root"
    environment node["run_env"]
    code <<-EOH
    keystone user-create --name=glance --pass=#{node[:calico][:admin_password]} --email=nj@metaswitch.com
    keystone user-role-add --user=glance --tenant=service --role=admin
    keystone service-create --name=glance --type=image \
      --description="OpenStack Image Service"
    keystone endpoint-create \
      --service-id=$(keystone service-list | awk '/ image / {print $2}') \
      --publicurl=http://#{node[:fqdn]}:9292 \
      --internalurl=http://#{node[:fqdn]}:9292 \
      --adminurl=http://#{node[:fqdn]}:9292
    EOH
end

template "/etc/glance/glance-api.conf" do
    mode "0640"
    source "control/glance-api.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password]
    })
    owner "glance"
    group "glance"
    notifies :restart, "service[glance-api]", :immediately
end
template "/etc/glance/glance-registry.conf" do
    mode "0640"
    source "control/glance-registry.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password]
    })
    owner "glance"
    group "glance"
    notifies :restart, "service[glance-registry]", :immediately
end
service "glance-api" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "glance-registry" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

bash "cirros-image" do
    action [:run]
    user "root"
    environment node["run_env"]
    code <<-EOH
    wget http://cdn.download.cirros-cloud.net/0.3.2/cirros-0.3.2-x86_64-disk.img -O - | glance image-create --name=cirros-0.3.2-x86_64 --disk-format=qcow2 \
      --container-format=bare --is-public=true
    EOH
    not_if "glance image-list | grep cirros"
end

bash "ipv6-image" do
    action [:run]
    user "root"
    environment node["run_env"]
    code <<-EOH
    wget #{node[:calico][:ipv6_image_url]} -O - | glance image-create --name=ipv6_enabled_image --disk-format=qcow2 \
      --container-format=bare --is-public=true
    EOH
    only_if { node[:calico][:ipv6_image_url].to_s != "" && !system("glance image-list | grep ipv6") }
end


# NOVA

package "nova-api" do
    action [:install]
end
package "nova-cert" do
    action [:install]
end
package "nova-conductor" do
    action [:install]
end
package "nova-consoleauth" do
    action [:install]
end
package "nova-novncproxy" do
    action [:install]
end
package "nova-scheduler" do
    action [:install]
    notifies :create, "template[/etc/nova/nova.conf]", :immediately
    notifies :run, "execute[remove-old-nova-db]", :immediately
end

execute "remove-old-nova-db" do
    action [:nothing]
    command "rm /var/lib/nova/nova.sqlite"
    notifies :run, "bash[nova-db-setup]", :immediately
end
bash "nova-db-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
      mysql -u root -p#{node[:calico][:admin_password]} <<EOF
CREATE DATABASE nova;
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '#{node[:calico][:admin_password]}';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '#{node[:calico][:admin_password]}';
exit
      EOF
      EOH
    notifies :run, "execute[nova-manage db sync]", :immediately
end
execute "nova-manage db sync" do
    action [:nothing]
    user "nova"
    notifies :run, "bash[initial-nova]", :immediately
end
bash "initial-nova" do
    action [:nothing]
    user "root"
    environment node["run_env"]
    code <<-EOH
    keystone user-create --name=nova --pass=#{node[:calico][:admin_password]} --email=nj@metaswitch.com
    keystone user-role-add --user=nova --tenant=service --role=admin
    keystone service-create --name=nova --type=compute \
      --description="OpenStack Compute"
    keystone endpoint-create \
      --service-id=$(keystone service-list | awk '/ compute / {print $2}') \
      --publicurl=http://#{node[:fqdn]}:8774/v2/%\\(tenant_id\\)s \
      --internalurl=http://#{node[:fqdn]}:8774/v2/%\\(tenant_id\\)s \
      --adminurl=http://#{node[:fqdn]}:8774/v2/%\\(tenant_id\\)s
    EOH
    notifies :restart, "service[nova-scheduler]", :immediately
end

template "/etc/nova/nova.conf" do
    mode "0640"
    source "control/nova.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password]
    })
    owner "nova"
    group "nova"
    notifies :restart, "service[nova-api]", :immediately
    notifies :restart, "service[nova-cert]", :immediately
    notifies :restart, "service[nova-consoleauth]", :immediately
    notifies :restart, "service[nova-scheduler]", :immediately
    notifies :restart, "service[nova-conductor]", :immediately
    notifies :restart, "service[nova-novncproxy]", :immediately
end
service "nova-api" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "nova-cert" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "nova-consoleauth" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "nova-scheduler" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "nova-conductor" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "nova-novncproxy" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end


# NEUTRON

package "neutron-server" do
    action [:install]
    notifies :install, "package[neutron-plugin-ml2]", :immediately
    notifies :create, "template[/etc/neutron/neutron.conf]", :immediately
    notifies :run, "bash[neutron-db-setup]", :immediately
end
package "neutron-plugin-ml2" do
    action [:install]
end
bash "neutron-db-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
      mysql -u root -p#{node[:calico][:admin_password]} <<EOF
CREATE DATABASE neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '#{node[:calico][:admin_password]}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '#{node[:calico][:admin_password]}';
exit
      EOF
      EOH
    notifies :run, "bash[initial-neutron]", :immediately
end
bash "initial-neutron" do
    action [:nothing]
    user "root"
    environment node["run_env"]
    code <<-EOH
    keystone user-create --name neutron --pass #{node[:calico][:admin_password]} --email nj@metaswitch.com
    keystone user-role-add --user neutron --tenant service --role admin
    keystone service-create --name neutron --type network --description "OpenStack Networking"
    keystone endpoint-create \
      --service-id $(keystone service-list | awk '/ network / {print $2}') \
      --publicurl http://#{node[:fqdn]}:9696 \
      --adminurl http://#{node[:fqdn]}:9696 \
      --internalurl http://#{node[:fqdn]}:9696
    EOH
end

template "/etc/neutron/neutron.conf" do
    mode "0640"
    source "control/neutron.conf.erb"
    variables lazy {
        {
            admin_password: node[:calico][:admin_password],
            tenant_id: `keystone tenant-get service | grep id | awk '{print $4;}'`
        }
    }
    owner "neutron"
    group "neutron"
    notifies :restart, "service[neutron-server]", :immediately
end
service "neutron-server" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end


# HORIZON

package "apache2" do
    action [:install]
end
package "memcached" do
    action [:install]
end
package "libapache2-mod-wsgi" do
    action [:install]
end
package "openstack-dashboard" do
    action [:install]
end
package "openstack-dashboard-ubuntu-theme" do
    action [:purge]
end


# CINDER

package "cinder-api" do
    action [:install]
end
package "cinder-volume" do
    action [:install]
end
package "cinder-scheduler" do
    action [:install]
    notifies :create, "template[/etc/cinder/cinder.conf]", :immediately
    notifies :run, "bash[cinder-db-setup]", :immediately
end
bash "cinder-db-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
      mysql -u root -p#{node[:calico][:admin_password]} <<EOF
CREATE DATABASE cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '#{node[:calico][:admin_password]}';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '#{node[:calico][:admin_password]}';
exit
      EOF
      EOH
    notifies :run, "execute[cinder-manage db sync]", :immediately
end
execute "cinder-manage db sync" do
    action [:nothing]
    user "cinder"
    notifies :run, "bash[initial-cinder]", :immediately
end
bash "initial-cinder" do
    action [:nothing]
    user "root"
    environment node["run_env"]
    code <<-EOH
    keystone user-create --name=cinder --pass=#{node[:calico][:admin_password]} --email=nj@metaswitch.com
    keystone user-role-add --user=cinder --tenant=service --role=admin
    keystone service-create --name=cinder --type=volume --description="OpenStack Block Storage"
    keystone endpoint-create \
      --service-id=$(keystone service-list | awk '/ volume / {print $2}') \
      --publicurl=http://#{node[:fqdn]}:8776/v1/%\\(tenant_id\\)s \
      --internalurl=http://#{node[:fqdn]}:8776/v1/%\\(tenant_id\\)s \
      --adminurl=http://#{node[:fqdn]}:8776/v1/%\\(tenant_id\\)s

    keystone service-create --name=cinderv2 --type=volumev2 --description="OpenStack Block Storage v2"
    keystone endpoint-create \
      --service-id=$(keystone service-list | awk '/ volumev2 / {print $2}') \
      --publicurl=http://#{node[:fqdn]}:8776/v2/%\\(tenant_id\\)s \
      --internalurl=http://#{node[:fqdn]}:8776/v2/%\\(tenant_id\\)s \
      --adminurl=http://#{node[:fqdn]}:8776/v2/%\\(tenant_id\\)s
    EOH
end

package "lvm2" do
    action [:install]
    notifies :run, "bash[configure-lvm]", :immediately
end
bash "configure-lvm" do
    action [:nothing]
    user "root"
    code <<-EOH
    dd if=/dev/zero of=/root/cinder.img bs=4096 count=1M
    losetup /dev/loop0 /root/cinder.img
    pvcreate /dev/loop0
    vgcreate cinder-volumes /dev/loop0
    EOH
end

template "/etc/cinder/cinder.conf" do
    mode "0640"
    source "control/cinder.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password]
    })
    owner "cinder"
    group "cinder"
    notifies :restart, "service[cinder-scheduler]", :immediately
    notifies :restart, "service[cinder-api]", :immediately
    notifies :restart, "service[cinder-volume]", :immediately
    notifies :restart, "service[tgt]", :immediately
end
service "cinder-scheduler" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "cinder-api" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "cinder-volume" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
service "tgt" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end


# CALICO

package "calico-control" do
    action :install
    notifies :create, "template[/etc/calico/acl_manager.cfg]", :immediately
end

cookbook_file "/etc/neutron/plugins/ml2/ml2_conf.ini" do
    mode "0644"
    source "ml2_conf.ini"
    owner "root"
    group "neutron"
    notifies :restart, "service[neutron-server]", :immediately
end

service "calico-acl-manager" do
    provider Chef::Provider::Service::Upstart
    action [:nothing]
end

template "/etc/calico/acl_manager.cfg" do
    mode "0644"
    source "control/acl_manager.cfg.erb"
    owner "root"
    group "root"
    notifies :start, "service[calico-acl-manager]", :immediately
end


# DEPLOMENT SPECIFIC CONFIGURATION

bash "basic-networks" do
    action [:run]
    user "root"
    environment node["run_env"]
    code <<-EOH
    neutron net-create demo-net --shared
    neutron subnet-create demo-net --name demo-subnet \
      --gateway 10.28.0.1 10.28.0.0/16
    neutron subnet-create --ip-version 6 demo-net --name demo6-subnet \
      --gateway fd5f:5d21:845:1c2e:2::1 fd5f:5d21:845:1c2e:2::/80
    EOH
    not_if "neutron net-list | grep demo-net"
end
