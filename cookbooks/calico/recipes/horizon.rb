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