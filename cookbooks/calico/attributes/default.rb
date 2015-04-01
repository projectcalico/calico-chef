# Default credentials. DO NOT USE THESE, THEY'RE WILDLY INSECURE.
default["calico"]["admin_password"] = "abcdef"
default["calico"]["admin_token"]    = "abcdef"

# The location of the Calico packages, and the location of the key used to sign
# them. By default we install from the release versions.
default["calico"]["package_source"] = "http://binaries.projectcalico.org/repo ./"
default["calico"]["package_key"]    = "http://binaries.projectcalico.org/repo/key"

# The list of compute node FQDNs used to setup an NFS mount on the controller
# for testing live migration.
default["calico"]["compute_fqdns"] = nil
