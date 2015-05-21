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