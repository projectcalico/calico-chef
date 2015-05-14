name "compute_redhat"
description "Compute nodes on Redhat"
run_list [
    "yum",
    "recipe[calico::general_compute_redhat]"
]

