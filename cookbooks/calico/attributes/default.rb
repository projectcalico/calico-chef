# Default credentials. DO NOT USE THESE, THEY'RE WILDLY INSECURE.
default["calico"]["admin_password"] = "abcdef"
default["calico"]["admin_token"]    = "abcdef"

# The location of the Calico packages, and the location of the key used to sign
# them. By default we install from the release versions.
default["calico"]["package_source"] = "http://binaries.projectcalico.org/repo ./"
default["calico"]["package_key"]    = "http://binaries.projectcalico.org/repo/key"

# Whether an NFS mount will be created.  This is not usually recommended since the
# mount that these scripts create is unprotected.
default["calico"]["configure_nfs"] = false
