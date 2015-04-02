# Find the controller FQDN.
controller = search(:node, "role:controller")[0][:fqdn]

# Find the other compute nodes.  This is everyone except ourselves.
# These are both our BGP neighbors and a list of nodes that we need to share passwordless
# nova authentication with.
other_compute = search(:node, "role:compute").select { |n| n[:ipaddress] != node[:ipaddress] }

# Tell apt about the Calico repository server.
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

# Configure sysctl so that forwarding is enabled, and router solicitations
# are accepted.  Allows SLAAC to provide an IPv6 address to each compute
# node without disabling forwarding. 
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
ruby_block "persist-sysctl" do
     block do
         file = Chef::Util::FileEdit.new("/etc/sysctl.conf")
         file.search_file_replace_line(/.*net\.ipv4\.conf\.all\.forwarding.*/, "net.ipv4.conf.all.forwarding=1")
         file.search_file_replace_line(/.*net\.ipv6\.conf\.all\.forwarding.*/, "net.ipv6.conf.all.forwarding=1")
         file.search_file_replace_line(/.*net\.ipv6\.conf\.all\.accept_ra.*/, "net.ipv6.conf.all.accept_ra=2")
         file.search_file_replace_line(/.*net\.ipv6\.conf\.eth0\.forwarding.*/, "net.ipv6.conf.eth0.forwarding=0")
         file.insert_line_if_no_match(/.*net\.ipv4\.conf\.all\.forwarding.*/, "net.ipv4.conf.all.forwarding=1")
         file.insert_line_if_no_match(/.*net\.ipv6\.conf\.all\.forwarding.*/, "net.ipv6.conf.all.forwarding=1")
         file.insert_line_if_no_match(/.*net\.ipv6\.conf\.all\.accept_ra.*/, "net.ipv6.conf.all.accept_ra=2")
         file.insert_line_if_no_match(/.*net\.ipv6\.conf\.eth0\.forwarding.*/, "net.ipv6.conf.eth0.forwarding=0")
         file.write_file
     end 
end 

# Install a few needed packages.
package "ntp" do
    action [:install]
end
package "python-mysqldb" do
    action [:install]
end


# COMPUTE

package "nova-compute-kvm" do
    action [:install]
end
package "python-guestfs" do
    action [:install]
end
package "nova-api-metadata" do
    action [:install]
end

# Mark the kernel world-readable.
cookbook_file "/etc/kernel/postinst.d/statoverride" do
    source "statoverride"
    mode "0755"
    owner "root"
    group "root"
    notifies :run, "bash[kernel-readable]", :immediately
end
bash "kernel-readable" do
    user "root"
    code "dpkg-statoverride --update --force --add root root 0644 /boot/vmlinuz-$(uname -r)"
    action [:nothing]
end

# Ensure that qemu can correctly find tap devices.
cookbook_file "/etc/libvirt/qemu.conf" do
    source "qemu.conf"
    mode "0600"
    owner "root"
    group "root"
    notifies :restart, "service[libvirt-bin]", :immediately
end
service "libvirt-bin" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

# Set up the nova configuration file.
template "/etc/nova/nova.conf" do
    mode "0640"
    source "compute/nova.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password],
        controller: controller,
	live_migrate: node[:calico][:live_migrate]
    })
    owner "nova"
    group "nova"
    notifies :delete, "file[/var/lib/nova/nova.sqlite]", :immediately
    notifies :restart, "service[nova-compute]", :immediately
    notifies :restart, "service[nova-api-metadata]", :immediately
end
template "/etc/nova/nova-compute.conf" do
    mode "0640"
    source "compute/nova-compute.conf.erb"
    variables lazy {
        {
            virt_type: if system("egrep -c '(vmx|svm)' /proc/cpuinfo") then "kvm" else "qemu" end
        }
    }
    owner "nova"
    group "nova"
    notifies :restart, "service[nova-compute]", :immediately
    notifies :run, "execute[live-migration]", :immediately
end

# Delete the sqlite DB and restart Nova.
file "/var/lib/nova/nova.sqlite" do
    action [:nothing]
end
service "nova-compute" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
    notifies :restart, "service[libvirt-bin]", :immediately
end
service "nova-api-metadata" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

# SET UP NOVA WITH PASSWORDLESS AUTHENTICATION

# Provide a logon shell for nova user.
execute "nova-logon-shell" do
    user "root"
    command "usermod -s /bin/bash nova"
end

# Create SSH key for nova user.
execute "nova-ssh-keygen" do
    user "root"
    command "sudo -u nova ssh-keygen -q -t rsa -N '' -f /var/lib/nova/.ssh/id_rsa"
    creates "/var/lib/nova/.ssh/id_rsa"
    not_if { ::File.exists?("/var/lib/nova/.ssh/id_rsa")}
end 

# Create authorized keys file for nova.
file "/var/lib/nova/.ssh/authorized_keys" do
    owner "nova"
    group "nova"
    mode "0600"
    action :create_if_missing
end

# Add SSH config to automatically accept unknown hosts
cookbook_file "/var/lib/nova/.ssh/config" do
    source "config.ssh"
    owner "nova"
    group "nova"
    mode "0600"
end

# Expose public key in attributes
ruby_block "expose-public-key" do
    block do
        node.default['nova_public_key'] = ::File.read("/var/lib/nova/.ssh/id_rsa.pub")
    end
end

# Add the public key for the other compute nodes to our authorized_keys.
ruby_block "load-compute-node-keys" do
    block do
        file = Chef::Util::FileEdit.new("/var/lib/nova/.ssh/authorized_keys")
        other_compute.each do |n|
            key = n['nova_public_key']
            file.insert_line_if_no_match(/#{key}/, key)
	end
	file.write_file
    end
end

# NETWORKING

package "neutron-common" do
    action [:install]
end
package "neutron-dhcp-agent" do
    action [:install]
end

# Set up the Neutron config file.
template "/etc/neutron/neutron.conf" do
    mode "0644"
    source "compute/neutron.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password],
        controller: controller
    })
    owner "root"
    group "neutron"
    notifies :restart, "service[neutron-dhcp-agent]", :delayed
end

cookbook_file "/etc/neutron/dhcp_agent.ini" do
    mode "0644"
    source "dhcp_agent.ini"
    owner "root"
    group "neutron"
end

# Restart relevant services.
service "neutron-dhcp-agent" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end


# CALICO

# Add a PPA for BIRD.
apt_repository "bird" do
    uri "http://ppa.launchpad.net/cz.nic-labs/bird/ubuntu"
    distribution "trusty"
    components ["main"]
    keyserver "keyserver.ubuntu.com"
    key "F9C59A45"
end

package "bird" do
    action [:install]
    notifies :create, "template[/etc/bird/bird.conf]", :immediately
    notifies :create, "template[/etc/bird/bird6.conf]", :immediately
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
        bgp_neighbors: other_compute
    })
    owner "bird"
    group "bird"
    notifies :restart, "service[bird6]", :delayed
end

service "bird" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

service "bird6" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

service "calico-felix" do
    provider Chef::Provider::Service::Upstart
    action [:nothing]
end

template "/etc/calico/felix.cfg" do
    mode "0644"
    source "compute/felix.cfg.erb"
    variables({
        controller: controller
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
    notifies :run, "ruby_block[store-nova-user-info]", :immediately
    notifies :stop, "service[nova-api]", :immediately
    notifies :stop, "service[libvirt-bin]", :immediately
    notifies :run, "ruby_block[update-libvirt]", :immediately
    notifies :run, "ruby_block[fix-nova-files]", :immediately
    notifies :install, "package[nfs-common]", :immediately
    notifies :create_if_missing, "directory[/var/lib/nova_share]", :immediately
    notifies :create_if_missing, "directory[/var/lib/nova_share/instances]", :immediately
    notifies :run, "ruby_block[persist-share-config]", :immediately
    notifies :run, "execute[mount-share]", :immediately
    notifies :start, "service[nova-api]", :immediately
    notifies :start, "service[libvirt-bin]", :immediately
end

ruby_block "store-nova-user-info" do
    action [:nothing]
    block do
        output = ::File.read("/tmp/nova.user")                
        match = /uid=(?<uid>\d+).*gid=(?<gid>\d+).*/.match(output)
        node.default["nova_uid"] = match[:uid]
        node.default["nova_gid"] = match[:gid]
    end 
end 

# Service nova-api and libvirt-bin
service "nova-api" do
    action [:nothing]
end
service "libvirt-bin" do
    action [:nothing]
end

# Update the libvirt configuration required to get live migration working.
ruby_block "update-libvirt" do
    action [:nothing]
    block do
        file = Chef::Util::FileEdit.new("/etc/libvirt/libvirt.conf")
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
        file.search_file_replace_line(/libvirtd_opts\s*=\s*\".*/, "libvirtd_opts=\" -d -l\"")
        file.write_file
    end
end

ruby_block "fix-nova-files" do
    action [:nothing]
    block do
        print "Current Nova UID: " + node[:nova_uid] + "\n"
        print "Current Nova GUI: " + node[:nova_gid] + "\n"
    end
    notifies :run, "bash[:fix-nova-files-uid]", :immediately
    notifies :run, "bash[:fix-nova-files-gid]", :immediately
end
    
bash "fix-nova-files-uid" do
    action [:nothing]
    command "find / -uid " + node[:nova_uid] + " -exec chown nova {}"
end

bash "fix-nova-files-gid" do
    action [:nothing]
    command "find / -gid " + node[:noda_gid] + " -exec chgrp nova {}"
end

# Install NFS kernel server.
package "nfs-common" do
    action [:nothing]
end

# Create share point.
directory "/var/lib/nova_share" do
    owner "nova"
    group "nova"
    mode "0777"
    action [:nothing]
end
directory "/var/lib/nova_share/instances" do
    owner "nova"
    group "nova"
    mode "0777"
    action [:nothing]
end

# Add a persistent entry for the share point.
ruby_block "persist-share-config" do
    block do
        file = Chef::Util::FileEdit.new("/etc/fstab")
        entry = controller + ":/ /var/lib/nova_share/instances nfs4 defaults 0 0"
        file.insert_line_if_no_match(/#{entry}/, entry)
        file.write_file
    end
    action [:nothing]
end

# Mount the share.
execute "mount-share" do
    command "mount -v -t nfs4 -o nfsvers=4 " + controller + ":/ /var/lib/nova_share/instances"
    action [:nothing]
end
