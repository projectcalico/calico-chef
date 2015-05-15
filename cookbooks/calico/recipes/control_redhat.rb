require 'uri'

# Find the BGP neighbors, which is everyone except ourselves.
bgp_neighbors = search(:node, "role:compute").select { |n| n[:ipaddress] != node[:ipaddress] }

# Tell yum about the Calico repository server.
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
remote_file "#{Chef::Config[:file_cache_path]}/epel-release-7-5.noarch.rpm" do
    source "http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm"
    action :create
end
remote_file "#{Chef::Config[:file_cache_path]}/rdo-release-juno.rpm" do
    source "http://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm"
    action :create
end

rpm_package "epel-release" do
    source "#{Chef::Config[:file_cache_path]}/epel-release-7-5.noarch.rpm"
    action :install
end
rpm_package "rdo-release" do
    source "#{Chef::Config[:file_cache_path]}/rdo-release-juno.rpm"
    action :install
end

yum_repository 'rhel-7-server-extras-rpms' do
  description 'Red Hat Enterprise Linux 7 Server - Extras (RPMs)'
  mirrorlist 'https://cdn.redhat.com/content/dist/rhel/server/7/7Server/$basearch/extras/os' 
  enabled true
  action :create
end
yum_repository 'rhel-7-server-optional-rpms' do
  description 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)'
  mirrorlist 'https://cdn.redhat.com/content/dist/rhel/server/7/$releasever/$basearch/optional/os' 
  enabled true
  notifies :run, "bash[subscribe]", :immediately
  notifies :run, "bash[disableNM]", :immediately
  action :create
end

bash "subscribe" do
    action [:nothing]
    user "root"
    code <<-EOF
subscription-manager repos --enable rhel-7-server-optional-rpms
subscription-manager repos --enable rhel-7-server-extras-rpms
EOF
end

bash "disableNM" do
    action [:nothing]
    user "root"
    code <<-EOF
systemctl stop NetworkManager
systemctl disable NetworkManager
systemctl enable network
EOF
end

# Start RDO install
package "openstack-packstack" do
    action [:install]
end

# create answerfile from template
template "/root/answers.cfg" do
    source "answers.erb"
    owner "root"
    group "root"
    variables({
        admin_pass: node[:calico][:admin_password],
        controllers: search(:node, "role:controller"), 
        computes: search(:node, "role:compute"),
    })
end

bash "run_packstack" do
    action [:nothing]
    user "root"
    code <<-EOH
packstack --answer-file=answers.cfg <<EOF
dcl1234!
dcl1234!
dcl1234!
EOF
EOH
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


# # Output and store the UID and GID for nova - this may be required for live migration
# execute "get-nova-info" do
    # command "id nova >> /tmp/nova.user"
# end
# ruby_block "store-nova-user-info" do
    # block do
        # output = ::File.read("/tmp/nova.user")
        # match = /uid=(?<uid>\d+).*gid=(?<gid>\d+).*/.match(output)
        # node.set["nova_uid"] = match[:uid]
        # node.set["nova_gid"] = match[:gid]
    # end
# end

# # CALICO

# package "python-devel" do
    # action :install
# end
# package "libffi-devel" do
    # action :install
# end
# package "openssl-devel" do
    # action :install
# end

# package "etcd" do
    # action :install
# end
# template "/etc/init/etcd.conf" do
    # mode "0640"
    # source "control/etcd.conf.erb"
    # owner "root"
    # group "root"
    # notifies :run, "bash[etcd-setup]", :immediately
    # notifies :run, "bash[get-python-etcd]", :immediately
# end

# # This action removes the etcd database and restarts it.
# bash "etcd-setup" do
    # action [:nothing]
    # user "root"
    # code <<-EOH
    # rm -rf /var/lib/etcd/*
    # service etcd restart
    # EOH
# end

# bash "get-python-etcd" do
    # action [:nothing]
    # user "root"
    # code <<-EOH
    # curl -L https://github.com/Metaswitch/python-etcd/archive/master.tar.gz -o python-etcd.tar.gz
    # tar xvf python-etcd.tar.gz
    # cd python-etcd-master
    # python setup.py install
    # EOH
# end

# package "calico-control" do
    # action :install
# end

# cookbook_file "/etc/neutron/plugins/ml2/ml2_conf.ini" do
    # mode "0644"
    # source "ml2_conf.ini"
    # owner "root"
    # group "neutron"
    # notifies :restart, "service[openstack-neutron-server]", :immediately
# end


# # DEPLOMENT SPECIFIC CONFIGURATION

# bash "basic-networks" do
    # action [:run]
    # user "root"
    # environment node["run_env"]
    # code <<-EOH
    # neutron net-create demo-net --shared
    # neutron subnet-create demo-net --name demo-subnet \
      # --gateway 10.28.0.1 10.28.0.0/16
    # neutron subnet-create --ip-version 6 demo-net --name demo6-subnet \
      # --gateway fd5f:5d21:845:1c2e:2::1 fd5f:5d21:845:1c2e:2::/80
    # EOH
    # not_if "neutron net-list | grep demo-net"
# end


# # LIVE MIGRATION CONFIGURATION

# # Install NFS kernel server.
# package "nfs-kernel-server" do
    # action [:nothing]
    # only_if { node[:calico][:live_migrate] }
    # notifies :run, "ruby_block[configure-idmapd]", :immediately
    # notifies :create_if_missing, "directory[/var/lib/nova_share]", :immediately
    # notifies :create_if_missing, "directory[/var/lib/nova_share/instances]", :immediately
    # notifies :run, "ruby_block[add-unrestricted-share]", :immediately
    # notifies :run, "execute[reload-nfs-cfg]", :immediately
    # notifies :restart, "service[nfs-kernel-server]", :immediately
    # notifies :restart, "service[idmapd]", :immediately
# end

# # Ensure idmapd configuration is correct
# ruby_block "configure-idmapd" do
    # block do
        # file = Chef::Util::FileEdit.new("/etc/idmapd.conf")
        # file.insert_line_if_no_match(/\[Mapping\]\s/, "[Mapping]")
        # file.insert_line_after_match(/\[Mapping\]\s/, "Nobody-Group = nogroup")
        # file.insert_line_after_match(/\[Mapping\]\s/, "Nobody-User = nobody")
        # file.write_file
    # end
    # action [:nothing]
# end

# # Create share point
# directory "/var/lib/nova_share" do
    # owner "nova"
    # group "nova"
    # mode "0755"
    # action [:nothing]
# end
# directory "/var/lib/nova_share/instances" do
    # owner "nova"
    # group "nova"
    # mode "0755"
    # action [:nothing]
# end

# # Add an unrestricted entry to the share point
# ruby_block "add-unrestricted-share" do
    # block do
        # file = Chef::Util::FileEdit.new("/etc/exports")
        # entry = "/var/lib/nova_share/instances *(rw,fsid=0,insecure,no_subtree_check,async,no_root_squash)"
        # file.insert_line_if_no_match(/#{entry}/, entry)
        # file.write_file
    # end
    # action [:nothing]
# end

# execute "reload-nfs-cfg" do
    # command "exportfs -r"
    # action [:nothing]
# end

# service "nfs-kernel-server" do
    # action [:nothing]
# end

# service "idmapd" do
    # action [:nothing]
# end
