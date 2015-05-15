# Find the controller node.  We use its FQDN and IP address below.
controller = search(:node, "role:controller")[0]

# Find the other compute nodes.  This is everyone except ourselves.
# These are both our BGP neighbors and a list of nodes that we need to share passwordless
# nova authentication with.
other_compute = search(:node, "role:compute").select { |n| n[:ipaddress] != node[:ipaddress] }

# Grab the right IPv6 address because there's more than one to choose from.
get_ipv6 = Proc.new do |node|
    addresses = node[:network][:interfaces][:eth0][:addresses]
    global_ipv6 = addresses.select do |address, info|
        info[:family] == 'inet6' && info[:scope] == 'Global'
    end
    if global_ipv6.empty?
        global_ipv6 = addresses.select do |address, info|
            info[:family] == 'inet6' && info[:scope] == 'Site'
        end
    end
    global_ipv6.keys.sort[0].to_s
end


# Tell apt about the Calico repository server.
template "/etc/yum.repos.d/calico.repo" do
    mode "0644"
    source "calico.repo.erb"
    owner "root"
    group "root"
    variables({
        package_source: node[:calico][:package_source],
    })
    # notifies :run, "execute[apt-key-calico]", :immediately
end

# Configure sysctl so that forwarding is enabled, and router solicitations
# are accepted.  Allows SLAAC to provide an IPv6 address to each compute
# node without disabling forwarding.
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

# Install a few needed packages.
package "ntp" do
    action [:install]
end

bash "disableNM" do
    action [:run]
    user "root"
    code <<-EOF
systemctl stop NetworkManager
systemctl disable NetworkManager
systemctl enable network
EOF
end

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

# CALICO

# install BIRD from EPEL
package "bird" do
    action [:install]
    notifies :create, "template[/etc/bird/bird.conf]", :immediately
    notifies :create, "template[/etc/bird/bird6.conf]", :immediately
end

# Make a startup file for it so it runs as a service
template "/etc/init/bird.conf" do
    mode "0644"
    source "compute/bird.init.erb"
    owner "root"
    group "root"
    notifies :restart, "service[bird]", :immediately
end

# Start the service
service "bird" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end

# Install etcd and friends.
package "python-etcd" do
    action :install
end
package "etcd" do
    action :install
end
template "/etc/init/etcd.conf" do
    mode "0640"
    source "compute/etcd.conf.erb"
    variables({
        controller: controller[:fqdn],
        controller_ip: controller[:ipaddress]
    })
    owner "root"
    group "root"
    notifies :run, "bash[etcd-setup]", :immediately
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

package "calico-compute" do
    action [:install]
    notifies :restart, "service[libvirt-bin]", :delayed
    notifies :create, "template[/etc/calico/felix.cfg]", :immediately
end

template "/etc/bird/bird.conf" do
    mode "0640"
    source "compute/bird.conf.erb"
    variables({
        bgp_neighbors: other_compute
    })
    owner "bird"
    group "bird"
    notifies :restart, "service[bird]", :delayed
end

template "/etc/bird/bird6.conf" do
    mode "0640"
    source "compute/bird6.conf.erb"
    variables({
        bgp_neighbors: other_compute,
        get_ipv6: get_ipv6
    })
    owner "bird"
    group "bird"
    not_if { get_ipv6.call(node).empty? }
    notifies :restart, "service[bird6]", :delayed
end

service "bird" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end

service "bird6" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true
    action [:nothing]
end

service "calico-felix" do
    provider Chef::Provider::Service::Systemd
    action [:nothing]
end

template "/etc/calico/felix.cfg" do
    mode "0644"
    source "compute/felix.cfg.erb"
    variables({
        controller: controller[:fqdn]
    })
    owner "root"
    group "root"
    notifies :start, "service[calico-felix]", :immediately
end

# LIVE MIGRATION CONFIGURATION

# Kick off the set of live migration tasks.  Start by getting the nova and
# gid and uid.  We need to ensure these are the same across all nodes.
execute "live-migration" do
    action [:nothing]
    only_if { node[:calico][:live_migrate] }
    command "id nova >> /tmp/nova.user"
    notifies :stop, "service[nova-compute]", :immediately
    notifies :stop, "service[nova-api-metadata]", :immediately
    notifies :stop, "service[libvirt-bin]", :immediately
    notifies :run, "ruby_block[update-libvirt]", :immediately
    notifies :run, "ruby_block[fix-nova-files]", :immediately
    notifies :install, "package[nfs-common]", :immediately
    notifies :create_if_missing, "directory[/var/lib/nova_share]", :immediately
    notifies :create_if_missing, "directory[/var/lib/nova_share/instances]", :immediately
    notifies :run, "ruby_block[persist-share-config]", :immediately
    notifies :run, "execute[mount-share]", :immediately
    notifies :start, "service[nova-api-metadata]", :immediately
    notifies :start, "service[libvirt-bin]", :immediately
    notifies :start, "service[nova-compute]", :immediately
end

# Update the libvirt configuration required to get live migration working.
ruby_block "update-libvirt" do
    action [:nothing]
    block do
        file = Chef::Util::FileEdit.new("/etc/libvirt/libvirtd.conf")
        file.search_file_replace_line(/.*listen_tls.*/, "listen_tls=0")
        file.search_file_replace_line(/.*listen_tcp.*/, "listen_tcp=1")
        file.search_file_replace_line(/.*auth_tcp.*/, "auth_tcp=\"none\"")
        file.insert_line_if_no_match(/.*listen_tls.*/, "listen_tls=0")
        file.insert_line_if_no_match(/.*listen_tcp.*/, "listen_tcp=1")
        file.insert_line_if_no_match(/.*auth_tcp.*/, "auth_tcp=\"none\"")
        file.write_file
        file = Chef::Util::FileEdit.new("/etc/default/libvirt-bin")
        file.search_file_replace_line(/libvirtd_opts\s*=\s*\".*/, "libvirtd_opts=\" -d -l\"")
        file.write_file
        file = Chef::Util::FileEdit.new("/etc/init/libvirt-bin.conf")
        file.search_file_replace_line(/\s*env\s*libvirtd_opts\s*=\s*\".*/, "env libvirtd_opts=\" -d -l\"")
        file.write_file
    end
end

ruby_block "fix-nova-files" do
    action [:nothing]
    block do
        output = ::File.read("/tmp/nova.user")
        match = /uid=(?<uid>\d+).*gid=(?<gid>\d+).*/.match(output)
        node.set["nova_uid"] = match[:uid]
        node.set["nova_gid"] = match[:gid]
    end
    notifies :run, "execute[set-nova-uid]", :immediately
    notifies :run, "execute[set-nova-gid]", :immediately
    notifies :run, "execute[fix-nova-files-uid]", :immediately
    notifies :run, "execute[fix-nova-files-gid]", :immediately
end

# It can take some time for all resources to stop using nova, so allow retries
# if this command fails.
execute "set-nova-uid" do
    action [:nothing]
    command "usermod -u #{controller[:nova_uid]} nova"
    retries 5
end

execute "set-nova-gid" do
    action [:nothing]
    command "groupmod -g #{controller[:nova_gid]} nova"
    retries 5
end

execute "fix-nova-files-uid" do
    action [:nothing]
    command lazy { "find / -path /proc -prune -o -uid #{node[:nova_uid]} -exec chown nova {} \\;" }
end
execute "fix-nova-files-gid" do
    action [:nothing]
    command lazy { "find / -path /proc -prune -o -gid #{node[:nova_gid]} -exec chgrp nova {} \\;" }
end

# Install NFS kernel server.
package "nfs-common" do
    action [:nothing]
end

# Create share point.
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

# Add a persistent entry for the share point.
ruby_block "persist-share-config" do
    block do
        file = Chef::Util::FileEdit.new("/etc/fstab")
        entry = "#{controller[:fqdn]}:/ /var/lib/nova_share/instances nfs4 defaults 0 0"
        file.insert_line_if_no_match(/#{entry}/, entry)
        file.write_file
    end
    action [:nothing]
end

# Mount the share.
execute "mount-share" do
    command "mount -v -t nfs4 -o nfsvers=4 #{controller[:fqdn]}:/ /var/lib/nova_share/instances"
    action [:nothing]
end
