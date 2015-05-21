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