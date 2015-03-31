# Find the controller hostname.
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
        controller: controller
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

# Set up Nova passwordless authentication.
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
