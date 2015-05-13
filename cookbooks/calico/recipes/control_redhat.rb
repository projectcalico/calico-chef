require 'uri'

# Find the BGP neighbors, which is everyone except ourselves.
bgp_neighbors = search(:node, "role:compute").select { |n| n[:ipaddress] != node[:ipaddress] }

# Tell apt about the Calico repository server.
template "/etc/yum.repos.d/calico.repo" do
    mode "0644"
    source "calico.repo.erb"
    owner "root"
    group "root"
    variables({
        package_source: node[:calico][:package_source],
        package_key: node[:calico][:package_key],
    })
    # notifies :run, "execute[apt-key-calico]", :immediately
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
cookbook_file "/etc/sysctl.conf" do
    source "sysctl.conf"
    mode "0644"
    owner "root"
    group "root"
    notifies :run, "execute[read-sysctl]", :immediately
end
execute "read-sysctl" do
    user "root"
    command "sysctl -p"
    action [:nothing]
end

# Prereqs
#package "yum-plugin-priorities" do
#    action [:install]
#end
#package "http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm" do
#    action [:install]
#end

# Enable Openstack repo
package "http://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm" do
    action [:install]
end

# install selinux
package "openstack-selinux" do
    action [:install]
end

# mysql
package ['MySQL-python', 'mariadb', 'mariadb-server'] do
    action [:install]
    notifies :run, "bash[configure-mysql]", :immediately
end

template "/etc/my.cnf" do
    mode "0644"
    source "control/my.cnf.erb"
    owner "root"
    group "root"
    notifies :restart, "service[mariadb]", :immediately
end

service "mariadb" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end

bash "configure-mysql" do
    action [:nothing]
    user "root"
    code <<-EOH
mysql_secure_installation <<EOF

Y
{node[:calico][:admin_password]}
{node[:calico][:admin_password]}
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
service "rabbitmq-server" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
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

package ['openstack-keystone', 'python-keystoneclient'] do
    action [:install]
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
    notifies :restart, "service[openstack-keystone]", :immediately
end

service "openstack-keystone" do
    provider Chef::Provider::Service::Systemd
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

package ['openstack-glance', 'python-glanceclient'] do
    action [:install]
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
    notifies :restart, "service[openstack-glance-api]", :immediately
end
template "/etc/glance/glance-registry.conf" do
    mode "0640"
    source "control/glance-registry.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password]
    })
    owner "glance"
    group "glance"
    notifies :restart, "service[openstack-glance-registry]", :immediately
end
service "openstack-glance-api" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-glance-registry" do
    provider Chef::Provider::Service::Systemd
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

package "openstack-nova-api" do
    action [:install]
end
package "openstack-nova-cert" do
    action [:install]
end
package "openstack-nova-console" do
    action [:install]
end
package "openstack-nova-novncproxy" do
    action [:install]
end
package "openstack-nova-scheduler" do
    action [:install]
    notifies :create, "template[/etc/nova/nova.conf]", :immediately
    notifies :run, "execute[remove-old-nova-db]", :immediately
end
template "/etc/nova/nova.conf" do
    mode "0640"
    source "control/nova.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password],
        live_migrate: node[:calico][:live_migrate]
    })
    owner "nova"
    group "nova"
    notifies :install, "package[nfs-kernel-server]", :immediately
    notifies :restart, "service[openstack-nova-api]", :immediately
    notifies :restart, "service[openstack-nova-cert]", :immediately
    notifies :restart, "service[openstack-nova-consoleauth]", :immediately
    notifies :restart, "service[openstack-nova-scheduler]", :immediately
    notifies :restart, "service[openstack-nova-novncproxy]", :immediately
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
    notifies :install, "package[openstack-nova-conductor]", :immediately
end

# Install conductor after syncing the database - if conductor is running during the resync
# it is possible to hit window conditions adding duplicate entries to the DB.
package "openstack-nova-conductor" do
    action [:nothing]
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
    notifies :restart, "service[openstack-nova-scheduler]", :immediately
end

service "openstack-nova-api" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-nova-cert" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-nova-consoleauth" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-nova-scheduler" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-nova-conductor" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-nova-novncproxy" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end

# Output and store the UID and GID for nova - this may be required for live migration
execute "get-nova-info" do
    command "id nova >> /tmp/nova.user"
end
ruby_block "store-nova-user-info" do
    block do
        output = ::File.read("/tmp/nova.user")
        match = /uid=(?<uid>\d+).*gid=(?<gid>\d+).*/.match(output)
        node.set["nova_uid"] = match[:uid]
        node.set["nova_gid"] = match[:gid]
    end
end


# NEUTRON

package "openstack-neutron-server" do
    action [:install]
    notifies :install, "package[openstack-neutron-plugin-ml2]", :immediately
    notifies :create, "template[/etc/neutron/neutron.conf]", :immediately
    notifies :run, "bash[neutron-db-setup]", :immediately
end
package "openstack-neutron-plugin-ml2" do
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
    notifies :restart, "service[openstack-neutron-server]", :immediately
end
service "openstack-neutron-server" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end


# HORIZON

package "openstack-dashboard" do
    action [:install]
end
package "httpd" do
    action [:install]
end
package "mod_wsgi" do
    action [:install]
end
package "memcached" do
    action [:install]
end
package "python-memcached" do
    action [:install]
end


# CINDER

package "openstack-cinder" do
    action [:install]
end
package "openstack-cinderclient" do
    action [:install]
    notifies :create, "template[/etc/cinder/cinder.conf]", :immediately
    notifies :run, "bash[cinder-db-setup]", :immediately
end
package "python-oslo-db" do
    action [:install]
end
package "targetcli" do
    action [:install]
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
    notifies :restart, "service[openstack-cinder-scheduler]", :immediately
    notifies :restart, "service[openstack-cinder-api]", :immediately
    notifies :restart, "service[openstack-cinder-volume]", :immediately
    notifies :restart, "service[target]", :immediately
end
service "lvm2-lvmetad" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end

service "openstack-cinder-scheduler" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-cinder-api" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "openstack-cinder-volume" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end
service "target" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end


# CALICO

package "python-devel" do
    action :install
end
package "libffi-devel" do
    action :install
end
package "openssl-devel" do
    action :install
end

package "etcd" do
    action :install
end
template "/etc/init/etcd.conf" do
    mode "0640"
    source "control/etcd.conf.erb"
    owner "root"
    group "root"
    notifies :run, "bash[etcd-setup]", :immediately
    notifies :run, "bash[get-python-etcd]", :immediately
end

# This action removes the etcd database and restarts it.
bash "etcd-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
    rm -rf /var/lib/etcd/*
    service etcd restart
    EOH
end

bash "get-python-etcd" do
    action [:nothing]
    user "root"
    code <<-EOH
    curl -L https://github.com/Metaswitch/python-etcd/archive/master.tar.gz -o python-etcd.tar.gz
    tar xvf python-etcd.tar.gz
    cd python-etcd-master
    python setup.py install
    EOH
end

package "calico-control" do
    action :install
end

cookbook_file "/etc/neutron/plugins/ml2/ml2_conf.ini" do
    mode "0644"
    source "ml2_conf.ini"
    owner "root"
    group "neutron"
    notifies :restart, "service[openstack-neutron-server]", :immediately
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


# LIVE MIGRATION CONFIGURATION

# Install NFS kernel server.
package "nfs-kernel-server" do
    action [:nothing]
    only_if { node[:calico][:live_migrate] }
    notifies :run, "ruby_block[configure-idmapd]", :immediately
    notifies :create_if_missing, "directory[/var/lib/nova_share]", :immediately
    notifies :create_if_missing, "directory[/var/lib/nova_share/instances]", :immediately
    notifies :run, "ruby_block[add-unrestricted-share]", :immediately
    notifies :run, "execute[reload-nfs-cfg]", :immediately
    notifies :restart, "service[nfs-kernel-server]", :immediately
    notifies :restart, "service[idmapd]", :immediately
end

# Ensure idmapd configuration is correct
ruby_block "configure-idmapd" do
    block do
        file = Chef::Util::FileEdit.new("/etc/idmapd.conf")
        file.insert_line_if_no_match(/\[Mapping\]\s/, "[Mapping]")
        file.insert_line_after_match(/\[Mapping\]\s/, "Nobody-Group = nogroup")
        file.insert_line_after_match(/\[Mapping\]\s/, "Nobody-User = nobody")
        file.write_file
    end
    action [:nothing]
end

# Create share point
directory "/var/lib/nova_share" do
    owner "nova"
    group "nova"
    mode "0755"
    action [:nothing]
end
directory "/var/lib/nova_share/instances" do
    owner "nova"
    group "nova"
    mode "0755"
    action [:nothing]
end

# Add an unrestricted entry to the share point
ruby_block "add-unrestricted-share" do
    block do
        file = Chef::Util::FileEdit.new("/etc/exports")
        entry = "/var/lib/nova_share/instances *(rw,fsid=0,insecure,no_subtree_check,async,no_root_squash)"
        file.insert_line_if_no_match(/#{entry}/, entry)
        file.write_file
    end
    action [:nothing]
end

execute "reload-nfs-cfg" do
    command "exportfs -r"
    action [:nothing]
end

service "nfs-kernel-server" do
    action [:nothing]
end

service "idmapd" do
    action [:nothing]
end
